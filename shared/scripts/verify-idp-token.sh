#!/usr/bin/env bash
# verify-idp-token.sh — manual token checks against any OIDC issuer/client
# registered for this testbed, before trusting a profile's config files.
#
# Confirms three things config files can't verify on their own:
#   1. client_credentials works at all with this client
#   2. resource= actually stamps the aud claim (RFC 8707)
#   3. token-exchange, if the client has it enabled
#
# Usage:
#   shared/scripts/verify-idp-token.sh \
#     --issuer <issuer> --client-id <id> --client-secret <secret> \
#     [--scope "openid ..."] [--resources "https://a/ https://b/ ..."]
#
# client secret can also come via $OIDC_CLIENT_SECRET env var instead of
# --client-secret, to avoid it showing up in shell history / process list.
#
# Example — egi-dev:
#   OIDC_CLIENT_SECRET=... shared/scripts/verify-idp-token.sh \
#     --issuer https://aai-dev.egi.eu/auth/realms/egi \
#     --client-id 699e9e29-29e8-4220-8863-5306d8a7feb8 \
#     --scope "openid profile eduperson_entitlement offline_access read:/ write:/"
#
# Example — lsaai-dev:
#   OIDC_CLIENT_SECRET=... shared/scripts/verify-idp-token.sh \
#     --issuer https://login.aai.lifescience-ri.eu/oidc/ \
#     --client-id 4ff05c0b-1d83-42b7-a00a-8bd162df4165 \
#     --scope "openid profile email offline_access eduperson_entitlement"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh disable=SC1091
source "${SCRIPT_DIR}/common.sh"

ISSUER=""
CID=""
CSECRET="${OIDC_CLIENT_SECRET:-}"
SCOPE="openid"
# Defaults match this testbed's example RSE audiences (conftest.py's
# _rse_resource() pattern) — override with --resources for a different set.
RESOURCES="https://xrd3.example.org/ https://xrd4.example.org/ https://teapot1.example.org/ https://teapot2.example.org/"

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

[[ -n "$ISSUER" ]]   || die "--issuer is required"
[[ -n "$CID" ]]       || die "--client-id is required"
[[ -n "$CSECRET" ]]   || die "client secret required, via --client-secret or \$OIDC_CLIENT_SECRET"

read -r -a RESOURCE_ARR <<< "$RESOURCES"
RESOURCE_1="${RESOURCE_ARR[0]}"
RESOURCE_2="${RESOURCE_ARR[1]:-${RESOURCE_ARR[0]}}"

TOKEN_URL=$(curl -s "${ISSUER%/}/.well-known/openid-configuration" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d['token_endpoint'])
")
[[ -n "$TOKEN_URL" ]] || die "could not resolve token_endpoint from ${ISSUER}/.well-known/openid-configuration"
log "TOKEN_URL=$TOKEN_URL"

# ── 1. client_credentials — does it work at all? ────────────────────────
echo "=== 1. client_credentials ==="
RESP1=$(curl -s -u "${CID}:${CSECRET}" \
  -d 'grant_type=client_credentials' \
  -d "scope=${SCOPE}" \
  "$TOKEN_URL")
echo "$RESP1" | python3 -m json.tool
echo "$RESP1" | python3 -c "import sys,json; sys.exit(0 if 'access_token' in json.load(sys.stdin) else 1)" \
  || { warn "client_credentials FAILED — stopping here, tests 2/3 need a working token first"; exit 1; }

# ── 2. client_credentials + resource= — does aud reflect it? ────────────
echo
echo "=== 2. client_credentials + resource=${RESOURCE_1} ==="
RESP2=$(curl -s -u "${CID}:${CSECRET}" \
  -d 'grant_type=client_credentials' \
  -d "scope=${SCOPE}" \
  -d "resource=${RESOURCE_1}" \
  "$TOKEN_URL")
TOKEN2=$(echo "$RESP2" | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))")
if [[ -z "$TOKEN2" ]]; then
  warn "resource= request FAILED: $RESP2"
else
  python3 -c "
import base64, json
p = '$TOKEN2'.split('.')[1]; p += '=' * (-len(p) % 4)
claims = json.loads(base64.urlsafe_b64decode(p))
print(json.dumps(claims, indent=2))
print('aud reflects resource=:', 'aud' in claims and '$RESOURCE_1' in claims.get('aud', []) if isinstance(claims.get('aud'), list) else claims.get('aud') == '$RESOURCE_1')
"
fi

# ── 3. token-exchange, if enabled on this client ─────────────────────────
echo
echo "=== 3. token-exchange (${RESOURCE_1} -> ${RESOURCE_2}) ==="
SUBJECT_RESP=$(curl -s -u "${CID}:${CSECRET}" \
  -d 'grant_type=client_credentials' \
  -d "resource=${RESOURCE_1}" \
  -d 'scope=openid' \
  "$TOKEN_URL")
SUBJECT_TOKEN=$(echo "$SUBJECT_RESP" | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))")
if [[ -z "$SUBJECT_TOKEN" ]]; then
  warn "subject token mint FAILED: $SUBJECT_RESP"
else
  EXCHANGE_RESP=$(curl -s -u "${CID}:${CSECRET}" \
    -d 'grant_type=urn:ietf:params:oauth:grant-type:token-exchange' \
    -d "subject_token=${SUBJECT_TOKEN}" \
    -d 'subject_token_type=urn:ietf:params:oauth:token-type:access_token' \
    -d 'requested_token_type=urn:ietf:params:oauth:token-type:access_token' \
    -d "resource=${RESOURCE_2}" \
    -d 'scope=openid' \
    "$TOKEN_URL")
  echo "$EXCHANGE_RESP" | python3 -c "
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
fi

echo
echo "=== 4. Authorization code flow — manual, can't be scripted ==="
echo "Point RUCIO_CONFIG at the profile's oidc-client.cfg and run 'rucio whoami'"
echo "once idpsecrets.json's placeholders are filled in — exercises the browser"
echo "login and gives you a real user 'sub' for the profile's user-mapping.csv."
