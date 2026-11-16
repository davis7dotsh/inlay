#!/bin/bash
# Make the hub's self-signed TLS certificate, as services-admin on services-01:
#   deploy/make-cert.sh <lan address> <tailnet address> [host name ...]
# The key (EC P-256, mode 600) and the certificate go to ~/.config/transcriber-hub/tls/. An existing key
# is kept, so a renewed certificate keeps the same public-key pin. The validity is 825 days, the most
# Apple accepts for a TLS server certificate. It prints the SHA-256 public-key pin (base64 of the
# SHA-256 of the DER SubjectPublicKeyInfo) that the Transcriber Client pins.
# The certificate is its own trust anchor, so it carries CA:TRUE and keyCertSign: Bun, Node and
# BoringSSL refuse a self-signed CA:FALSE certificate given as the CA ("unable to verify the first
# certificate"), measured 2026-11-16.
set -euo pipefail
umask 077
openssl=/opt/homebrew/bin/openssl
[ $# -ge 2 ] || { echo "usage: make-cert.sh <lan address> <tailnet address> [host name ...]" >&2; exit 2; }
dir="$HOME/.config/transcriber-hub/tls"
mkdir -p "$dir"
chmod 700 "$HOME/.config/transcriber-hub" "$dir"
san="IP:$1,IP:$2"
shift 2
for name in "$@"; do san="$san,DNS:$name"; done
if [ ! -f "$dir/key.pem" ]; then
  new=$(mktemp "$dir/.key.XXXXXX")
  "$openssl" genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$new"
  chmod 600 "$new" && mv -fh "$new" "$dir/key.pem"
fi
chmod 600 "$dir/key.pem"
new=$(mktemp "$dir/.cert.XXXXXX")
"$openssl" req -x509 -new -key "$dir/key.pem" -sha256 -days 825 -subj "/CN=transcriber-hub services-01" \
  -addext "subjectAltName=$san" -addext "extendedKeyUsage=serverAuth" \
  -addext "keyUsage=critical,digitalSignature,keyCertSign" -addext "basicConstraints=critical,CA:TRUE" -out "$new"
chmod 644 "$new" && mv -fh "$new" "$dir/cert.pem"
"$openssl" x509 -in "$dir/cert.pem" -noout -subject -enddate -ext subjectAltName
pin=$("$openssl" x509 -in "$dir/cert.pem" -pubkey -noout | "$openssl" pkey -pubin -outform der | "$openssl" dgst -sha256 -binary | base64)
echo "make-cert.sh: public-key pin sha256/$pin"
