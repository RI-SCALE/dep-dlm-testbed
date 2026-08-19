#!/usr/bin/env bash
set -euo pipefail

RUNTIME="${RUNTIME:-compose}"
K8S_NAMESPACE="${K8S_NAMESPACE:-dep-dlm-sandbox}"
TOKEN_MODE="${TOKEN_MODE:-managed}"
COMPOSE_FILE="${COMPOSE_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/deploy/compose/docker-compose.${TOKEN_MODE}.yml}"


FTS_OIDC="https://fts:8446"
OIDC_SEED_SCOPE="openid offline_access aud:rucio storage.read storage.modify wlcg"

SEED_ACCOUNTS=( root ddmlab )

KCADM="/opt/keycloak/bin/kcadm.sh"
KC_REALM=rucio
EXCHANGE_REQUESTERS=( fts rucio )
EXCHANGE_TARGETS=( xrd3 xrd4 teapot1 teapot2 )
declare -A EXCHANGE_SECRET=( [fts]=fts-secret [rucio]=rucio-secret )

SCOPE_PROFILE="${SCOPE_PROFILE:-local}"

OIDC_ISSUER="${OIDC_ISSUER:-https://keycloak:8443/realms/rucio}"
OIDC_TOKEN_URL="${OIDC_TOKEN_URL:-${OIDC_ISSUER%/}/protocol/openid-connect/token}"
IDPSECRETS_PATH_IN_CONTAINER="${IDPSECRETS_PATH_IN_CONTAINER:-/opt/rucio/etc/idpsecrets.json}"

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
                rucio-server)
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
            _exec rucio-server curl -s -o /dev/null -w '%{http_code}' \
                "http://localhost${path}" 2>/dev/null || true ;;
    esac
}

_grant_mode_for_profile() {
    case "$SCOPE_PROFILE" in
        egi-dev|ls-aai-dev) echo "client_credentials" ;;
        *)       echo "password" ;;
    esac
}

_expected_audience_for_profile() {
    case "$SCOPE_PROFILE" in
        egi-dev|ls-aai-dev) echo "https://fts.example.org/" ;;
        *)                  echo "$FTS_OIDC" ;;
    esac
}

OIDC_EXPECTED_AUDIENCE="${OIDC_EXPECTED_AUDIENCE:-$(_expected_audience_for_profile)}"

_cap() {
    local path="$1" default="$2"
    _exec rucio-server env \
        CAP_ISSUER="$OIDC_ISSUER" CAP_PATH="$path" CAP_DEFAULT="$default" \
        CAP_FILE="$IDPSECRETS_PATH_IN_CONTAINER" \
        python3 -c "
import json, os
try:
    with open(os.environ['CAP_FILE']) as f:
        data = json.load(f)
    val = data.get(os.environ['CAP_ISSUER'], {}).get('capabilities', {})
    for part in os.environ['CAP_PATH'].split('.'):
        val = val[part]
    print(str(val).lower())
except Exception:
    print(os.environ['CAP_DEFAULT'])
"
}

# ── Service URLs ─────────────────────────────────────────────────

ra() { _exec rucio-server rucio-admin -S userpass -u ddmlab --password secret "$@"; }

_kc() { _exec keycloak "$KCADM" "$@"; }

_fts_admin() {
    local attempt rc
    for attempt in 1 2 3; do
        if _exec fts curl -skS --tls-max 1.2 \
            --cert /etc/grid-security/hostcert.pem \
            --key /etc/grid-security/hostkey.pem \
            "$@"; then
            rc=0
        else
            rc=$?
        fi
        [ "$rc" -eq 0 ] && return 0
        [ "$rc" -eq 18 ] && { echo "  ⚠ curl exit 18 (response truncated at transport layer, request itself succeeds server-side — continuing" >&2; return 0; }
        echo "  ⚠ FTS admin call failed (curl exit ${rc}), attempt ${attempt}/3 — retrying in 5s..." >&2
        sleep 5
    done
    echo "  ✗ FTS admin call failed after 3 attempts: $*" >&2
    return 1
}

# ── Infrastructure Readiness ─────────────────────────────────────

wait_for_infrastructure() {
    echo "=== Waiting for Rucio and Keycloak ==="
    for i in $(seq 1 30); do
        code=$(_http_probe_local 8090 /ping)
        [[ "$code" == "200" ]] && { echo "  ✓ rucio ready"; break; }
        echo "  [$i] rucio HTTP $code — waiting..."; sleep 5
    done

    for i in $(seq 1 30); do
        code=$(_exec rucio-server curl -s -o /dev/null -w '%{http_code}' \
            "${OIDC_ISSUER%/}/.well-known/openid-configuration" \
            2>/dev/null) || true
        [[ "$code" == "200" ]] && { echo "  ✓ Keycloak ready"; break; }
        echo "  [$i] Keycloak HTTP $code — waiting..."; sleep 5
    done

    for i in $(seq 1 30); do
        code=$(_fts_admin -o /dev/null -w '%{http_code}' https://localhost:8446/whoami 2>/dev/null) || code=0
        [[ "$code" == "200" || "$code" == "403" ]] && { echo "  ✓ FTS ready"; break; }
        echo "  [$i] FTS HTTP $code — waiting..."; sleep 5
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
    ra account add-attribute randomaccount --key admin --value True || true

    local grant_mode
    grant_mode=$(_grant_mode_for_profile)
    if [ "$grant_mode" != "password" ]; then
        echo "  Skipping password-grant identity registration (grant_mode=$grant_mode for $OIDC_ISSUER)."
        echo "  Map the external identity manually — see runbook 02 Step 3"
        echo "  (rucio-admin identity add --type OIDC --id \"SUB=..., ISS=$OIDC_ISSUER\" ...)."
        return 0
    fi

    echo "  Verifying Keycloak token endpoint..."
    AUTH=$(echo -n "rucio:rucio-secret" | base64)
    for i in $(seq 1 12); do
        code=$(_exec rucio-server curl -s -o /dev/null -w '%{http_code}' \
            -X POST "$OIDC_TOKEN_URL" \
            -H "Authorization: Basic $AUTH" \
            -d "grant_type=password&username=randomaccount&password=secret" \
            2>/dev/null) || true
        [[ "$code" == "200" ]] && break
        sleep 5
    done

    echo "  Registering OIDC identity for randomaccount..."
    _exec rucio-server env OIDC_TOKEN_URL="$OIDC_TOKEN_URL" python3 -c "
import urllib.request, urllib.parse, json, base64
import os
from rucio.core.identity import add_identity, add_account_identity
from rucio.common.types import InternalAccount
from rucio.common import exception


def ensure_identity(identity, id_type, email):
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
    req = urllib.request.Request(os.environ['OIDC_TOKEN_URL'],
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
seed_subject_tokens() {
    local accounts_csv
    accounts_csv=$(printf '%s,' "${SEED_ACCOUNTS[@]}"); accounts_csv="${accounts_csv%,}"
    echo "=== Seeding OIDC subject tokens for accounts: ${SEED_ACCOUNTS[*]} ==="

    local token_url="$OIDC_TOKEN_URL"
    local grant_mode
    grant_mode=$(_grant_mode_for_profile)

    for acct in "${SEED_ACCOUNTS[@]}"; do
        _exec ruciodb env PGPASSWORD=rucio psql -U rucio -tAc \
        "DELETE FROM tokens WHERE account='${acct}' AND identity LIKE 'SUB=%';"
    done

    echo "  Using expected audience: $OIDC_EXPECTED_AUDIENCE"

    _exec rucio-server env \
        SEED_ACCOUNTS="$accounts_csv" \
        OIDC_SEED_SCOPE="${OIDC_STORAGE_SCOPE:-$OIDC_SEED_SCOPE}" \
        OIDC_TOKEN_URL="$token_url" \
        OIDC_GRANT_MODE="$grant_mode" \
        OIDC_CLIENT_ID="${OIDC_CLIENT_ID:-rucio}" \
        OIDC_CLIENT_SECRET="${OIDC_CLIENT_SECRET:-rucio-secret}" \
        OIDC_EXPECTED_AUDIENCE="$OIDC_EXPECTED_AUDIENCE" \
        python3 -c "
import urllib.request, urllib.parse, json, base64, sys, os
from datetime import datetime
from rucio.core.identity import add_account_identity
from rucio.core import oidc
from rucio.common.types import InternalAccount
from rucio.common import exception

SEED_SCOPE    = os.environ['OIDC_SEED_SCOPE']
TOKEN_URL     = os.environ['OIDC_TOKEN_URL']
GRANT_MODE    = os.environ['OIDC_GRANT_MODE']
CLIENT_ID     = os.environ['OIDC_CLIENT_ID']
CLIENT_SECRET = os.environ['OIDC_CLIENT_SECRET']
ACCOUNTS      = [a for a in os.environ['SEED_ACCOUNTS'].split(',') if a]
EXPECTED_AUDIENCE = os.environ['OIDC_EXPECTED_AUDIENCE']


def _b64json(segment):
    return json.loads(base64.urlsafe_b64decode(segment + '=='))


def _mint_token():
    if GRANT_MODE == 'client_credentials':
        data = {
            'grant_type': 'client_credentials',
            'scope': SEED_SCOPE,
        }
        if EXPECTED_AUDIENCE.startswith(('http://', 'https://')):
            data['resource'] = EXPECTED_AUDIENCE
        data = urllib.parse.urlencode(data).encode()
    else:
        data = urllib.parse.urlencode({
            'grant_type': 'password',
            'username': 'randomaccount',
            'password': 'secret',
            'scope': SEED_SCOPE,
        }).encode()
    _auth = base64.b64encode(f'{CLIENT_ID}:{CLIENT_SECRET}'.encode()).decode()
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
    if GRANT_MODE == 'password' and 'offline_access' not in granted_scope:
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
            print(f'  ✓ Subject token already present for {account}')
        else:
            raise
    return identity_internal, granted_scope, audience, lifetime


try:
    last = None
    for account in ACCOUNTS:
        last = _store(account, _mint_token())

    if last:
        identity_internal, granted_scope, audience, lifetime = last
        print(f'      identity = {identity_internal}')
        print(f'      scope    = {granted_scope!r}')
        print(f'      audience = {audience!r}')
        print(f'      expires  = {lifetime}')

except urllib.error.HTTPError as e:
    print(f'  ✗ Token request failed: HTTP {e.code} {e.read().decode()[:300]}')
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

    local resource_param
    resource_param=$(_cap "client_credentials.resource_param" "false")

    for rse in XRD3 XRD4; do
        local host
        host=$(echo "$rse" | tr '[:upper:]' '[:lower:]')
        ra rse add "$rse" || true
        ra rse set-attribute --rse "$rse" --key fts --value "$FTS_OIDC"
        ra rse set-attribute --rse "$rse" --key oidc_support --value True
        ra rse set-attribute --rse "$rse" --key auth_type --value OIDC
        if [ "$resource_param" = "true" ]; then
            ra rse set-attribute --rse "$rse" --key audience --value "https://${host}.example.org/"
        else
            ra rse set-attribute --rse "$rse" --key audience --value "${host}"
        fi
        ra rse set-attribute --rse "$rse" --key verify_checksum --value False
        ra rse add-protocol "$rse" --scheme davs --hostname "$host" --port 1094 \
            --prefix /data \
            --impl rucio.rse.protocols.gfal.Default \
            --domain-json '{"wan":{"read":1,"write":1,"delete":1,"third_party_copy_read":1,"third_party_copy_write":1},"lan":{"read":1,"write":1,"delete":1}}'
    done
    ra rse add-distance XRD3 XRD4 --distance 1 || true
    ra rse add-distance XRD4 XRD3 --distance 1 || true

    for rse in TEAPOT1 TEAPOT2; do
        local instance
        instance=$(echo "$rse" | tr '[:upper:]' '[:lower:]')
        ra rse add "$rse" || true
        ra rse set-attribute --rse "$rse" --key fts --value "$FTS_OIDC"
        ra rse set-attribute --rse "$rse" --key oidc_support --value True
        ra rse set-attribute --rse "$rse" --key auth_type --value OIDC
        if [ "$resource_param" = "true" ]; then
            ra rse set-attribute --rse "$rse" --key audience --value "https://${instance}.example.org/"
        else
            ra rse set-attribute --rse "$rse" --key audience --value "$instance"
        fi
        ra rse set-attribute --rse "$rse" --key verify_checksum --value False
        ra rse add-protocol "$rse" --scheme davs \
            --hostname "${instance}" --port 8081 --prefix /data \
            --impl rucio.rse.protocols.gfal.Default \
            --domain-json '{"wan":{"read":1,"write":1,"delete":1,"third_party_copy_read":1,"third_party_copy_write":1},"lan":{"read":1,"write":1,"delete":1}}'

        ra rse add-protocol "$rse" --scheme https \
            --hostname "${instance}" --port 8081 --prefix /data \
            --impl rucio.rse.protocols.gfal.Default \
            --domain-json '{"wan":{"read":1,"write":1,"delete":1,"third_party_copy_read":1,"third_party_copy_write":1},"lan":{"read":1,"write":1,"delete":1}}'
    done
    ra rse add-distance TEAPOT1 TEAPOT2 --distance 1 || true
    ra rse add-distance TEAPOT2 TEAPOT1 --distance 1 || true

    ra rse add-distance XRD3 TEAPOT1 --distance 1 || true
    ra rse add-distance TEAPOT1 XRD3 --distance 1 || true
}

# ── S3 source RSE ──
configure_s3_source_rse() {
    if [ -z "${S3_ACCESS_KEY:-}" ] || [ -z "${S3_SECRET_KEY:-}" ]; then
        echo "=== COPERNICUS_S3 skipped (ACCESS_KEY / SECRET_KEY not set) ==="
        return 0
    fi

    local raw_endpoint="${S3_ENDPOINT:-eodata.dataspace.copernicus.eu}"
    local s3_endpoint="${raw_endpoint#*://}"
    s3_endpoint="${s3_endpoint%%/*}"
    local s3_bucket="${S3_BUCKET:-eodata}"

    echo "=== Configuring S3 source RSE (COPERNICUS_S3) → s3s://${s3_endpoint}/${s3_bucket}/ ==="

    ra rse add --non-deterministic COPERNICUS_S3 || true
    ra rse set-attribute --rse COPERNICUS_S3 --key fts             --value "$FTS_OIDC"
    ra rse set-attribute --rse COPERNICUS_S3 --key verify_checksum --value False

    ra rse add-protocol COPERNICUS_S3 --scheme s3s \
        --hostname "${s3_endpoint}" --port 443 \
        --prefix "/${s3_bucket}" \
        --impl rucio.rse.protocols.gfal.Default \
        --domain-json '{"wan":{"read":1,"write":0,"delete":0,"third_party_copy_read":1,"third_party_copy_write":0},"lan":{"read":1,"write":0,"delete":0}}'

    ra rse add-distance COPERNICUS_S3 TEAPOT2 --distance 1 || true
    ra rse add-distance COPERNICUS_S3 XRD4    --distance 1 || true

    local acct
    for acct in root ddmlab randomaccount; do
        ra account set-limits "$acct" COPERNICUS_S3 -1 || true
    done
}

# ── FTS server-side S3 configuration ─────────────────────────────
configure_fts_cloud_storage() {
    if [ -z "${S3_ACCESS_KEY:-}" ] || [ -z "${S3_SECRET_KEY:-}" ]; then
        echo "=== FTS cloud_storage skipped (ACCESS_KEY / SECRET_KEY not set) ==="
        return 0
    fi

    local raw_endpoint="${S3_ENDPOINT:-eodata.dataspace.copernicus.eu}"
    local s3_endpoint="${raw_endpoint#*://}"
    s3_endpoint="${s3_endpoint%%/*}"
    local s3_region="${S3_REGION:-default}"
    local storage_name="S3:${s3_endpoint}"

    local user_dn="${FTS_USER_DN:-}"
    if [ -z "$user_dn" ]; then
        echo "  Deriving user_dn from FTS's own client_credentials sub claim..."
        user_dn=$(_exec fts env \
            OIDC_TOKEN_URL="$OIDC_TOKEN_URL" \
            OIDC_CLIENT_ID="${OIDC_CLIENT_ID:-rucio}" \
            OIDC_CLIENT_SECRET="${OIDC_CLIENT_SECRET:-rucio-secret}" \
            OIDC_STORAGE_SCOPE="${OIDC_STORAGE_SCOPE:-openid}" \
            python3 -c "
import urllib.request, urllib.parse, json, base64, os
data = urllib.parse.urlencode({'grant_type':'client_credentials','scope':os.environ['OIDC_STORAGE_SCOPE']}).encode()
auth = base64.b64encode(f\"{os.environ['OIDC_CLIENT_ID']}:{os.environ['OIDC_CLIENT_SECRET']}\".encode()).decode()
req = urllib.request.Request(os.environ['OIDC_TOKEN_URL'], data=data, headers={'Authorization': f'Basic {auth}'})
tok = json.loads(urllib.request.urlopen(req).read())['access_token']
p = tok.split('.')[1]; p += '=' * (-len(p) % 4)
print(json.loads(base64.urlsafe_b64decode(p))['sub'])
")
        if [ -z "$user_dn" ]; then
            echo "  ✗ Failed to derive user_dn — falling back to placeholder (will 403 at transfer time)"
            user_dn="e8af11a6-76bb-44dd-abf7-32988c769cfc"
        else
            echo "  ✓ Derived user_dn: $user_dn"
        fi
    fi

    echo "=== Configuring FTS cloud_storage entry for ${storage_name} (via REST) ==="

    _fts_admin -X POST -H "Content-Type: application/json" \
        -d "{\"storage_name\":\"${storage_name}\",\"region\":\"${s3_region}\",\"sigv4_header_mode\":1}" \
        https://localhost:8446/config/cloud_storage

    # OPEN QUESTION — not resolved by this migration:
    # the old raw insert set BOTH user_dn AND vo_name='*' on one row.
    # add_user_to_cloud_storage() REJECTS that combination outright.
    # This picks user_dn (exact-match only) — unconfirmed against
    # CSInterface.py as a like-for-like replacement.
    _fts_admin -X POST -H "Content-Type: application/json" \
        -d "{\"user_dn\":\"${user_dn}\",\"access_key\":\"${S3_ACCESS_KEY}\",\"secret_key\":\"${S3_SECRET_KEY}\"}" \
        "https://localhost:8446/config/cloud_storage/${storage_name}"

    local s3_se="s3s://${s3_endpoint}"
    echo "  Marking ${s3_se} as tpc_support=NONE (force streamed copy mode)..."
    _fts_admin -X POST -H "Content-Type: application/json" \
        -d "{\"${s3_se}\":{\"se_info\":{\"tpc_support\":\"NONE\"}}}" \
        https://localhost:8446/config/se

    local gfal_section
    gfal_section="[S3:$(echo "$s3_endpoint" | tr '[:lower:]' '[:upper:]')]"
    local region_line=""
    [ -n "$s3_region" ] && region_line="REGION=${s3_region}"
    local conf_path="/etc/gfal2.d/s3-${s3_endpoint}.conf"
    _exec fts bash -c "cat > '${conf_path}' <<CONF
${gfal_section}
ALTERNATE=true
${region_line}
SIGV4_HEADER_MODE=true
CONF"

    echo "  Restarting fts to pick up new cloud_storage entry..."
    _restart fts
}

# ── External validation-storage RSEs (see modules/validation-storage) ────
configure_validation_storage_rses() {
    local tf_dir="${TF_DIR:-deploy/terraform/environments/${TF_ENV:-staging}}"
    local val_hostname
    val_hostname=$(terraform -chdir="$tf_dir" output -raw validation_storage_hostname 2>/dev/null) || {
        echo "=== VALIDATION_STORAGE skipped (terraform output not available) ==="
        return 0
    }
    [ -n "$val_hostname" ] || { echo "=== VALIDATION_STORAGE skipped (empty hostname) ==="; return 0; }

    echo "=== Configuring external validation-storage RSEs (${val_hostname}) ==="

    # XRootD side — two RSEs, ports 1094/1095 (see module outputs
    # xrd3_pfn_root/xrd4_pfn_root)
    local rse port
    for rse_port in "EXT_XRD3:1094" "EXT_XRD4:1095"; do
        rse="${rse_port%%:*}"; port="${rse_port##*:}"
        ra rse add "$rse" || true
        ra rse set-attribute --rse "$rse" --key fts --value "$FTS_OIDC"
        ra rse set-attribute --rse "$rse" --key verify_checksum --value False
        ra rse add-protocol "$rse" --scheme root \
            --hostname "$val_hostname" --port "$port" --prefix /rucio \
            --impl rucio.rse.protocols.gfal.Default \
            --domain-json '{"wan":{"read":1,"write":1,"delete":1,"third_party_copy_read":1,"third_party_copy_write":1},"lan":{"read":1,"write":1,"delete":1}}'
    done
    ra rse add-distance EXT_XRD3 EXT_XRD4 --distance 1 || true
    ra rse add-distance EXT_XRD4 EXT_XRD3 --distance 1 || true

    # Teapot/WebDAV side — ports 8081/8082
    for rse_port in "EXT_TEAPOT1:8081" "EXT_TEAPOT2:8082"; do
        rse="${rse_port%%:*}"; port="${rse_port##*:}"
        ra rse add "$rse" || true
        ra rse set-attribute --rse "$rse" --key fts --value "$FTS_OIDC"
        ra rse set-attribute --rse "$rse" --key verify_checksum --value False
        ra rse add-protocol "$rse" --scheme https \
            --hostname "$val_hostname" --port "$port" --prefix / \
            --impl rucio.rse.protocols.gfal.Default \
            --domain-json '{"wan":{"read":1,"write":1,"delete":1,"third_party_copy_read":1,"third_party_copy_write":1},"lan":{"read":1,"write":1,"delete":1}}'
    done
    ra rse add-distance EXT_TEAPOT1 EXT_TEAPOT2 --distance 1 || true
    ra rse add-distance EXT_TEAPOT2 EXT_TEAPOT1 --distance 1 || true

    # Pair against the EXISTING sandbox RSEs too — no need for a second
    # VM, real external network path is already exercised via these RSEs.
    for rse in XRD3 XRD4; do
        ra rse add-distance EXT_XRD3 "$rse" --distance 1 || true
        ra rse add-distance "$rse" EXT_XRD3 --distance 1 || true
    done
    for rse in TEAPOT1 TEAPOT2; do
        ra rse add-distance EXT_TEAPOT1 "$rse" --distance 1 || true
        ra rse add-distance "$rse" EXT_TEAPOT1 --distance 1 || true
    done

    local acct
    for acct in root ddmlab randomaccount; do
        for rse in EXT_XRD3 EXT_XRD4 EXT_TEAPOT1 EXT_TEAPOT2; do
            ra account set-limits "$acct" "$rse" -1 || true
        done
    done
}

# ── FTS OIDC Provider Registration ───────────────────────────────

setup_fts_oidc_provider() {
    echo "=== Registering Keycloak in FTS Database (via REST) ==="

    echo "  Waiting for FTS config API to be ready..."
    for i in $(seq 1 60); do
        code=$(_fts_admin -o /dev/null -w '%{http_code}' https://localhost:8446/config/token_providers 2>/dev/null) || code=0
        [[ "$code" == "200" ]] && { echo "  ✓ Config API ready"; break; }
        [ "$i" = "60" ] && { echo "  ✗ Config API never became ready (last code: $code)"; exit 1; }
        sleep 5
    done

    # Both slash and no-slash forms are genuinely required (not just belt-
    # and-braces): submit-time lookup matches the raw JWT 'iss' claim
    # verbatim (no slash), while t_token has an FK (fk_token_issuer)
    # requiring the SLASHED form. shared/patches/fts/tokenproviders.py
    # stores issuer exactly as given, so both calls are needed.
    if [ "$SCOPE_PROFILE" = "egi-dev" ]; then
        _fts_admin -X POST -H "Content-Type: application/json" \
            -d "{\"name\":\"egi-checkin-dev\",\"issuer\":\"https://aai-dev.egi.eu/auth/realms/egi\",\"client_id\":\"${OIDC_CLIENT_ID}\",\"client_secret\":\"${OIDC_CLIENT_SECRET}\"}" \
            https://localhost:8446/config/token_providers
        _fts_admin -X POST -H "Content-Type: application/json" \
            -d "{\"name\":\"egi-checkin-dev-slash\",\"issuer\":\"https://aai-dev.egi.eu/auth/realms/egi/\",\"client_id\":\"${OIDC_CLIENT_ID}\",\"client_secret\":\"${OIDC_CLIENT_SECRET}\"}" \
            https://localhost:8446/config/token_providers
    elif [ "$SCOPE_PROFILE" = "ls-aai-dev" ]; then
        _fts_admin -X POST -H "Content-Type: application/json" \
            -d "{\"name\":\"ls-aai-dev\",\"issuer\":\"https://login.aai.lifescience-ri.eu/oidc\",\"client_id\":\"${OIDC_CLIENT_ID}\",\"client_secret\":\"${OIDC_CLIENT_SECRET}\"}" \
            https://localhost:8446/config/token_providers
        _fts_admin -X POST -H "Content-Type: application/json" \
            -d "{\"name\":\"ls-aai-dev-slash\",\"issuer\":\"https://login.aai.lifescience-ri.eu/oidc/\",\"client_id\":\"${OIDC_CLIENT_ID}\",\"client_secret\":\"${OIDC_CLIENT_SECRET}\"}" \
            https://localhost:8446/config/token_providers
    else
        _fts_admin -X POST -H "Content-Type: application/json" \
            -d "{\"name\":\"keycloak-rucio\",\"issuer\":\"https://keycloak:8443/realms/rucio\",\"client_id\":\"fts\",\"client_secret\":\"fts-secret\"}" \
            https://localhost:8446/config/token_providers
        _fts_admin -X POST -H "Content-Type: application/json" \
            -d "{\"name\":\"keycloak-rucio-slash\",\"issuer\":\"https://keycloak:8443/realms/rucio/\",\"client_id\":\"fts\",\"client_secret\":\"fts-secret\"}" \
            https://localhost:8446/config/token_providers
    fi

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
grant_token_exchange() {
    echo "=== Granting token-exchange permissions ==="

    _kc config credentials \
        --server http://localhost:8080 \
        --realm master --user admin --password admin

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
verify_token_exchange() {
    [ "${INIT_VERIFY_EXCHANGE:-0}" = "1" ] || return 0
    local grant_mode
    grant_mode=$(_grant_mode_for_profile)
    if [ "$grant_mode" != "password" ]; then
        echo "=== Skipping token-exchange self-test: non-viable on grant_mode=$grant_mode ==="
        echo "    (see docs/runbooks/02-bring-your-own-idp.md — token_strategy=exchange caveat)"
        return 0
    fi
    echo "=== Self-test: token-exchange as each requester -> each target ==="

    local subject
    subject=$(_exec fts curl -sk \
        -d "client_id=rucio&client_secret=rucio-secret&grant_type=password&username=randomaccount&password=secret" \
        "$OIDC_TOKEN_URL" \
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
                "$OIDC_TOKEN_URL" \
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
    configure_s3_source_rse
    configure_fts_cloud_storage
    configure_validation_storage_rses
    setup_scopes_and_quotas
    setup_fts_oidc_provider
    cleanup_session_tokens

    echo -e "\n=== Initialization Complete ==="
}

main
