#!/bin/bash
# Install the hub sync on this Mac from a commit of the Transcriber repo, and load its LaunchAgent:
#   Client/hub-sync/deploy/install.sh [commit]      (default HEAD)
# It copies Client/hub-sync and Hub/src of that commit to ~/.local/share/transcriber-hub-client/
# releases/<commit>/ and points current at it, so the job never runs from a checkout that switches
# branches. It copies config.json and hub-cert.pem to ~/.config/transcriber-hub-client/. The token
# comes from token.sh. It removes nothing but the job's own earlier LaunchAgent registration.
set -euo pipefail
umask 077
repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
commit=$(git -C "$repo" rev-parse "${1:-HEAD}")
share="$HOME/.local/share/transcriber-hub-client"
release="$share/releases/$commit"
config="$HOME/.config/transcriber-hub-client"
label=ai.codecaine.transcriber.hub-sync
plist="$HOME/Library/LaunchAgents/$label.plist"
# The job runs Bun by its absolute path: the one on PATH, else the usual install places.
bun=$(command -v bun || true)
for b in "$bun" "$HOME/.bun/bin/bun" /opt/homebrew/bin/bun /usr/local/bin/bun; do
  if [ -n "$b" ] && [ -x "$b" ]; then bun=$(cd "$(dirname "$b")" && pwd -P)/$(basename "$b"); break; fi
  bun=""
done
[ -n "$bun" ] || { echo "install.sh: no bun found on PATH, in ~/.bun/bin or in Homebrew" >&2; exit 1; }
case "$bun" in *[#\&]*) echo "install.sh: the bun path $bun holds a character the plist edit cannot take" >&2; exit 1;; esac

mkdir -p "$share/releases" "$config" "$HOME/.local/state/transcriber-hub-client" "$HOME/Library/LaunchAgents"
if [ ! -d "$release" ]; then
  tmp=$(mktemp -d "$share/releases/.new.XXXXXX")
  git -C "$repo" archive "$commit" Client/hub-sync Hub/src | tar -x -C "$tmp"
  mv "$tmp" "$release"
fi
ln -sfn "$release" "$share/current"
install -m 644 "$release/Client/hub-sync/config/config.json" "$config/config.json"
install -m 644 "$release/Client/hub-sync/config/hub-cert.pem" "$config/hub-cert.pem"
test -s "$config/token" || echo "install.sh: no token yet, run deploy/token.sh" >&2

sed -e "s#__HOME__#$HOME#g" -e "s#__BUN__#$bun#g" \
  "$release/Client/hub-sync/deploy/$label.plist" > "$plist.new"
plutil -lint "$plist.new" > /dev/null
mv -f "$plist.new" "$plist"
chmod 644 "$plist"
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$plist"
echo "install.sh: $label from $commit with $bun, next run at 23:30"
