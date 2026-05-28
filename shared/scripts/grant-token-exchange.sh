#!/usr/bin/env bash
# grant-token-exchange.sh
# Grants the `rucio` and `fts` clients permission to perform standard
# token-exchange targeting the storage audience clients (xrd3, xrd4,
# teapot1, teapot2) in realm `rucio`.
#
# Two exchanges happen in the managed-token flow, by two different clients:
#   1. Rucio, at submission time (core/oidc.py), authenticates as `rucio`
#      and exchanges the seeded subject token into per-RSE-audienced
#      source/destination tokens for FTS.
#   2. FTS-server TokenExchangeService authenticates as `fts` (per the
#      t_token_provider row) and exchanges those into refresh tokens.
# Both requesters therefore need the FGAP token-exchange permission.
# Keycloak 23.0.1 — legacy token exchange V1.
set -euo pipefail

RUNTIME="${RUNTIME:-compose}"
K8S_NAMESPACE="${K8S_NAMESPACE:-dep-dlm-testbed}"

KCADM="/opt/keycloak/bin/kcadm.sh"
REALM=rucio
REQUESTERS=( "fts" "rucio" )       # every client that performs token-exchange
TARGETS=( "xrd3" "xrd4" "teapot1" "teapot2" )

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
                keycloak|fts|rucio)
                    target="deploy/${svc}"
                    cflag=(-c "$svc")
                    ;;
                *)
                    target="deploy/${svc}"
                    ;;
            esac

            kubectl -n "$K8S_NAMESPACE" exec \
                "$target" "${cflag[@]}" -- "$@"
            ;;

        *)
            echo "Unknown RUNTIME: $RUNTIME" >&2
            exit 2
            ;;
    esac
}

# --- 1. Authenticate kcadm -------------------------------------------------
_exec keycloak "$KCADM" config credentials \
  --server http://localhost:8080 \
  --realm master --user admin --password admin

# --- 2. Resolve every requester client UUID --------------------------------
REQUESTER_UUIDS=()
for RC in "${REQUESTERS[@]}"; do
  UUID=$(_exec keycloak "$KCADM" get clients -r "$REALM" \
    -q clientId="$RC" --fields id --format csv --noquotes | tr -d '\r')
  if [ -z "$UUID" ]; then
    echo "  ERROR: requester client '$RC' not found" >&2
    exit 1
  fi
  echo "requester $RC UUID: $UUID"
  REQUESTER_UUIDS+=( "$UUID" )
done
# JSON array of all requester UUIDs, e.g. ["uuid1","uuid2"]
REQUESTER_UUIDS_JSON=$(printf '"%s",' "${REQUESTER_UUIDS[@]}")
REQUESTER_UUIDS_JSON="[${REQUESTER_UUIDS_JSON%,}]"

# --- 3. For each target client: enable permissions, create policy, bind ----
for TARGET in "${TARGETS[@]}"; do
  echo "=== Configuring token-exchange for target: $TARGET ==="

  TARGET_UUID=$(_exec keycloak "$KCADM" get clients -r "$REALM" \
    -q clientId="$TARGET" --fields id --format csv --noquotes | tr -d '\r')
  if [ -z "$TARGET_UUID" ]; then
    echo "  ERROR: target client '$TARGET' not found — is it imported?" >&2
    exit 1
  fi
  echo "  target UUID: $TARGET_UUID"

  _exec keycloak "$KCADM" update \
    "clients/$TARGET_UUID/management/permissions" -r "$REALM" \
    -s enabled=true
  echo "  management permissions enabled"

  RM_UUID=$(_exec keycloak "$KCADM" get clients -r "$REALM" \
    -q clientId=realm-management --fields id --format csv --noquotes | tr -d '\r')

  # Client policy whose members are ALL requester clients (fts + rucio).
  POLICY_NAME="exchange-to-${TARGET}"
  POLICY_NAME_SAFE=$(echo "$POLICY_NAME" | tr -c 'A-Za-z0-9_.-' '_')

  echo "  creating client policy: $POLICY_NAME_SAFE  members=$REQUESTER_UUIDS_JSON"
  _exec keycloak "$KCADM" create \
    "clients/$RM_UUID/authz/resource-server/policy/client" -r "$REALM" \
    -s "name=$POLICY_NAME_SAFE" \
    -s "clients=$REQUESTER_UUIDS_JSON" \
    -s "logic=POSITIVE" \
    || echo "  (policy may already exist — updating it instead)"

  POLICY_ID=$(_exec keycloak "$KCADM" get \
    "clients/$RM_UUID/authz/resource-server/policy?name=$POLICY_NAME_SAFE" \
    -r "$REALM" --fields id --format csv --noquotes | tr -d '\r' | head -n1)

  # If the policy already existed, make sure it lists BOTH requesters
  # (a stale single-client policy from an earlier run would still permit
  # only fts — update it in place).
  if [ -n "$POLICY_ID" ]; then
    _exec keycloak "$KCADM" update \
      "clients/$RM_UUID/authz/resource-server/policy/client/$POLICY_ID" -r "$REALM" \
      -s "clients=$REQUESTER_UUIDS_JSON" \
      || echo "  (could not update policy membership — check manually)"
  fi

  PERM_NAME="token-exchange.permission.client.$TARGET_UUID"
  PERM_ID=$(_exec keycloak "$KCADM" get \
    "clients/$RM_UUID/authz/resource-server/permission?name=$PERM_NAME" \
    -r "$REALM" --fields id --format csv --noquotes | tr -d '\r' | head -n1)

  if [ -z "$PERM_ID" ] || [ -z "$POLICY_ID" ]; then
    echo "  ERROR: could not resolve PERM_ID ($PERM_ID) or POLICY_ID ($POLICY_ID)." >&2
    exit 1
  fi

  _exec keycloak "$KCADM" update \
    "clients/$RM_UUID/authz/resource-server/permission/scope/$PERM_ID" -r "$REALM" \
    -s "policies=[\"$POLICY_ID\"]"
  echo "  policy bound to token-exchange permission"
done

# --- 4. Self-test: exchange as EACH requester, for each target -------------
SUBJECT=$(_exec fts curl -sk \
  -d "client_id=rucio&client_secret=rucio-secret&grant_type=password&username=randomaccount&password=secret" \
  https://keycloak:8443/realms/rucio/protocol/openid-connect/token \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['access_token'])")
echo "subject token: ${SUBJECT:0:30}..."

declare -A SECRET=( [fts]=fts-secret [rucio]=rucio-secret )
for RC in "${REQUESTERS[@]}"; do
  for AUD in "${TARGETS[@]}"; do
    echo -n "--- exchange as $RC -> $AUD : "
    _exec fts curl -sk -u "$RC:${SECRET[$RC]}" \
      -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
      -d "requested_token_type=urn:ietf:params:oauth:token-type:refresh_token" \
      -d "subject_token_type=urn:ietf:params:oauth:token-type:access_token" \
      -d "subject_token=$SUBJECT" \
      -d "audience=$AUD" \
      https://keycloak:8443/realms/rucio/protocol/openid-connect/token \
      | python3 -c "import sys,json;r=json.load(sys.stdin);print('OK' if 'refresh_token' in r else r)"
  done
done

echo "=== Done ==="
