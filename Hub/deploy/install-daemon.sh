#!/bin/bash
# Install the Transcriber Hub LaunchDaemon on services-01. Run as root:
#   fleet-sudo services-01 /usr/bin/env HUB_APP=<app folder> HUB_HOSTS=<lan>,<tailnet> /bin/bash <app>/deploy/install-daemon.sh [--files-only]
# Settings (environment):
#   HUB_APP     the folder the hub runs from (a copy of Hub/). Required, absolute.
#   HUB_HOSTS   the addresses the hub listens on, comma separated. Required. Never a wildcard.
#   HUB_PORT    default 8797
# It installs hub-job (the ssh hop) and hub-run (the forced command, with the settings filled in) to
# /usr/local/libexec/transcriber-hub/, root-owned, so services-admin cannot change what the key runs.
# Without --files-only it also installs and loads the LaunchDaemon ai.codecaine.transcriber-hub.
# Before: deploy/make-cert.sh, deploy/mount.sh --init and deploy/ssh-hop.sh as services-admin.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "install-daemon.sh: run as root" >&2; exit 1; }
here="$(cd "$(dirname "$0")" && pwd)"
label=ai.codecaine.transcriber-hub
plist="/Library/LaunchDaemons/$label.plist"
libexec=/usr/local/libexec/transcriber-hub
cfg=/Users/services-admin/.config/transcriber-hub
app="${HUB_APP:-}"
hosts="${HUB_HOSTS:-}"
port="${HUB_PORT:-8797}"
case "$app" in /*) ;; *) echo "install-daemon.sh: set HUB_APP to an absolute path" >&2; exit 1;; esac
# hub-run takes the path as a bare shell word, and sed takes it as a replacement text.
[[ "$app" =~ ^[A-Za-z0-9/._-]+$ ]] || { echo "install-daemon.sh: HUB_APP may hold only letters, digits and / . _ -" >&2; exit 1; }
[ -f "$app/src/main.ts" ] || { echo "install-daemon.sh: $app/src/main.ts is missing" >&2; exit 1; }
[[ "$hosts" =~ ^[0-9.]+(,[0-9.]+)*$ ]] || { echo "install-daemon.sh: HUB_HOSTS must be a comma list of IPv4 addresses" >&2; exit 1; }
case ",$hosts," in *,0.0.0.0,*) echo "install-daemon.sh: HUB_HOSTS must not hold 0.0.0.0" >&2; exit 1;; esac
[[ "$port" =~ ^[0-9]+$ ]] || { echo "install-daemon.sh: HUB_PORT must be a number" >&2; exit 1; }
for f in hub-job-ed25519 hub-job-known_hosts tls/cert.pem tls/key.pem; do
  [ -f "$cfg/$f" ] || { echo "install-daemon.sh: $cfg/$f is missing. See the steps at the top of this file." >&2; exit 1; }
done
# Put stdin at <path> with <mode>, root-owned, through a new temp name and mv -h.
place() {
  local new
  new=$(mktemp "$(dirname "$1")/.$(basename "$1").XXXXXX")
  cat > "$new"
  chown root:wheel "$new" && chmod "$2" "$new" && mv -fh "$new" "$1"
}
install -d -m 755 -o root -g wheel "$libexec"
place "$libexec/hub-job" 755 < "$here/hub-job"
sed -e "s|@APP@|$app|" -e "s|@HOSTS@|$hosts|" -e "s|@PORT@|$port|" "$here/hub-run" | place "$libexec/hub-run" 755
echo "install-daemon.sh: installed $libexec/hub-job and $libexec/hub-run (app $app, hosts $hosts, port $port)"
[ "${1:-}" = "--files-only" ] && exit 0

plutil -lint "$here/$label.plist"
install -d -m 700 -o services-admin -g staff /Users/services-admin/transcriber-hub-logs
place "$plist" 644 < "$here/$label.plist"
loaded() { launchctl print "system/$label" >/dev/null 2>&1; }
if loaded; then
  launchctl bootout "system/$label" || true
  for _ in $(seq 1 60); do loaded || break; sleep 1; done
  if loaded; then echo "install-daemon.sh: $label did not unload in 60 s" >&2; exit 1; fi
fi
launchctl bootstrap system "$plist"
launchctl enable "system/$label"
echo "install-daemon.sh: $label loaded"
