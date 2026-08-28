#!/usr/bin/env bash
set -euo pipefail

# ── Global Config ───────────────────────────────────────────────────────────
CERTS="certs"
# Extra SAN entries for the validation-storage externally-facing certs
# (xrd3/xrd4/teapot1/teapot2). Only known once Terraform has reserved the
# static IP (google_compute_address.this.address) — and, once DNS exists,
# once that hostname resolves to it. Pass one or more comma-separated
# entries; each is auto-detected as an IP literal or a DNS name.
#
#   VALSTORAGE_EXTERNAL_SAN="34.159.9.77" ./generate-certs.sh
#   VALSTORAGE_EXTERNAL_SAN="valstorage.dep-dlm-staging.example.com,34.159.9.77" ./generate-certs.sh
#
# Regenerating requires re-running this script AFTER `terraform apply` has
# produced the IP (or hostname), then updating the certs secret and
# rebooting the VM to pick up the new cert — see module README for the
# two-phase apply -> fetch IP -> regenerate certs -> re-apply flow.
VALSTORAGE_EXTERNAL_SAN="${VALSTORAGE_EXTERNAL_SAN:-}"

# ── Helpers ─────────────────────────────────────────────────────────────────

write_ext_file() {
  local out=$1; local dns_list=$2; local profile=$3; local eku
  case $profile in
    server) eku="serverAuth" ;;
    client) eku="clientAuth" ;;
    both)   eku="serverAuth, clientAuth" ;;
  esac
  # IPv4-literal detection: TLS hostname verification checks IP SANs
  # separately from DNS SANs -- an IP address placed in a DNS.n entry
  # will NOT be matched against a client connecting by IP. Route each
  # entry to IP.n or DNS.n based on whether it parses as an IPv4 literal.
  local is_ip_regex='^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'
  {
    echo "[ v3_req ]"
    echo "keyUsage         = digitalSignature, keyEncipherment"
    echo "extendedKeyUsage = $eku"
    echo "subjectAltName   = @alt_names"
    echo -e "\n[ alt_names ]"
    local dns_i=1; local ip_i=1; IFS=',' read -ra names <<< "$dns_list"
    for n in "${names[@]}"; do
      n="${n// /}"
      [ -z "$n" ] && continue
      if [[ "$n" =~ $is_ip_regex ]]; then
        echo "IP.$ip_i = $n"; ip_i=$((ip_i+1))
      else
        echo "DNS.$dns_i = $n"; dns_i=$((dns_i+1))
      fi
    done
  } > "$out"
}

mint_cert() {
  local base=$1; local cn=$2; local extfile=$3
  openssl req -nodes -newkey rsa:2048 -keyout "$CERTS/${base}key.pem" \
    -out "$CERTS/${base}cert.csr" -subj "/CN=${cn}" 2>/dev/null
  openssl x509 -req -days 365 -in "$CERTS/${base}cert.csr" \
    -CA "$CERTS/rucio_ca.pem" -CAkey "$CERTS/rucio_ca.key.pem" -CAcreateserial \
    -extfile "$extfile" -extensions v3_req -out "$CERTS/${base}cert.pem" 2>/dev/null
}

# ── Logic Blocks ────────────────────────────────────────────────────────────

generate_service_certs() {
    # FTS OIDC host cert
    write_ext_file /tmp/fts-ext.cnf "fts,localhost" both
    mint_cert "host" "fts" /tmp/fts-ext.cnf
    cat "$CERTS/hostcert.pem" "$CERTS/hostkey.pem" > "$CERTS/hostcert_with_key.pem"
    chmod 600 "$CERTS/hostkey.pem" "$CERTS/hostcert_with_key.pem"

    # XRootD SciTokens instances
    for host in xrd3 xrd4; do
        local sans="${host},localhost"
        [ -n "$VALSTORAGE_EXTERNAL_SAN" ] && sans="${sans},${VALSTORAGE_EXTERNAL_SAN}"
        write_ext_file "/tmp/${host}-ext.cnf" "$sans" both
        mint_cert "${host}" "${host}" "/tmp/${host}-ext.cnf"
        chmod 644 "$CERTS/${host}key.pem"
    done

    # Teapot instances
    for instance in teapot1 teapot2; do
        local sans="${instance},localhost"
        [ -n "$VALSTORAGE_EXTERNAL_SAN" ] && sans="${sans},${VALSTORAGE_EXTERNAL_SAN}"
        write_ext_file "/tmp/${instance}-ext.cnf" "$sans" server
        mint_cert "${instance}" "${instance}" "/tmp/${instance}-ext.cnf"
        chmod 644 "$CERTS/${instance}key.pem"
    done
    cp "$CERTS/teapot1cert.pem" "$CERTS/teapotcert.pem"
    cp "$CERTS/teapot1key.pem"  "$CERTS/teapotkey.pem"

    # Teapot's internal StoRM-WebDAV localhost cert
    write_ext_file /tmp/storm-webdav-localhost-ext.cnf "localhost" server
    mint_cert "storm-webdav-localhost" "localhost" /tmp/storm-webdav-localhost-ext.cnf
    chmod 644 "$CERTS/storm-webdav-localhostkey.pem"

    # Keycloak
    write_ext_file /tmp/keycloak-ext.cnf "keycloak,localhost" server
    mint_cert "keycloak" "keycloak" /tmp/keycloak-ext.cnf
    chmod 644 "$CERTS/keycloakkey.pem"
}

setup_trust_anchors() {
    echo "=== Preparing Trust Anchors (XRootD-safe mode) ==="
    mkdir -p "$CERTS"

    HASH_NEW=$(openssl x509 -noout -hash -in "$CERTS/rucio_ca.pem")
    HASH_OLD=$(openssl x509 -noout -subject_hash_old -in "$CERTS/rucio_ca.pem")

    for H in "$HASH_NEW" "$HASH_OLD"; do
        cp "$CERTS/rucio_ca.pem" "$CERTS/${H}.0"
        chmod 644 "$CERTS/${H}.0"
    done

    CA_SUBJECT=$(openssl x509 -noout -subject -nameopt compat -in "$CERTS/rucio_ca.pem" | sed 's/^subject=//; s/^\///')

    for H in "$HASH_NEW" "$HASH_OLD"; do
        cat > "$CERTS/${H}.signing_policy" <<EOF
access_id_CA      X509    '${CA_SUBJECT}'
pos_rights        globus  CA:sign
cond_subjects     globus  '/*'
EOF
        chmod 644 "$CERTS/${H}.signing_policy"
    done

    chmod 755 "$CERTS"

    echo "✔ Trust anchors fully materialized (correct permissions)"
}

cleanup_intermediaries() {
    echo "=== Cleaning up CSRs and Temporary Files ==="
    rm -f "$CERTS"/*.csr "$CERTS"/*.srl /tmp/*-ext.cnf
}

# ── Main Entry Point ────────────────────────────────────────────────────────

main() {
    if [[ ! -f "$CERTS/rucio_ca.pem" || ! -f "$CERTS/rucio_ca.key.pem" ]]; then
        echo "ERROR: CA files missing in $CERTS/"
        exit 1
    fi

    generate_service_certs
    setup_trust_anchors
    cleanup_intermediaries

    echo -e "\n=== Certificate Generation Complete ==="
}

main
