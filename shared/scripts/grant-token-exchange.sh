#!/usr/bin/env bash
# grant-token-exchange.sh
# Grants the `fts` client permission to perform standard token-exchange
# targeting the storage audience clients (xrd3, xrd4, teapot) in realm `rucio`.
# Keycloak 23.0.1 — legacy token exchange V1.
set -euo pipefail

KC=compose-keycloak-1
KCADM="/opt/keycloak/bin/kcadm.sh"
REALM=rucio
REQUESTER_CLIENT_ID=fts          # the client making the exchange request
TARGETS=( "https://xrd3:1094" "https://xrd4:1094" "teapot" )

# --- 1. Authenticate kcadm -------------------------------------------------
docker exec "$KC" "$KCADM" config credentials \
  --server http://localhost:8080 \
  --realm master --user admin --password admin

# --- 2. Resolve the requester (fts) client UUID ----------------------------
FTS_UUID=$(docker exec "$KC" "$KCADM" get clients -r "$REALM" \
  -q clientId="$REQUESTER_CLIENT_ID" --fields id --format csv --noquotes | tr -d '\r')
echo "fts client UUID: $FTS_UUID"

# --- 3. For each target client: enable permissions, create policy, bind ----
for TARGET in "${TARGETS[@]}"; do
  echo "=== Configuring token-exchange for target: $TARGET ==="

  TARGET_UUID=$(docker exec "$KC" "$KCADM" get clients -r "$REALM" \
    -q clientId="$TARGET" --fields id --format csv --noquotes | tr -d '\r')
  if [ -z "$TARGET_UUID" ]; then
    echo "  ERROR: target client '$TARGET' not found — is it imported?" >&2
    exit 1
  fi
  echo "  target UUID: $TARGET_UUID"

  # 3a. Enable management permissions on the target client.
  #     This auto-creates the authz resource + the `token-exchange` scope
  #     permission scaffold on the realm-management client.
  docker exec "$KC" "$KCADM" update \
    "clients/$TARGET_UUID/management/permissions" -r "$REALM" \
    -s enabled=true
  echo "  management permissions enabled"

  # 3b. Find the realm-management client UUID (host of the authz config).
  RM_UUID=$(docker exec "$KC" "$KCADM" get clients -r "$REALM" \
    -q clientId=realm-management --fields id --format csv --noquotes | tr -d '\r')

  # 3c. Create a Client policy whose member is the fts client.
  #     Name is unique per target so re-runs are idempotent-ish.
  POLICY_NAME="fts-may-exchange-to-${TARGET}"
  # kcadm rejects some characters in resource names; sanitize for the name only.
  POLICY_NAME_SAFE=$(echo "$POLICY_NAME" | tr -c 'A-Za-z0-9_.-' '_')

  echo "  creating client policy: $POLICY_NAME_SAFE"
  docker exec "$KC" "$KCADM" create \
    "clients/$RM_UUID/authz/resource-server/policy/client" -r "$REALM" \
    -s "name=$POLICY_NAME_SAFE" \
    -s "clients=[\"$FTS_UUID\"]" \
    -s "logic=POSITIVE" \
    || echo "  (policy may already exist — continuing)"

  # 3d. Locate the auto-created token-exchange permission for this target,
  #     and the policy we just made, then bind the policy to the permission.
  POLICY_ID=$(docker exec "$KC" "$KCADM" get \
    "clients/$RM_UUID/authz/resource-server/policy?name=$POLICY_NAME_SAFE" \
    -r "$REALM" --fields id --format csv --noquotes | tr -d '\r' | head -n1)

  # The permission is named like: token-exchange.permission.client.<TARGET_UUID>
  PERM_NAME="token-exchange.permission.client.$TARGET_UUID"
  PERM_ID=$(docker exec "$KC" "$KCADM" get \
    "clients/$RM_UUID/authz/resource-server/permission?name=$PERM_NAME" \
    -r "$REALM" --fields id --format csv --noquotes | tr -d '\r' | head -n1)

  if [ -z "$PERM_ID" ] || [ -z "$POLICY_ID" ]; then
    echo "  ERROR: could not resolve PERM_ID ($PERM_ID) or POLICY_ID ($POLICY_ID)." >&2
    echo "  Inspect manually:" >&2
    echo "    kcadm get clients/$RM_UUID/authz/resource-server/permission -r $REALM" >&2
    exit 1
  fi

  # 3e. Attach the policy to the permission (preserving any existing policies).
  docker exec "$KC" "$KCADM" update \
    "clients/$RM_UUID/authz/resource-server/permission/scope/$PERM_ID" -r "$REALM" \
    -s "policies=[\"$POLICY_ID\"]"
  echo "  policy bound to token-exchange permission"
done

SUBJECT=$(docker exec compose-fts-1 curl -sk -d "client_id=rucio&client_secret=rucio-secret&grant_type=password&username=randomaccount&password=secret" https://keycloak:8443/realms/rucio/protocol/openid-connect/token | python3 -c "import sys,json;print(json.load(sys.stdin)['access_token'])")
echo "${SUBJECT:0:30}..."

for AUD in "https://xrd3:1094" "https://xrd4:1094" "teapot"; do
  echo "--- $AUD ---"
  docker exec compose-fts-1 curl -sk -u "fts:fts-secret" \
    -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
    -d "requested_token_type=urn:ietf:params:oauth:token-type:refresh_token" \
    -d "subject_token_type=urn:ietf:params:oauth:token-type:access_token" \
    -d "subject_token=$SUBJECT" \
    -d "audience=$AUD" \
    https://keycloak:8443/realms/rucio/protocol/openid-connect/token \
    | python3 -c "import sys,json;r=json.load(sys.stdin);print('OK' if 'refresh_token' in r else r)"
done

echo "=== Done ==="
