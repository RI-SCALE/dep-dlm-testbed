#!/usr/bin/env bash
# fetch-odrl-policies.sh — print the DEP ODRL policies from the WP4 policy repository.
# Needs ODRL_CLIENT_ID / ODRL_CLIENT_SECRET (EGI Check-in dev client with policies:read).
set -euo pipefail
: "${ODRL_CLIENT_ID:?}" "${ODRL_CLIENT_SECRET:?}"
TE="${ODRL_TOKEN_ENDPOINT:-https://aai-dev.egi.eu/auth/realms/egi/protocol/openid-connect/token}"
API="${ODRL_API_ENDPOINT:-https://odrl-repo.dep.dev.rciam.grnet.gr/policies}"

BT=$(curl -fsS -u "$ODRL_CLIENT_ID:$ODRL_CLIENT_SECRET" \
  -d grant_type=client_credentials -d scope=policies:read "$TE" | jq -r .access_token)
[[ "$BT" != "null" ]] || { echo "token request failed" >&2; exit 1; }

curl -fsS "${API}?limit=100" -H "Authorization: Bearer $BT" \
  | jq '{total, policies: [.items[].odrlPolicy]}'
