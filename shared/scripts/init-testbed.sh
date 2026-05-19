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

try:
    data = urllib.parse.urlencode({'grant_type':'password','username':'randomaccount','password':'secret'}).encode()
    _auth = base64.b64encode(b'rucio:rucio-secret').decode()
    req = urllib.request.Request('https://keycloak:8443/realms/rucio/protocol/openid-connect/token',
        data=data, headers={'Authorization': f'Basic {_auth}'})
    resp = json.loads(urllib.request.urlopen(req).read())
    claims = json.loads(base64.urlsafe_b64decode(resp['access_token'].split('.')[1] + '=='))
    identity = claims['iss'] + '#' + claims['sub']

    try: add_identity(identity, 'OIDC', 'randomaccount@rucio')
    except exception.Duplicate: pass

    try: add_account_identity(identity, 'OIDC', InternalAccount('randomaccount'), 'randomaccount@rucio')
    except exception.Duplicate: pass
    print(f'  ✓ Identity registered: {identity}')
except Exception as e:
    print(f'  ⚠ Registration failed: {e}')
"
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
        ra rse set-attribute --rse "$rse" --key audience --value "https://${host}:1094"
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
        ra rse set-attribute --rse "$rse" --key audience --value "teapot"
        ra rse set-attribute --rse "$rse" --key verify_checksum --value False
        ra rse add-protocol "$rse" --scheme davs \
            --hostname "${instance}" --port 8081 --prefix /data \
            --impl rucio.rse.protocols.gfal.Default \
            --domain-json '{"wan":{"read":1,"write":1,"delete":1,"third_party_copy_read":1,"third_party_copy_write":1},"lan":{"read":1,"write":1,"delete":1}}'
    done
    ra rse add-distance TEAPOT1 TEAPOT2 --distance 1 || true
    ra rse add-distance TEAPOT2 TEAPOT1 --distance 1 || true
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
    INSERT IGNORE INTO t_token_provider (name, issuer, client_id, client_secret)
    VALUES
      ('keycloak-rucio',       'https://keycloak:8443/realms/rucio',  'rucio', 'rucio-secret'),
      ('keycloak-rucio-slash', 'https://keycloak:8443/realms/rucio/', 'rucio', 'rucio-secret');"

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
        ra account set-limits ddmlab "$rse" -1 || true   # ← add this
    done
}

# ── Main ──────────────────────────────────────────────────────────

main() {
    wait_for_infrastructure
    setup_accounts_and_identities
    configure_rses
    setup_scopes_and_quotas
    setup_fts_oidc_provider

    echo -e "\n=== Initialization Complete ==="
}

main
