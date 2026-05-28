#!/usr/bin/env bash
set -euo pipefail

RUNTIME="${RUNTIME:-compose}"
K8S_NAMESPACE="${K8S_NAMESPACE:-dep-dlm-testbed}"
COMPOSE_FILE="${COMPOSE_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/deploy/compose/docker-compose.yml}"

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

OIDC_SEED_SCOPE="openid offline_access aud:rucio storage.read storage.modify wlcg"

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

    seed_subject_token_for_root
}

# ── Subject-token seeding (managed-mode token exchange) ──────────
#
# The conveyor submitter runs transfers as account 'root'. In managed-token
# mode (oidc.token_strategy = exchange), Rucio mints per-file FTS tokens by
# exchanging that account's stored OIDC *subject token* (RFC 8693). An
# unattended account never acquires one on its own, so we seed it here:
#
#   1. obtain a user access token via the password grant, WITH offline_access
#      in scope (required for the exchange to be able to mint a refresh token);
#   2. map the corresponding OIDC identity to the root account;
#   3. persist the token into the Rucio `tokens` table.
#
# Step 3 deliberately does NOT use validate_jwt(): that function is built for
# *external* tokens and resolves the account through get_default_account(),
# which is ambiguous here because this one OIDC identity is mapped to more than
# one account. Instead it calls save_subject_token() - a thin wrapper added in
# shared/patches/rucio/managed-token/oidc.py around the same internal saver
# validate_jwt would have used - with the account known explicitly.
#
# The token row MUST have:
#   - identity in Rucio's internal "SUB=<sub>, ISS=<iss>" form (NOT iss#sub),
#     because get_token_for_account_operation() parses the issuer out of it as
#     identity.split(", ")[1].split("=")[1];
#   - a non-empty oidc_scope containing offline_access;
#   - a non-empty audience.
#
# Without this row, get_token_for_account_operation() finds no subject token
# and logs "No valid token exists for account root".

seed_subject_token_for_root() {
    echo "=== Seeding OIDC subject token for account 'root' ==="

    _exec rucio python3 -c "
import urllib.request, urllib.parse, json, base64, sys
from datetime import datetime
from rucio.core.identity import add_account_identity
from rucio.core import oidc
from rucio.common.types import InternalAccount
from rucio.common import exception

SEED_SCOPE = '${OIDC_SEED_SCOPE}'
TOKEN_URL  = 'https://keycloak:8443/realms/rucio/protocol/openid-connect/token'


def _b64json(segment):
    return json.loads(base64.urlsafe_b64decode(segment + '=='))


try:
    # 1. password grant for the Keycloak user 'randomaccount', explicitly
    #    requesting offline_access. 'randomaccount' is a real Keycloak user;
    #    'root' is the Rucio-side account the conveyor submits under. We map
    #    this user's OIDC identity onto root and store its token for root.
    data = urllib.parse.urlencode({
        'grant_type': 'password',
        'username': 'randomaccount',
        'password': 'secret',
        'scope': SEED_SCOPE,
    }).encode()
    _auth = base64.b64encode(b'rucio:rucio-secret').decode()
    req = urllib.request.Request(TOKEN_URL, data=data,
                                 headers={'Authorization': f'Basic {_auth}'})
    resp = json.loads(urllib.request.urlopen(req).read())

    access_token = resp['access_token']
    claims = _b64json(access_token.split('.')[1])

    sub = claims['sub']
    iss = claims['iss']
    granted_scope = claims.get('scope', '')
    granted_aud   = claims.get('aud', '')
    exp           = claims.get('exp')

    print(f'  token scope = {granted_scope!r}')
    print(f'  token aud   = {granted_aud!r}')
    if 'offline_access' not in granted_scope:
        print('  ⚠ offline_access NOT granted by Keycloak - the exchange will '
              'not be able to mint a refresh token. Check that offline_access '
              'is an allowed scope on the rucio client.')

    # 2. map the OIDC identity to the root account, in Rucio's internal
    #    'SUB=..., ISS=...' form. This MUST be the same string used for the
    #    tokens row in step 3 — get_token_for_account_operation joins the
    #    identities table to the tokens table by exact string equality
    #    (Token.identity.in_(identities)), so the two must not differ.
    identity_internal = oidc.oidc_identity_string(sub, iss)
    try:
        add_account_identity(identity_internal, 'OIDC', InternalAccount('root'), 'root@rucio')
        print(f'  ✓ OIDC identity mapped to root: {identity_internal}')
    except exception.Duplicate:
        print(f'  ✓ OIDC identity already mapped to root: {identity_internal}')
    except Exception as e:
        msg = str(e).lower()
        if 'duplicate key' in msg or 'already exists' in msg or 'unique constraint' in msg:
            print('  ✓ OIDC identity already mapped to root (pre-existing)')
        else:
            raise

    # 3. persist the access token into the tokens table for account root.
    #    NOTE the identity format: the tokens row must use Rucio's internal
    #    'SUB=<sub>, ISS=<iss>' string, which oidc_identity_string() builds,
    #    NOT the iss#sub form used for the identities table above.
    identity_internal = oidc.oidc_identity_string(sub, iss)
    audience = ' '.join(granted_aud) if isinstance(granted_aud, list) else granted_aud
    lifetime = datetime.utcfromtimestamp(float(exp)) if exp else None

    oidc.save_subject_token(
        token=access_token,
        account=InternalAccount('root'),
        identity=identity_internal,
        scope=granted_scope,
        audience=audience,
        lifetime=lifetime,
    )
    print(f'  ✓ Subject token saved for root')
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
    print('    shared/patches/rucio/managed-token/oidc.py and re-run.')
    sys.exit(1)
except Exception as e:
    import traceback
    print(f'  ✗ Subject-token seeding failed: {e}')
    traceback.print_exc()
    sys.exit(1)
"
    # Remove non-OIDC token rows for root. The ra() helper authenticates via
    # rucio-admin userpass, which mints session tokens with identity='ddmlab'
    # (not 'SUB=..., ISS=...') under account=root. The patched
    # get_token_for_account_operation now filters these out defensively, but
    # they are pure cruft for managed-mode TPC, so drop them to keep root's
    # token set to exactly the seeded OIDC subject token.
    echo "  Removing non-OIDC token rows for root..."
    _exec ruciodb psql -U rucio -tAc \
      "DELETE FROM tokens WHERE account='root' AND identity NOT LIKE 'SUB=%';"
}

cleanup_root_session_tokens() {
    echo "=== Removing non-OIDC session tokens for root ==="
    _exec ruciodb psql -U rucio -tAc \
      "DELETE FROM tokens WHERE account='root' AND identity NOT LIKE 'SUB=%';"
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

# ── Main ──────────────────────────────────────────────────────────

main() {
    wait_for_infrastructure
    setup_accounts_and_identities
    configure_rses
    setup_scopes_and_quotas
    setup_fts_oidc_provider
    cleanup_root_session_tokens

    echo -e "\n=== Initialization Complete ==="
}

main
