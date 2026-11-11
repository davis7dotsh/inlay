#!/bin/bash
# Documents what carries over when moving setup to the Release server.
# Never moves server data: histories are never touched by a client migration.
set -euo pipefail

data_dir="${INLAY_SERVER_DATA_DIR:-$HOME/Library/Application Support/Inlay/ServerData}"
models_dir="${INLAY_MODEL_DIR:-$HOME/Library/Application Support/Inlay/Models}"
token_file="${INLAY_SERVER_TOKEN_FILE:-$data_dir/admin-token}"

check() { # label path...
    local label="$1"; shift
    local found=0
    for candidate in "$@"; do
        if [[ -e "$candidate" ]]; then printf 'found   %s: %s\n' "$label" "$candidate"; found=1; fi
    done
    if [[ "$found" == 0 ]]; then printf 'missing %s (searched: %s)\n' "$label" "$*" >&2; return 1; fi
}

status=0
check "data directory" "$data_dir" || status=1
check "admin token" "$token_file" || status=1
check "Parakeet model" "$models_dir/ggml-parakeet-tdt-0.6b-v3-f16.bin" "$PWD/.local/models/ggml-parakeet-tdt-0.6b-v3-f16.bin" || status=1
check "Qwen model" "$models_dir/Qwen3-4B-Instruct-2507-MLX-4bit/model.safetensors" "$PWD/.local/models/Qwen3-4B-Instruct-2507-MLX-4bit/model.safetensors" || status=1

if [[ "$status" != 0 ]]; then
    printf 'Fix the missing paths above (or set INLAY_SERVER_DATA_DIR / INLAY_MODEL_DIR / INLAY_SERVER_TOKEN_FILE) and run again.\n' >&2
    exit 1
fi

cat <<'NEXT'

To finish moving to the Release server:
  1. ./scripts/build-server.sh
  2. ./scripts/install-service.sh
  Confirm Inlay connects and dictates, that old history is visible in
  History, then uninstall Inlay Dev from System Settings > General >
  Login Items & Extensions > App Management (if listed).
NEXT
