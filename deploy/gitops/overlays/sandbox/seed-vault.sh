#!/usr/bin/env bash
# ============================================================================
# seed-vault.sh — load the testbed's existing files into Vault (SANDBOX ONLY)
# ============================================================================
# Mirrors what the umbrella's templates did from files/ symlinks, but writes the
# content into Vault KV so the base ExternalSecrets can project it into the
# testbed-* Secrets. Uses `vault kv put key=@file` (validated: avoids the
# $(cat) empty-on-missing and binary/newline mangling).
#
# Staging/production do NOT run this — an operator seeds the real Vault.
#
# Run from the repo root, against the sandbox Vault:
#   VAULT_POD=vault-0 NS=dep-dlm-sandbox FLOW=managed ./seed-vault.sh
set -euo pipefail

NS="${NS:-dep-dlm-sandbox}"
VAULT_POD="${VAULT_POD:-vault-0}"
FLOW="${FLOW:-managed}"     # managed -> token-exchange cfg, unmanaged -> client-credentials
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# Runtime certs are gitignored (only the CA is committed); generate them if
# missing, mirroring CI's `make certs` step. Needs openssl on the host.
if [[ ! -f "$REPO_ROOT/certs/hostcert.pem" ]]; then
  echo "==> Runtime certs missing — generating (make certs)"
  ( cd "$REPO_ROOT" && bash shared/scripts/generate-certs.sh )
fi

kv() {  # kv <vault-path> <key=@hostfile> ...
  local path="$1"; shift
  local args=() tmp
  for pair in "$@"; do
    local key="${pair%%=@*}" file="${pair#*=@}"
    [[ -f "$REPO_ROOT/$file" ]] || { echo "  skip $key (missing $file)"; continue; }
    tmp="/tmp/seed-$key"
    kubectl -n "$NS" cp "$REPO_ROOT/$file" "$VAULT_POD:$tmp"
    args+=("$key=@$tmp")
  done
  [[ ${#args[@]} -gt 0 ]] && kubectl -n "$NS" exec "$VAULT_POD" -- \
    vault kv put "secret/$path" "${args[@]}"
}

echo "==> Seeding certs"
kv dep-dlm/certs \
  hostcert.pem=@certs/hostcert.pem \
  hostkey.pem=@certs/hostkey.pem \
  hostcert_with_key.pem=@certs/hostcert_with_key.pem \
  rucio_ca.pem=@certs/rucio_ca.pem \
  5fca1cb1.0=@certs/5fca1cb1.0 \
  5fca1cb1.signing_policy=@certs/5fca1cb1.signing_policy \
  b96dc756.0=@certs/b96dc756.0 \
  b96dc756.signing_policy=@certs/b96dc756.signing_policy \
  keycloakcert.pem=@certs/keycloakcert.pem \
  keycloakkey.pem=@certs/keycloakkey.pem \
  xrd3cert.pem=@certs/xrd3cert.pem \
  xrd3key.pem=@certs/xrd3key.pem \
  teapot1cert.pem=@certs/teapot1cert.pem \
  teapot1key.pem=@certs/teapot1key.pem \
  storm-webdav-localhostcert.pem=@certs/storm-webdav-localhostcert.pem \
  storm-webdav-localhostkey.pem=@certs/storm-webdav-localhostkey.pem

echo "==> Seeding configs"
kv dep-dlm/configs \
  fts3config=@shared/config/fts/fts3config \
  gfal2_http_plugin.conf=@shared/config/fts/gfal2_http_plugin.conf \
  realm.json=@shared/config/keycloak/realm.json \
  xrdrucio-scitokens.cfg=@shared/config/xrootd/xrdrucio-scitokens.cfg \
  authdb=@shared/config/xrootd/authdb \
  scitokens.conf=@shared/config/xrootd/scitokens.conf \
  config.ini=@shared/config/teapot/config.ini \
  user-mapping.csv=@shared/config/teapot/user-mapping.csv \
  logback.xml=@shared/config/teapot/logback.xml \
  application.yml=@shared/config/teapot/application.yml \
  data.properties=@shared/config/teapot/data.properties \
  "fts3restconfig=@shared/config/fts/${FLOW}.fts3restconfig"

echo "==> Seeding patches"
kv dep-dlm/patches \
  rucio--fts3.py=@shared/patches/rucio/fts3.py \
  rucio--oidc.py=@shared/patches/rucio/oidc.py \
  rucio--constants.py=@shared/patches/rucio/constants.py \
  fts--middleware.py=@shared/patches/fts/middleware.py \
  fts--openidconnect.py=@shared/patches/fts/openidconnect.py \
  fts--JobBuilder.py=@shared/patches/fts/JobBuilder.py \
  teapot--teapot.py=@shared/patches/teapot/teapot.py

echo "==> Seeding rucio cfg (flow=${FLOW})"
CFG="server.token-exchange.cfg"; [[ "$FLOW" == "unmanaged" ]] && CFG="server.client-credentials.cfg"
kv dep-dlm/rucio \
  "server.cfg=@shared/config/rucio/${CFG}" \
  alembic.ini=@shared/config/rucio/alembic.ini \
  idpsecrets.json=@shared/config/rucio/idpsecrets.json

echo "==> Seeding xrootd scripts"
kv dep-dlm/scripts-xrootd \
  docker-entrypoint.sh=@shared/scripts/xrootd/docker-entrypoint.sh

echo "==> Done. ExternalSecrets will project these into testbed-* Secrets."
