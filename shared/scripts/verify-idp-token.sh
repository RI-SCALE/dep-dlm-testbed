#!/usr/bin/env bash
set -euo pipefail

# ── Global Config ───────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh disable=SC1091
source "${SCRIPT_DIR}/common.sh"

ISSUER=""
CID=""
CSECRET="${OIDC_CLIENT_SECRET:-}"
SCOPE="openid"
# Defaults match this testbed's example RSE audiences (conftest.py's
# _rse_resource() pattern) — override with --resources for a different set.
RESOURCES="https://fts.example.org/ https://xrd3.example.org/ https://xrd4.example.org/ https://teapot1.example.org/ https://teapot2.example.org/"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --issuer)         ISSUER="$2"; shift 2 ;;
    --client-id)       CID="$2"; shift 2 ;;
    --client-secret)   warn "passing secrets via --client-secret is visible in shell history/process list — prefer \$OIDC_CLIENT_SECRET"; CSECRET="$2"; shift 2 ;;
    --scope)           SCOPE="$2"; shift 2 ;;
    --resources)       RESOURCES="$2"; shift 2 ;;
    -h|--help)         grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

read -r -a RESOURCE_ARR <<< "$RESOURCES"
RESOURCE_1="${RESOURCE_ARR[0]}"
RESOURCE_2="${RESOURCE_ARR[1]:-${RESOURCE_ARR[0]}}"

TOKEN_URL=""   # set by resolve_token_endpoint, consumed by every test_* block

# ── Logic Blocks ────────────────────────────────────────────────────────────

validate_args() {
  [[ -n "$ISSUER" ]]  || die "--issuer is required"
  [[ -n "$CID" ]]     || die "--client-id is required"
  [[ -n "$CSECRET" ]] || die "client secret required, via --client-secret or \$OIDC_CLIENT_SECRET"
}

resolve_token_endpoint() {
  TOKEN_URL=$(curl -s "${ISSUER%/}/.well-known/openid-configuration" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d['token_endpoint'])
")
  [[ -n "$TOKEN_URL" ]] || die "could not resolve token_endpoint from ${ISSUER}/.well-known/openid-configuration"
  log "TOKEN_URL=$TOKEN_URL"
}

# 1. client_credentials — does it work at all?
test_client_credentials() {
  echo "=== 1. client_credentials ==="
  local resp
  resp=$(curl -s -u "${CID}:${CSECRET}" \
    -d 'grant_type=client_credentials' \
    -d "scope=${SCOPE}" \
    "$TOKEN_URL")
  echo "$resp" | python3 -m json.tool
  echo "$resp" | python3 -c "import sys,json; sys.exit(0 if 'access_token' in json.load(sys.stdin) else 1)" \
    || { warn "client_credentials FAILED — stopping here, tests 2/3 need a working token first"; exit 1; }
}

# 2. client_credentials + resource= — does aud reflect it?
test_resource_audience() {
  echo
  echo "=== 2. client_credentials + resource=${RESOURCE_1} ==="
  local resp token
  resp=$(curl -s -u "${CID}:${CSECRET}" \
    -d 'grant_type=client_credentials' \
    -d "scope=${SCOPE}" \
    -d "resource=${RESOURCE_1}" \
    "$TOKEN_URL")
  token=$(echo "$resp" | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))")
  if [[ -z "$token" ]]; then
    warn "resource= request FAILED: $resp"
    return 0
  fi
  python3 -c "
import base64, json
p = '$token'.split('.')[1]; p += '=' * (-len(p) % 4)
claims = json.loads(base64.urlsafe_b64decode(p))
print(json.dumps(claims, indent=2))
print('aud reflects resource=:', 'aud' in claims and '$RESOURCE_1' in claims.get('aud', []) if isinstance(claims.get('aud'), list) else claims.get('aud') == '$RESOURCE_1')
"
}

# 3. token-exchange, if enabled on this client
test_token_exchange() {
  echo
  echo "=== 3. token-exchange (${RESOURCE_1} -> ${RESOURCE_2}) ==="
  local subject_resp subject_token exchange_resp
  subject_resp=$(curl -s -u "${CID}:${CSECRET}" \
    -d 'grant_type=client_credentials' \
    -d "resource=${RESOURCE_1}" \
    -d 'scope=openid' \
    "$TOKEN_URL")
  subject_token=$(echo "$subject_resp" | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))")
  if [[ -z "$subject_token" ]]; then
    warn "subject token mint FAILED: $subject_resp"
    return 0
  fi
  exchange_resp=$(curl -s -u "${CID}:${CSECRET}" \
    -d 'grant_type=urn:ietf:params:oauth:grant-type:token-exchange' \
    -d "subject_token=${subject_token}" \
    -d 'subject_token_type=urn:ietf:params:oauth:token-type:access_token' \
    -d 'requested_token_type=urn:ietf:params:oauth:token-type:access_token' \
    -d "resource=${RESOURCE_2}" \
    -d 'scope=openid' \
    "$TOKEN_URL")
  echo "$exchange_resp" | python3 -c "
import sys, json, base64
resp = json.load(sys.stdin)
if 'access_token' not in resp:
    print('EXCHANGE FAILED:', json.dumps(resp, indent=2)); sys.exit(0)
t = resp['access_token']
p = t.split('.')[1]; p += '=' * (-len(p) % 4)
claims = json.loads(base64.urlsafe_b64decode(p))
print(json.dumps(claims, indent=2))
print('aud present:', 'aud' in claims)
"
}

# 4. refresh_token grant — does it work, and does aud/resource carry over?
test_refresh_token() {
  echo
  echo "=== 4. refresh_token grant (resource=${RESOURCE_1}) ==="
  local cc_resp refresh_token refresh_resp token
  cc_resp=$(curl -s -u "${CID}:${CSECRET}" \
    -d 'grant_type=client_credentials' \
    -d "scope=${SCOPE} offline_access" \
    -d "resource=${RESOURCE_1}" \
    "$TOKEN_URL")
  refresh_token=$(echo "$cc_resp" | python3 -c "import sys,json;print(json.load(sys.stdin).get('refresh_token',''))")
  if [[ -z "$refresh_token" ]]; then
    warn "No refresh_token returned — client may not have 'Issue refresh tokens' enabled, or offline_access scope was dropped/rejected: $cc_resp"
    return 0
  fi
  refresh_resp=$(curl -s -u "${CID}:${CSECRET}" \
    -d 'grant_type=refresh_token' \
    -d "refresh_token=${refresh_token}" \
    -d "resource=${RESOURCE_1}" \
    "$TOKEN_URL")
  token=$(echo "$refresh_resp" | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))")
  if [[ -z "$token" ]]; then
    warn "refresh_token grant FAILED: $refresh_resp"
    return 0
  fi
  python3 -c "
import base64, json
p = '$token'.split('.')[1]; p += '=' * (-len(p) % 4)
claims = json.loads(base64.urlsafe_b64decode(p))
print(json.dumps(claims, indent=2))
print('aud reflects resource= after refresh:', 'aud' in claims and '$RESOURCE_1' in claims.get('aud', []) if isinstance(claims.get('aud'), list) else claims.get('aud') == '$RESOURCE_1')
"
}

# 5. Authorization code flow can't be scripted — just print how to do it manually.
print_auth_code_note() {
  echo
  echo "=== 5. Authorization code flow — manual, can't be scripted ==="
  echo "Point RUCIO_CONFIG at the profile's oidc-client.cfg and run 'rucio whoami'"
  echo "once idpsecrets.json's placeholders are filled in — exercises the browser"
  echo "login and gives you a real user 'sub' for the profile's user-mapping.csv."
}

# ── Main Entry Point ────────────────────────────────────────────────────────

main() {
  validate_args
  resolve_token_endpoint
  test_client_credentials
  test_resource_audience
  test_token_exchange
  test_refresh_token
  print_auth_code_note
}

main
