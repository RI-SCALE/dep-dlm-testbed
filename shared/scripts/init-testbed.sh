#!/usr/bin/env bash
set -euo pipefail

RUNTIME="${RUNTIME:-compose}"
K8S_NAMESPACE="${K8S_NAMESPACE:-dep-dlm-testbed}"
TOKEN_MODE="${TOKEN_MODE:-managed}"
COMPOSE_FILE="${COMPOSE_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/deploy/compose/docker-compose.${TOKEN_MODE}.yml}"

OIDC_SEED_SCOPE="openid offline_access aud:rucio storage.read storage.modify wlcg"

# Every Rucio account that can OWN a transfer needs a seeded OIDC subject
# token, because the conveyor submitter calls request_token(account=<rule
# owner>) and get_token_for_account_operation walks that account's
# identity->subject-token chain. compose submits as root; the k8s rucio-client
# is configured account=ddmlab. Seed both so the testbed works under either.
SEED_ACCOUNTS=( root ddmlab )

# ── Token-exchange (FGAP) configuration ──────────────────────────
# Clients that PERFORM token-exchange (need the FGAP permission):
#   - rucio: submission-time exchange (core/oidc.py) -> per-RSE source/dest tokens
#   - fts:   FTS-server TokenExchangeService -> refresh tokens
# Targets are the storage-audience clients the exchange is allowed to mint for.
KCADM="/opt/keycloak/bin/kcadm.sh"
KC_REALM=rucio
EXCHANGE_REQUESTERS=( fts rucio )
EXCHANGE_TARGETS=( xrd3 xrd4 teapot1 teapot2 )
declare -A EXCHANGE_SECRET=( [fts]=fts-secret [rucio]=rucio-secret )

# ─── Cross-runtime helpers ───────────────────────────────────────

_exec() {
    local svc=$1; shift
    case "$RUNTIME" in
        compose)
            docker exec "compose-${svc}-1" "$@"
            ;;
        k8s)
            local target
            local -a cflag=()
            case "$svc" in
                ftsdb|ruciodb)
                    target="pod/${svc}-0" ;;
                rucio)
                    target="deploy/${svc}"; cflag=(-c "$svc") ;;
                *)
                    target="deploy/${svc}" ;;
            esac
            kubectl -n "$K8S_NAMESPACE" exec "$target" "${cflag[@]}" -- "$@"
            ;;
        *) echo "Unknown RUNTIME: $RUNTIME" >&2; return 2 ;;
    esac
}

_restart() {
    case "$RUNTIME" in
        compose)
            docker compose -f "$COMPOSE_FILE" restart "$@" ;;
        k8s)
            for svc in "$@"; do
                local target
                case "$svc" in
                    ftsdb*|ruciodb*)
                        target="statefulset/${svc}" ;;
                    *)
                        target="deploy/${svc}" ;;
                esac
                kubectl -n "$K8S_NAMESPACE" rollout restart "$target"
                kubectl -n "$K8S_NAMESPACE" rollout status  "$target" --timeout=120s
            done ;;
    esac
}

_http_probe_local() {
    local port=$1 path=$2
    case "$RUNTIME" in
        compose)
            curl -s -o /dev/null -w '%{http_code}' \
                "http://localhost:${port}${path}" || true ;;
        k8s)
            _exec rucio curl -s -o /dev/null -w '%{http_code}' \
                "http://localhost${path}" 2>/dev/null || true ;;
    esac
}


# ── Service URLs ─────────────────────────────────────────────────
FTS_OIDC="https://fts:8446"

ra() { _exec rucio rucio-admin -S userpass -u ddmlab --password secret "$@"; }

# Run kcadm inside the keycloak service (compose container or k8s pod).
_kc() { _exec keycloak "$KCADM" "$@"; }

# ── Infrastructure Readiness ─────────────────────────────────────

wait_for_infrastructure() {
    echo "=== Waiting for Rucio and Keycloak ==="
    for i in $(seq 1 30); do
        code=$(_http_probe_local 8090 /ping)
        [[ "$code" == "200" ]] && { echo "  ✓ rucio ready"; break; }
        echo "  [$i] rucio HTTP $code — waiting..."; sleep 5
    done

    for i in $(seq 1 30); do
        code=$(_exec rucio curl -s -o /dev/null -w '%{http_code}' \
            https://keycloak:8443/realms/rucio/.well-known/openid-configuration \
            2>/dev/null) || true
        [[ "$code" == "200" ]] && { echo "  ✓ Keycloak ready"; break; }
        echo "  [$i] Keycloak HTTP $code — waiting..."; sleep 5
    done
}

# ── Identity & Account Setup ─────────────────────────────────────
setup_accounts_and_identities() {
    echo "=== Configuring Rucio Accounts ==="

    ra account add --type SERVICE --email ddmlab@rucio ddmlab || true
    ra identity add --type USERPASS --id ddmlab --email ddmlab@rucio \
        --account ddmlab --password secret || true
    ra account add-attribute ddmlab --key admin --value True || true
    ra account update --account ddmlab --key type --value SERVICE || true
    ra account add --type USER --email randomaccount@rucio randomaccount || true

    echo "  Verifying Keycloak token endpoint..."
    AUTH=$(echo -n "rucio:rucio-secret" | base64)
    for i in $(seq 1 12); do
        code=$(_exec rucio curl -s -o /dev/null -w '%{http_code}' \
            -X POST https://keycloak:8443/realms/rucio/protocol/openid-connect/token \
            -H "Authorization: Basic $AUTH" \
            -d "grant_type=password&username=randomaccount&password=secret" \
            2>/dev/null) || true
        [[ "$code" == "200" ]] && break
        sleep 5
    done

    echo "  Registering OIDC identity for randomaccount..."
    _exec rucio python3 -c "
import urllib.request, urllib.parse, json, base64
from rucio.core.identity import add_identity, add_account_identity
from rucio.common.types import InternalAccount
from rucio.common import exception


def ensure_identity(identity, id_type, email):
    # Idempotently create an identity row. add_identity does NOT normalise a
    # PK collision into exception.Duplicate on this Rucio version - it lets the
    # raw DatabaseException through - so we also match on the message text.
    try:
        add_identity(identity, id_type, email)
    except exception.Duplicate:
        pass
    except Exception as e:
        msg = str(e).lower()
        if 'duplicate key' in msg or 'already exists' in msg or 'unique constraint' in msg:
            pass
        else:
            raise


def ensure_account_identity(identity, id_type, account, email):
    # Idempotently map an identity to an account.
    try:
        add_account_identity(identity, id_type, account, email)
    except exception.Duplicate:
        pass
    except Exception as e:
        msg = str(e).lower()
        if 'duplicate key' in msg or 'already exists' in msg or 'unique constraint' in msg:
            pass
        else:
            raise


try:
    data = urllib.parse.urlencode({'grant_type':'password','username':'randomaccount','password':'secret'}).encode()
    _auth = base64.b64encode(b'rucio:rucio-secret').decode()
    req = urllib.request.Request('https://keycloak:8443/realms/rucio/protocol/openid-connect/token',
        data=data, headers={'Authorization': f'Basic {_auth}'})
    resp = json.loads(urllib.request.urlopen(req).read())
    claims = json.loads(base64.urlsafe_b64decode(resp['access_token'].split('.')[1] + '=='))
    identity = 'SUB=' + claims['sub'] + ', ISS=' + claims['iss']

    ensure_identity(identity, 'OIDC', 'randomaccount@rucio')
    ensure_account_identity(identity, 'OIDC', InternalAccount('randomaccount'), 'randomaccount@rucio')
    print(f'  ✓ Identity registered: {identity}')
except Exception as e:
    print(f'  ⚠ Registration failed: {e}')
"
}

# ── Subject-token seeding (managed-mode token exchange) ──────────
#
# In managed-token mode (oidc.token_strategy = exchange), Rucio mints per-file
# FTS tokens by exchanging the *transfer-owning account's* stored OIDC subject
# token (RFC 8693). The owning account is whoever created the rule: compose
# submits as root, the k8s rucio-client is account=ddmlab. An unattended
# account never acquires a subject token on its own, so we seed one for each
# account in SEED_ACCOUNTS here:
#
#   1. obtain a user access token via the password grant, WITH offline_access
#      in scope (required for the exchange to mint a refresh token);
#   2. map the corresponding OIDC identity to each account;
#   3. persist the token into the Rucio `tokens` table for each account.
#
# One OIDC identity (randomaccount's) is intentionally mapped to multiple
# Rucio accounts — Rucio supports this, and get_token_for_account_operation
# resolves the issuer from the identity string, not from a 1:1 mapping.
#
# The token row MUST have:
#   - identity in Rucio's internal "SUB=<sub>, ISS=<iss>" form (NOT iss#sub),
#     because get_token_for_account_operation() parses the issuer out of it as
#     identity.split(", ")[1].split("=")[1];
#   - a non-empty oidc_scope containing offline_access;
#   - a non-empty audience.

seed_subject_tokens() {
    local accounts_csv
    accounts_csv=$(printf '%s,' "${SEED_ACCOUNTS[@]}"); accounts_csv="${accounts_csv%,}"
    echo "=== Seeding OIDC subject tokens for accounts: ${SEED_ACCOUNTS[*]} ==="

    _exec rucio env SEED_ACCOUNTS="$accounts_csv" OIDC_SEED_SCOPE="${OIDC_SEED_SCOPE}" python3 -c "
import urllib.request, urllib.parse, json, base64, sys, os
from datetime import datetime
from rucio.core.identity import add_account_identity
from rucio.core import oidc
from rucio.common.types import InternalAccount
from rucio.common import exception

SEED_SCOPE = os.environ['OIDC_SEED_SCOPE']
ACCOUNTS   = [a for a in os.environ['SEED_ACCOUNTS'].split(',') if a]
TOKEN_URL  = 'https://keycloak:8443/realms/rucio/protocol/openid-connect/token'


def _b64json(segment):
    return json.loads(base64.urlsafe_b64decode(segment + '=='))


def _mint_token():
    # Each call is a fresh password grant -> a distinct JWT (different jti/iat),
    # so each account gets its own token string. The tokens table PK is the
    # token column, so reusing one JWT across accounts violates TOKENS_PK.
    data = urllib.parse.urlencode({
        'grant_type': 'password',
        'username': 'randomaccount',
        'password': 'secret',
        'scope': SEED_SCOPE,
    }).encode()
    _auth = base64.b64encode(b'rucio:rucio-secret').decode()
    req = urllib.request.Request(TOKEN_URL, data=data,
                                 headers={'Authorization': f'Basic {_auth}'})
    return json.loads(urllib.request.urlopen(req).read())['access_token']


def _ensure_mapped(identity_internal, account):
    try:
        add_account_identity(identity_internal, 'OIDC', InternalAccount(account), f'{account}@rucio')
        print(f'  ✓ OIDC identity mapped to {account}: {identity_internal}')
    except exception.Duplicate:
        print(f'  ✓ OIDC identity already mapped to {account}')
    except Exception as e:
        msg = str(e).lower()
        if 'duplicate key' in msg or 'already exists' in msg or 'unique constraint' in msg:
            print(f'  ✓ OIDC identity already mapped to {account} (pre-existing)')
        else:
            raise


def _store(account, access_token):
    claims = _b64json(access_token.split('.')[1])
    sub = claims['sub']
    iss = claims['iss']
    granted_scope = claims.get('scope', '')
    granted_aud   = claims.get('aud', '')
    exp           = claims.get('exp')
    if 'offline_access' not in granted_scope:
        print('  ⚠ offline_access NOT granted by Keycloak - the exchange will '
              'not be able to mint a refresh token. Check that offline_access '
              'is an allowed scope on the rucio client.')
    identity_internal = oidc.oidc_identity_string(sub, iss)
    audience = ' '.join(granted_aud) if isinstance(granted_aud, list) else granted_aud
    lifetime = datetime.utcfromtimestamp(float(exp)) if exp else None

    _ensure_mapped(identity_internal, account)
    try:
        oidc.save_subject_token(
            token=access_token,
            account=InternalAccount(account),
            identity=identity_internal,
            scope=granted_scope,
            audience=audience,
            lifetime=lifetime,
        )
        print(f'  ✓ Subject token saved for {account}')
    except Exception as e:
        msg = str(e).lower()
        if 'duplicate key' in msg or 'tokens_pk' in msg or 'unique constraint' in msg:
            # token row already present for this account (idempotent re-run)
            print(f'  ✓ Subject token already present for {account}')
        else:
            raise
    return identity_internal, granted_scope, audience, lifetime


try:
    last = None
    for account in ACCOUNTS:
        # fresh grant per account -> unique token string -> no PK collision
        last = _store(account, _mint_token())

    if last:
        identity_internal, granted_scope, audience, lifetime = last
        print(f'      identity = {identity_internal}')
        print(f'      scope    = {granted_scope!r}')
        print(f'      audience = {audience!r}')
        print(f'      expires  = {lifetime}')

except urllib.error.HTTPError as e:
    print(f'  ✗ Keycloak token request failed: HTTP {e.code} {e.read().decode()[:300]}')
    sys.exit(1)
except AttributeError as e:
    print(f'  ✗ Subject-token seeding failed: {e}')
    print('    This usually means save_subject_token() is missing from the')
    print('    patched oidc.py - add the wrapper to')
    print('    shared/patches/rucio/oidc.py and re-run.')
    sys.exit(1)
except Exception as e:
    import traceback
    print(f'  ✗ Subject-token seeding failed: {e}')
    traceback.print_exc()
    sys.exit(1)
"

    # Remove non-OIDC (userpass session) token rows for every seeded account,
    # so each account's token set is exactly the seeded OIDC subject token.
    echo "  Removing non-OIDC token rows for seeded accounts..."
    local acct
    for acct in "${SEED_ACCOUNTS[@]}"; do
        _exec ruciodb env PGPASSWORD=rucio psql -U rucio -tAc \
          "DELETE FROM tokens WHERE account='${acct}' AND identity NOT LIKE 'SUB=%';"
    done
}

cleanup_session_tokens() {
    echo "=== Removing non-OIDC session tokens for seeded accounts ==="
    local acct
    for acct in "${SEED_ACCOUNTS[@]}"; do
        _exec ruciodb env PGPASSWORD=rucio psql -U rucio -tAc \
          "DELETE FROM tokens WHERE account='${acct}' AND identity NOT LIKE 'SUB=%';"
    done
}

# ── RSE Configuration ─────────────────────────────────────────────

configure_rses() {
    echo "=== Configuring RSEs ==="

    # XRootD SciTokens instances
    for rse in XRD3 XRD4; do
        local host
        host=$(echo "$rse" | tr '[:upper:]' '[:lower:]')
        ra rse add "$rse" || true
        ra rse set-attribute --rse "$rse" --key fts --value "$FTS_OIDC"
        ra rse set-attribute --rse "$rse" --key oidc_support --value True
        ra rse set-attribute --rse "$rse" --key auth_type --value OIDC
        ra rse set-attribute --rse "$rse" --key audience --value "${host}"
        ra rse set-attribute --rse "$rse" --key verify_checksum --value False
        ra rse add-protocol "$rse" --scheme davs --hostname "$host" --port 1094 \
            --prefix /data \
            --impl rucio.rse.protocols.gfal.Default \
            --domain-json '{"wan":{"read":1,"write":1,"delete":1,"third_party_copy_read":1,"third_party_copy_write":1},"lan":{"read":1,"write":1,"delete":1}}'
    done
    ra rse add-distance XRD3 XRD4 --distance 1 || true
    ra rse add-distance XRD4 XRD3 --distance 1 || true

    # Teapot WebDAV instances
    for rse in TEAPOT1 TEAPOT2; do
        local instance
        instance=$(echo "$rse" | tr '[:upper:]' '[:lower:]')
        ra rse add "$rse" || true
        ra rse set-attribute --rse "$rse" --key fts --value "$FTS_OIDC"
        ra rse set-attribute --rse "$rse" --key oidc_support --value True
        ra rse set-attribute --rse "$rse" --key auth_type --value OIDC
        ra rse set-attribute --rse "$rse" --key audience --value "$instance"
        ra rse set-attribute --rse "$rse" --key verify_checksum --value False
        ra rse add-protocol "$rse" --scheme davs \
            --hostname "${instance}" --port 8081 --prefix /data \
            --impl rucio.rse.protocols.gfal.Default \
            --domain-json '{"wan":{"read":1,"write":1,"delete":1,"third_party_copy_read":1,"third_party_copy_write":1},"lan":{"read":1,"write":1,"delete":1}}'
    done
    ra rse add-distance TEAPOT1 TEAPOT2 --distance 1 || true
    ra rse add-distance TEAPOT2 TEAPOT1 --distance 1 || true

    ra rse add-distance XRD3 TEAPOT1 --distance 1 || true
    ra rse add-distance TEAPOT1 XRD3 --distance 1 || true
}

# ── FTS OIDC Provider Registration ───────────────────────────────

setup_fts_oidc_provider() {
    echo "=== Registering Keycloak in FTS Database ==="

    echo "  Waiting for fts.t_token_provider schema..."
    for i in $(seq 1 60); do
        if _exec ftsdb mysql -h 127.0.0.1 --protocol=tcp -ufts -pfts fts \
            -e "SELECT 1 FROM t_token_provider LIMIT 1" >/dev/null 2>&1; then
            echo "  ✓ Schema ready"; break
        fi
        if [ "$i" = "60" ]; then
            echo "  ✗ Schema never appeared"
            exit 1
        fi
        sleep 5
    done


    _exec ftsdb mysql -h 127.0.0.1 --protocol=tcp -ufts -pfts fts -e "
    INSERT IGNORE INTO t_token_provider (name, issuer, client_id, client_secret) VALUES
    ('keycloak-rucio',       'https://keycloak:8443/realms/rucio',  'fts', 'fts-secret'),
    ('keycloak-rucio-slash', 'https://keycloak:8443/realms/rucio/', 'fts', 'fts-secret');"

    echo "  Restarting fts..."
    _restart fts
    for i in $(seq 1 30); do
        code=$(_exec fts curl -sk -o /dev/null -w '%{http_code}' \
            https://localhost:8446/whoami 2>/dev/null) || code=0
        [[ "$code" == "200" || "$code" == "403" ]] && { echo "  ✓ fts ready"; break; }
        sleep 5
    done
}

# ── Scopes & Quotas ───────────────────────────────────────────────

setup_scopes_and_quotas() {
    echo "=== Configuring Scopes and Quotas ==="

    ra scope add --account root --scope test || true
    ra scope add --account ddmlab --scope ddmlab || true
    ra scope add --account randomaccount --scope randomaccount || true

    for rse in XRD3 XRD4; do
        ra account set-limits root "$rse" -1 || true
        ra account set-limits randomaccount "$rse" -1 || true
        ra account set-limits ddmlab "$rse" -1 || true
    done

    for rse in TEAPOT1 TEAPOT2; do
        ra account set-limits root "$rse" -1 || true
        ra account set-limits randomaccount "$rse" -1 || true
        ra account set-limits ddmlab "$rse" -1 || true
    done
}

# ── Token-exchange grant (merged from grant-token-exchange.sh) ────
#
# Grants EXCHANGE_REQUESTERS (rucio, fts) permission to perform standard
# (legacy V1) token-exchange targeting each storage-audience client
# (EXCHANGE_TARGETS). For each target: enable management permissions, create
# (or update) a client policy whose members are all requesters, and bind that
# policy to the target's token-exchange scope permission. Idempotent.
# Keycloak 23.0.1.
grant_token_exchange() {
    echo "=== Granting token-exchange permissions ==="

    # 1. authenticate kcadm against the master realm
    _kc config credentials \
        --server http://localhost:8080 \
        --realm master --user admin --password admin

    # 2. resolve every requester client UUID
    local rc uuid
    local requester_uuids=()
    for rc in "${EXCHANGE_REQUESTERS[@]}"; do
        uuid=$(_kc get clients -r "$KC_REALM" \
            -q clientId="$rc" --fields id --format csv --noquotes | tr -d '\r')
        if [ -z "$uuid" ]; then
            echo "  ERROR: requester client '$rc' not found" >&2
            exit 1
        fi
        echo "  requester $rc UUID: $uuid"
        requester_uuids+=( "$uuid" )
    done
    local requester_uuids_json
    requester_uuids_json=$(printf '"%s",' "${requester_uuids[@]}")
    requester_uuids_json="[${requester_uuids_json%,}]"

    # 3. per target: enable permissions, create/refresh policy, bind it
    local target target_uuid rm_uuid policy_name policy_id perm_name perm_id
    for target in "${EXCHANGE_TARGETS[@]}"; do
        echo "  === target: $target ==="

        target_uuid=$(_kc get clients -r "$KC_REALM" \
            -q clientId="$target" --fields id --format csv --noquotes | tr -d '\r')
        if [ -z "$target_uuid" ]; then
            echo "  ERROR: target client '$target' not found — is it imported?" >&2
            exit 1
        fi
        echo "    target UUID: $target_uuid"

        _kc update "clients/$target_uuid/management/permissions" -r "$KC_REALM" \
            -s enabled=true
        echo "    management permissions enabled"

        rm_uuid=$(_kc get clients -r "$KC_REALM" \
            -q clientId=realm-management --fields id --format csv --noquotes | tr -d '\r')

        policy_name="exchange-to-${target}"
        policy_name=$(echo "$policy_name" | tr -c 'A-Za-z0-9_.-' '_')

        echo "    creating client policy: $policy_name  members=$requester_uuids_json"
        _kc create "clients/$rm_uuid/authz/resource-server/policy/client" -r "$KC_REALM" \
            -s "name=$policy_name" \
            -s "clients=$requester_uuids_json" \
            -s "logic=POSITIVE" \
            || echo "    (policy may already exist — updating it instead)"

        policy_id=$(_kc get \
            "clients/$rm_uuid/authz/resource-server/policy?name=$policy_name" \
            -r "$KC_REALM" --fields id --format csv --noquotes | tr -d '\r' | head -n1)

        # ensure an existing policy lists BOTH requesters (a stale single-client
        # policy from an earlier run would otherwise permit only fts).
        if [ -n "$policy_id" ]; then
            _kc update \
                "clients/$rm_uuid/authz/resource-server/policy/client/$policy_id" \
                -r "$KC_REALM" -s "clients=$requester_uuids_json" \
                || echo "    (could not update policy membership — check manually)"
        fi

        perm_name="token-exchange.permission.client.$target_uuid"
        perm_id=$(_kc get \
            "clients/$rm_uuid/authz/resource-server/permission?name=$perm_name" \
            -r "$KC_REALM" --fields id --format csv --noquotes | tr -d '\r' | head -n1)

        if [ -z "$perm_id" ] || [ -z "$policy_id" ]; then
            echo "  ERROR: could not resolve perm_id ($perm_id) or policy_id ($policy_id)." >&2
            exit 1
        fi

        _kc update \
            "clients/$rm_uuid/authz/resource-server/permission/scope/$perm_id" \
            -r "$KC_REALM" -s "policies=[\"$policy_id\"]"
        echo "    policy bound to token-exchange permission"
    done
}

# ── Token-exchange self-test (optional, gated) ───────────────────
# Set INIT_VERIFY_EXCHANGE=1 to exchange as each requester for each target and
# assert a refresh_token comes back. Off by default to keep init fast.
verify_token_exchange() {
    [ "${INIT_VERIFY_EXCHANGE:-0}" = "1" ] || return 0
    echo "=== Self-test: token-exchange as each requester -> each target ==="

    local subject
    subject=$(_exec fts curl -sk \
        -d "client_id=rucio&client_secret=rucio-secret&grant_type=password&username=randomaccount&password=secret" \
        https://keycloak:8443/realms/rucio/protocol/openid-connect/token \
        | python3 -c "import sys,json;print(json.load(sys.stdin)['access_token'])")
    echo "  subject token: ${subject:0:30}..."

    local rc aud
    for rc in "${EXCHANGE_REQUESTERS[@]}"; do
        for aud in "${EXCHANGE_TARGETS[@]}"; do
            echo -n "  --- exchange as $rc -> $aud : "
            _exec fts curl -sk -u "$rc:${EXCHANGE_SECRET[$rc]}" \
                -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
                -d "requested_token_type=urn:ietf:params:oauth:token-type:refresh_token" \
                -d "subject_token_type=urn:ietf:params:oauth:token-type:access_token" \
                -d "subject_token=$subject" \
                -d "audience=$aud" \
                https://keycloak:8443/realms/rucio/protocol/openid-connect/token \
                | python3 -c "import sys,json;r=json.load(sys.stdin);print('OK' if 'refresh_token' in r else r)"
        done
    done
}

# ── Main ──────────────────────────────────────────────────────────

main() {
    wait_for_infrastructure
    setup_accounts_and_identities
    if [ "${TOKEN_MODE:-managed}" = "managed" ]; then
        grant_token_exchange
        seed_subject_tokens
    fi
    configure_rses
    setup_scopes_and_quotas
    setup_fts_oidc_provider
    cleanup_session_tokens

    echo -e "\n=== Initialization Complete ==="
}

main
