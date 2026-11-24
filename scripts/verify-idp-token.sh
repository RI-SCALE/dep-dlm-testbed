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
USERINFO_URL="" # set by resolve_token_endpoint, consumed by test_userinfo_entitlements

# ── Logic Blocks ────────────────────────────────────────────────────────────

validate_args() {
  [[ -n "$ISSUER" ]]  || die "--issuer is required"
  [[ -n "$CID" ]]     || die "--client-id is required"
  [[ -n "$CSECRET" ]] || die "client secret required, via --client-secret or \$OIDC_CLIENT_SECRET"
}

resolve_token_endpoint() {
  local discovery
  discovery=$(curl -s "${ISSUER%/}/.well-known/openid-configuration")
  TOKEN_URL=$(echo "$discovery" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d['token_endpoint'])
")
  USERINFO_URL=$(echo "$discovery" | python3 -c "import sys, json; print(json.load(sys.stdin).get('userinfo_endpoint', ''))")
  [[ -n "$TOKEN_URL" ]] || die "could not resolve token_endpoint from ${ISSUER}/.well-known/openid-configuration"
  log "TOKEN_URL=$TOKEN_URL"
}

# 1. client_credentials — does it work at all?
test_client_credentials_baseline() {
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
test_client_credentials_resource_audience() {
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
test_token_exchange_access_token() {
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
aud = claims.get('aud')
ok = aud == '$RESOURCE_2' or (isinstance(aud, list) and '$RESOURCE_2' in aud)
print('aud reflects resource=:', ok)
"
}

# 4. refresh_token grant — does it work, and does aud/resource carry over?
test_refresh_token_grant() {
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
    warn "No refresh_token returned from client_credentials+offline_access."
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

# 5. token-exchange requesting a refresh_token as output — the actual
#    original question (distinct from test 4's ordinary refresh grant).
test_token_exchange_refresh_token() {
  echo
  echo "=== 5. token-exchange requesting requested_token_type=refresh_token ==="
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
    -d 'requested_token_type=urn:ietf:params:oauth:token-type:refresh_token' \
    -d "resource=${RESOURCE_2}" \
    -d 'scope=openid' \
    "$TOKEN_URL")
  echo "$exchange_resp" | python3 -m json.tool
  echo "$exchange_resp" | python3 -c "
import sys, json
resp = json.load(sys.stdin)
if 'refresh_token' in resp:
    print('refresh_token issued by token-exchange: True')
elif resp.get('error') == 'invalid_request' and 'requested_token_type' in resp.get('error_description',''):
    print('requested_token_type=refresh_token NOT SUPPORTED by this deployment')
else:
    print('token-exchange for refresh_token FAILED:', json.dumps(resp, indent=2))
"
}

# 6. Authorization code flow can't be scripted — just print how to do it manually.
print_auth_code_flow_note() {
  echo
  echo "=== 6. Authorization code flow — manual, can't be scripted ==="
  echo "Point RUCIO_CONFIG at the profile's oidc-client.cfg and run 'rucio whoami'"
  echo "once idpsecrets.json's placeholders are filled in — exercises the browser"
  echo "login and gives you a real user 'sub' for the profile's user-mapping.csv."
}

# 7. Entitlements for the client itself — the same lookup as the OPA policy
#    package (permission.py): access-token claims first, then userinfo.
test_userinfo_entitlements() {
  echo
  echo "=== 7. entitlements for this client (access token, then userinfo) ==="
  local token
  token=$(curl -s -u "${CID}:${CSECRET}" \
    -d 'grant_type=client_credentials' \
    -d "scope=${SCOPE}" \
    "$TOKEN_URL" | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))")
  [[ -n "$token" ]] || { warn "token mint FAILED"; return 0; }
  [[ -n "$USERINFO_URL" ]] || { warn "no userinfo_endpoint in discovery"; return 0; }
  curl -s -H "Authorization: Bearer ${token}" "$USERINFO_URL" | TOKEN="$token" python3 -c "
import base64, json, os, sys
p = os.environ['TOKEN'].split('.')[1]; p += '=' * (-len(p) % 4)
claims = json.loads(base64.urlsafe_b64decode(p))
try:
    info = json.load(sys.stdin)
except ValueError:
    info = {}
def ents(d):
    return d.get('entitlements') or d.get('eduperson_entitlement') or []
print('sub              :', claims.get('sub'))
print('token entitlement:', ents(claims) or '-')
print('userinfo         :', json.dumps(info, indent=2) if info else '(empty or error)')
found = ents(claims) or ents(info)
print('entitlement for this client:', bool(found), found or '')
print('=> ODRL assignee possible' if found else '=> no entitlement: whitelist by iss+sub needed')
"
}

# ── Main Entry Point ────────────────────────────────────────────────────────

main() {
  validate_args
  resolve_token_endpoint
  test_client_credentials_baseline
  test_client_credentials_resource_audience
  test_token_exchange_access_token
  test_refresh_token_grant
  test_token_exchange_refresh_token
  print_auth_code_flow_note
  test_userinfo_entitlements
}

main
