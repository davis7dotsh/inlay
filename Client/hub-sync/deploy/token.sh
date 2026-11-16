#!/bin/bash
# Put the MacBook's hub token in ~/.config/transcriber-hub-client/token (mode 600). Run on the MacBook:
#   Client/hub-sync/deploy/token.sh
# Infisical holds it in project core, env dev, folder /transcriber-hub, as TRANSCRIBER_HUB_TOKEN_MACBOOK.
# It goes from Infisical to the file over a pipe. It is never printed or put on a command line.
# It lands in a new file that mktemp made, and mv -h puts it in place without following a link.
set -euo pipefail
umask 077
PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
project="${INFISICAL_CORE_PROJECT_ID:-45806d3b-d5d1-47e2-9627-b164873ff62c}"
dir="$HOME/.config/transcriber-hub-client"
mkdir -p "$dir"
f=$(mktemp "$dir/.token.XXXXXX")
trap 'rm -f "$f"' EXIT
infisical secrets get TRANSCRIBER_HUB_TOKEN_MACBOOK --projectId "$project" --env dev --path /transcriber-hub --plain --silent \
  | tr -d '\r\n' > "$f"
test -s "$f"
chmod 600 "$f"
mv -fh "$f" "$dir/token"
echo "token.sh: wrote $dir/token, $(wc -c < "$dir/token" | tr -d ' ') bytes, mode $(stat -f %Lp "$dir/token")"
