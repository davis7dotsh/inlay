#!/bin/bash
# Mount the NAS share transcripts on services-01, or check and repair the mount. Run as services-admin:
#   deploy/mount.sh           mount when needed, then check that the share is writable and holds the marker
#   deploy/mount.sh --init    the same, and create the marker .transcriber-hub-share once
# The pattern of agent-traces deploy/nas/mount.sh. hub-run calls it before the hub starts and every
# 15 minutes outside the NAS window. A stale mount is unmounted and mounted again once.
# The hub writes the share only while the marker is there, so it never writes the bare mount point.
set -euo pipefail
umask 077
here="$(cd "$(dirname "$0")" && pwd)"
PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

mount_point="${HUB_SHARE:-$HOME/mnt/nas-transcripts}"
share_url="${HUB_SHARE_URL:-smb://10.10.60.10/transcripts}"
share_user="${HUB_SHARE_USER:-transcripts-writer}"
password_file="${HUB_SHARE_PASSWORD_FILE:-$HOME/.config/transcripts/nas-transcripts-writer-password}"
helper_dir="$HOME/.local/libexec/transcriber-hub"
helper="$helper_dir/nas-mount"
marker="$mount_point/.transcriber-hub-share"

log() { echo "mount.sh: $*"; }
die() { echo "mount.sh: ERROR $*" >&2; exit 1; }
# macOS has no timeout(1). A stale SMB mount can block a file call.
limit() { local s="$1"; shift; perl -e 'alarm shift; exec @ARGV or exit 127' "$s" "$@"; }

is_mounted() { mount | grep -q " on $mount_point (smbfs"; }
is_read_only() { mount | grep " on $mount_point (smbfs" | grep -q "read-only"; }

# Write, read back and delete a small file at the share root. mktemp makes a new name, so the probe
# never writes through a link.
probe() {
  limit 20 /bin/sh -c 'f=$(mktemp "$1/.nas-probe.XXXXXX") && printf probe > "$f" && [ "$(cat "$f")" = probe ] && rm -f "$f"' sh "$mount_point" 2>/dev/null
}

build_helper() {
  if [ ! -x "$helper" ] || [ "$here/nas-mount.swift" -nt "$helper" ]; then
    mkdir -p "$helper_dir"
    log "building $helper"
    local build
    build=$(mktemp -d "$helper_dir/.build.XXXXXX")
    /usr/bin/swiftc -O "$here/nas-mount.swift" -o "$build/nas-mount" -module-cache-path "$build/module-cache"
    mv -fh "$build/nas-mount" "$helper"
    rm -rf "$build"
  fi
}

do_mount() {
  [ -f "$password_file" ] || die "$password_file is missing"
  mkdir -p "$mount_point"
  [ ! -L "$mount_point" ] || die "the mount point $mount_point is a symbolic link"
  chmod 700 "$mount_point"
  # A hub write cut off by a forced unmount can leave empty artifacts folders here. Only empty
  # folders go. Any file stays and stops the mount below.
  find "$mount_point" -mindepth 1 -type d -empty -delete
  # A file in the bare mount point means something wrote into it while the share was gone.
  if [ -n "$(ls -A "$mount_point")" ]; then die "the bare mount point $mount_point is not empty. Nothing was mounted."; fi
  build_helper
  # A NetAuthSysAgent alive from an earlier mount fails each new session with EAUTH 80 (agent-traces,
  # 2026-11-12). Stop it, and launchd starts a fresh one on the next request.
  pkill -TERM -u "$(id -u)" -x NetAuthSysAgent || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -u "$(id -u)" -x NetAuthSysAgent >/dev/null || break; sleep 0.5; done
  pgrep -u "$(id -u)" -x NetAuthSysAgent >/dev/null && die "the old NetAuthSysAgent did not exit"
  limit 60 "$helper" "$share_url" "$mount_point" "$share_user" "$password_file" || die "the mount of $share_url failed"
  is_mounted || die "$share_url is not mounted at $mount_point after the mount"
  log "mounted $share_url at $mount_point"
}

if is_mounted; then
  if limit 20 /bin/test -d "$mount_point/." && ! is_read_only && probe; then
    log "$mount_point is mounted and writable"
  else
    log "$mount_point is stale or read-only. Unmounting it."
    limit 30 /sbin/umount -f "$mount_point" || limit 30 /usr/sbin/diskutil unmount force "$mount_point" || die "cannot unmount the stale mount $mount_point"
    do_mount
  fi
else
  do_mount
fi

is_read_only && die "$mount_point is mounted read-only"
if [ "${1:-}" = "--init" ] && ! limit 20 /bin/test -f "$marker"; then
  limit 20 /bin/sh -c 'printf "{\"share\":\"transcripts\",\"writer\":\"transcriber-hub on services-01\"}\n" > "$1"' sh "$marker"
  log "created $marker"
fi
limit 20 /bin/test -f "$marker" || die "$marker is missing. Run deploy/mount.sh --init once."
probe || die "a write and read-back in $mount_point failed"
log "$mount_point is ready"
