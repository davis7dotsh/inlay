#!/bin/bash
# Mount one NAS share read-only as nas-status at its own folder, run one command, and unmount the
# share on every way out. Run as services-admin:
#   deploy/mount-ro.sh <share> <mount point> -- <command> [args...]
# The NAS status job (src/nas-status.ts) lists the newest backup folders of the agents share
# through it. hub-run runs it once a day. The command runs whether the mount worked or not, with one of these set:
#   NAS_RO_MOUNT   the mount point, when the share is mounted read-only there
#   NAS_RO_ERROR   why the share is not mounted, when the mount failed
# One sign-in per run: the helper runs at most once and a failed mount is never tried again, so
# the run cannot reach the NAS lockout (10 failed sign-ins in 5 minutes).
# Settings (environment):
#   NAS_RO_HOST           default 10.10.60.10
#   NAS_RO_USER           default nas-status
#   NAS_RO_PASSWORD_FILE  default ~/.config/transcriber-hub/nas-status-password (mode 600)
#   NAS_MOUNT_HELPER      default ~/.local/libexec/transcriber-hub/nas-mount, the hub's helper. It is
#                         built from deploy/nas-mount.swift when it is missing or older, as mount.sh does.
# Mount rules from cp1: a mount folder under /tmp fails with error 62 (/tmp is a link), so the
# mount point must be outside it. NetAuthSysAgent is stopped first, or the mount fails with error 80.
# It never mounts in the NAS window, 10:57 to 12:00 UTC (exit 75, the command does not run). It checks
# the window at the start and again right before the sign-in, after the helper build.
# The mount point is made canonical once (no trailing slash, no linked parent folder), and that one
# path is used for each mount check and the unmount, as /sbin/mount prints it.
set -uo pipefail
umask 077
here="$(cd "$(dirname "$0")" && pwd)"
PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

log() { echo "mount-ro.sh: $*" >&2; }
die() { echo "mount-ro.sh: ERROR $*" >&2; exit 1; }
# macOS has no timeout(1). A stale SMB mount can block a file call.
limit() { local s="$1"; shift; perl -e 'alarm shift; exec @ARGV or exit 127' "$s" "$@"; }

[ $# -ge 4 ] && [ "$3" = "--" ] || die "usage: mount-ro.sh <share> <mount point> -- <command> [args...]"
share="$1"
mount_point="$2"
shift 3
[[ "$share" =~ ^[A-Za-z0-9_-]+$ ]] || die "the share name $share may hold only letters, digits, _ and -"
case "$mount_point" in
  /*) ;;
  *) die "the mount point $mount_point must be an absolute path" ;;
esac
# The canonical path: no trailing slashes, and the parent folder with its links resolved. The last
# part stays as it is, so prepare() still refuses a mount point that is itself a link.
while [ "${mount_point%/}" != "$mount_point" ]; do mount_point="${mount_point%/}"; done
base="$(basename "$mount_point")"
case "$base" in
  "" | . | ..) die "the mount point $2 must name a folder" ;;
esac
parent="$(dirname "$mount_point")"
mkdir -p "$parent" || die "cannot make $parent"
parent="$(cd "$parent" && pwd -P)" || die "cannot resolve $parent"
mount_point="${parent%/}/$base"
case "$mount_point" in
  /tmp/* | /private/tmp/*) die "the mount point $mount_point is under /tmp, which fails with error 62. Use ~/mnt." ;;
esac
host="${NAS_RO_HOST:-10.10.60.10}"
user="${NAS_RO_USER:-nas-status}"
password_file="${NAS_RO_PASSWORD_FILE:-$HOME/.config/transcriber-hub/nas-status-password}"
helper="${NAS_MOUNT_HELPER:-$HOME/.local/libexec/transcriber-hub/nas-mount}"
share_url="smb://$host/$share"

in_window() { local m=$((10#$(date -u +%H%M))); [ "$m" -ge 1057 ] && [ "$m" -lt 1200 ]; }
if in_window; then
  log "it is 10:57 to 12:00 UTC, the NAS window. Nothing was mounted or run."
  exit 75
fi

is_mounted() { mount | grep -qF " on $mount_point (smbfs"; }
is_read_only() { mount | grep -F " on $mount_point (smbfs" | grep -q "read-only"; }

unmount() {
  is_mounted || return 0
  limit 30 /sbin/umount "$mount_point" 2>/dev/null ||
    limit 30 /sbin/umount -f "$mount_point" 2>/dev/null ||
    limit 30 /usr/sbin/diskutil unmount force "$mount_point" >/dev/null 2>&1
  ! is_mounted
}

child=""
mounted_here=""
# shellcheck disable=SC2329 # the EXIT trap below calls it
cleanup() {
  local rc=$?
  trap - EXIT INT TERM HUP ALRM
  if [ -n "$child" ] && kill -0 "$child" 2>/dev/null; then
    kill -TERM "$child" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$child" 2>/dev/null || break; sleep 1; done
    kill -KILL "$child" 2>/dev/null
    # Reap it, so its open files on the share are closed before the unmount.
    wait "$child" 2>/dev/null
  fi
  if [ -n "$mounted_here" ] && is_mounted; then
    if unmount; then
      log "unmounted $mount_point"
    else
      log "ERROR cannot unmount $mount_point"
      rc=1
    fi
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP
trap 'exit 142' ALRM

build_helper() {
  if [ ! -x "$helper" ] || [ "$here/nas-mount.swift" -nt "$helper" ]; then
    mkdir -p "$(dirname "$helper")"
    log "building $helper"
    local build
    build=$(mktemp -d "$(dirname "$helper")/.build.XXXXXX") || return 1
    /usr/bin/swiftc -O "$here/nas-mount.swift" -o "$build/nas-mount" -module-cache-path "$build/module-cache" &&
      mv -fh "$build/nas-mount" "$helper"
    local rc=$?
    rm -rf "$build"
    return "$rc"
  fi
}

# Every step before the one mount try. Its output is the reason when it fails.
prepare() {
  [ -f "$password_file" ] || { echo "the password file $password_file is missing"; return 1; }
  # A mount that an earlier run left behind is unmounted first. That needs no sign-in.
  if is_mounted; then
    unmount || { echo "a mount that an earlier run left at $mount_point does not unmount"; return 1; }
  fi
  mkdir -p "$mount_point" || { echo "cannot make $mount_point"; return 1; }
  [ ! -L "$mount_point" ] || { echo "the mount point $mount_point is a symbolic link"; return 1; }
  chmod 700 "$mount_point"
  if [ -n "$(ls -A "$mount_point")" ]; then echo "the bare mount point $mount_point is not empty"; return 1; fi
  build_helper >&2 || { echo "the build of $helper failed"; return 1; }
  # A NetAuthSysAgent alive from an earlier mount fails each new session with error 80. Stop it,
  # and launchd starts a fresh one on the next request (as mount.sh does).
  pkill -TERM -u "$(id -u)" -x NetAuthSysAgent || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -u "$(id -u)" -x NetAuthSysAgent >/dev/null || break; sleep 0.5; done
  if pgrep -u "$(id -u)" -x NetAuthSysAgent >/dev/null; then echo "the old NetAuthSysAgent did not exit"; return 1; fi
}

unset NAS_RO_MOUNT NAS_RO_ERROR
if ! reason=$(prepare); then
  export NAS_RO_ERROR="$reason. No sign-in was tried."
  log "$NAS_RO_ERROR"
else
  # prepare() can take up to 2 minutes (an old unmount, the helper build). Check the window again.
  if in_window; then
    log "the NAS window started at 10:57 UTC during the preparation. Nothing was mounted or run."
    exit 75
  fi
  # The one sign-in of this run. A failure is never tried again.
  mounted_here=1
  if ! out=$(limit 60 "$helper" "$share_url" "$mount_point" "$user" "$password_file" --read-only 2>&1); then
    last=$(printf '%s' "$out" | tail -n 1 | cut -c1-200)
    export NAS_RO_ERROR="the mount of $share_url as $user failed: $last"
    log "$NAS_RO_ERROR"
  elif ! is_mounted; then
    export NAS_RO_ERROR="$share_url is not mounted at $mount_point after the mount"
    log "$NAS_RO_ERROR"
  elif ! is_read_only; then
    unmount
    export NAS_RO_ERROR="$share_url mounted read-write at $mount_point, so it was unmounted and not read"
    log "$NAS_RO_ERROR"
  else
    export NAS_RO_MOUNT="$mount_point"
    log "mounted $share_url read-only as $user at $mount_point"
  fi
fi

# The command runs as a child, so a signal reaches the traps above while it runs.
"$@" &
child=$!
wait "$child"
rc=$?
child=""
exit "$rc"
