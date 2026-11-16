#!/bin/bash
# Set up the ssh hop of the hub, as services-admin on services-01. Safe to run again.
# The pattern of agent-traces deploy/nas/ssh-hop.sh.
#   1. A key pair for the hub only: ~/.config/transcriber-hub/hub-job-ed25519, mode 600, no passphrase.
#   2. A known_hosts file that pins the ed25519 host key of 127.0.0.1, checked against /etc/ssh.
#   3. One authorized_keys line: restrict, from 127.0.0.1 and ::1 only, forced command hub-run.
#      It backs up authorized_keys first, appends only, and changes no other line.
set -euo pipefail
umask 077
cfg="$HOME/.config/transcriber-hub"
key="$cfg/hub-job-ed25519"
known="$cfg/hub-job-known_hosts"
forced=/usr/local/libexec/transcriber-hub/hub-run
auth="$HOME/.ssh/authorized_keys"
die() { echo "ssh-hop.sh: $*" >&2; exit 1; }
plain() { [ ! -L "$1" ] && { [ ! -e "$1" ] || { [ -f "$1" ] && [ "$(stat -f %l "$1")" = 1 ]; }; }; }
mkdir -p "$cfg"
[ ! -L "$cfg" ] || die "$cfg is a symbolic link"
chmod 700 "$cfg"
for f in "$key" "$key.pub" "$auth"; do plain "$f" || die "$f is a link or not a regular file. Nothing was written."; done
# A first setup can have no authorized_keys yet.
if [ ! -e "$auth" ]; then
  mkdir -p "$(dirname "$auth")"
  [ ! -L "$(dirname "$auth")" ] || die "$(dirname "$auth") is a symbolic link"
  chmod 700 "$(dirname "$auth")"
  ( umask 077 && : > "$auth" )
fi
if [ ! -f "$key" ]; then
  made=$(mktemp -d "$cfg/.hub-job-key.XXXXXX")
  ssh-keygen -q -t ed25519 -N "" -C "transcriber-hub@services-01" -f "$made/key"
  mv -fh "$made/key.pub" "$key.pub" && mv -fh "$made/key" "$key" && rmdir "$made"
fi
chmod 600 "$key"
host_key=$(cut -d' ' -f1,2 /etc/ssh/ssh_host_ed25519_key.pub)
scanned=$(ssh-keyscan -T 5 -t ed25519 127.0.0.1 2>/dev/null | grep -v '^#' | cut -d' ' -f2,3)
[ "$host_key" = "$scanned" ] || die "the key 127.0.0.1 shows is not /etc/ssh/ssh_host_ed25519_key.pub"
new=$(mktemp "$cfg/.hub-job-known_hosts.XXXXXX")
printf '127.0.0.1 %s\n' "$host_key" > "$new" && mv -fh "$new" "$known"
body=$(cut -d' ' -f1,2 "$key.pub")
if grep -qF "$body" "$auth"; then
  echo "ssh-hop.sh: authorized_keys already holds the hub key"
else
  bak=$(mktemp "$auth.bak-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")
  cat "$auth" > "$bak"
  new=$(mktemp "$(dirname "$auth")/.authorized_keys.XXXXXX")
  cat "$auth" > "$new"
  printf 'restrict,from="127.0.0.1,::1",command="%s" %s transcriber-hub@services-01\n' "$forced" "$body" >> "$new"
  chmod "$(stat -f %Lp "$auth")" "$new" && mv -fh "$new" "$auth"
  echo "ssh-hop.sh: appended the hub key to authorized_keys. The file before is $(basename "$bak")"
fi
grep -F "$body" "$auth" | sed -E 's/(ssh-ed25519 )[A-Za-z0-9+\/=]+/\1<key>/'
