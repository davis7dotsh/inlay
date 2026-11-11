#!/bin/bash
set -euo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
    printf 'install-service.sh is macOS-only; Linux uses Server/inlay-server.service.\n' >&2
    exit 1
fi

project_dir=$(cd "$(dirname "$0")/.." && pwd)
label="dev.davis.inlay.server-agent"
plist_path="$HOME/Library/LaunchAgents/$label.plist"
server_dir="${INLAY_SERVER_PACKAGE_DIR:-$project_dir/build/server}"
data_dir="${INLAY_SERVER_DATA_DIR:-$HOME/Library/Application Support/Inlay/ServerData}"
models_dir="${INLAY_MODEL_DIR:-$HOME/Library/Application Support/Inlay/Models}"
token_file="${INLAY_SERVER_TOKEN_FILE:-$data_dir/admin-token}"
log_dir="$HOME/Library/Logs/Inlay"
domain="gui/$(id -u)"

if [[ "${1:-}" == --uninstall ]]; then
    launchctl bootout "$domain/$label" 2>/dev/null || true
    rm -f "$plist_path"
    printf 'Removed the Inlay server agent. Data and models are kept.\n'
    exit 0
fi

test -x "$server_dir/inlay-server" ||
    { printf 'No server package at %s; run ./scripts/build-server.sh or set INLAY_SERVER_PACKAGE_DIR.\n' "$server_dir" >&2; exit 1; }

if curl -fsS http://127.0.0.1:8391/v1/liveness >/dev/null 2>&1; then
    printf 'Something already answers on 127.0.0.1:8391; stop it (or it may already be your server) and retry.\n' >&2
    exit 1
fi

# sed works line by line, so a newline would cut the rendered plist short.
for value in "$server_dir" "$data_dir" "$models_dir" "$token_file" "$log_dir"; do
    if [[ "$value" == *$'\n'* ]]; then
        printf 'Paths cannot contain newlines: %q\n' "$value" >&2
        exit 1
    fi
done

# Values land in plist <string> text through a sed replacement: XML-escape
# them, then escape the replacement's own metacharacters (\, &, and |).
plist_value() {
    local value=$1
    value=${value//'&'/'&amp;'}
    value=${value//'<'/'&lt;'}
    value=${value//'>'/'&gt;'}
    value=${value//'\'/'\\'}
    value=${value//'&'/'\&'}
    value=${value//'|'/'\|'}
    printf '%s' "$value"
}

mkdir -p "$data_dir" "$log_dir" "$HOME/Library/LaunchAgents"
chmod 700 "$data_dir"
umask 077
sed \
    -e "s|__LABEL__|$(plist_value "$label")|g" \
    -e "s|__SERVER_DIR__|$(plist_value "$server_dir")|g" \
    -e "s|__DATA_DIR__|$(plist_value "$data_dir")|g" \
    -e "s|__MODELS_DIR__|$(plist_value "$models_dir")|g" \
    -e "s|__TOKEN_FILE__|$(plist_value "$token_file")|g" \
    -e "s|__LOG_DIR__|$(plist_value "$log_dir")|g" \
    "$project_dir/Server/dev.davis.inlay.server-agent.plist" > "$plist_path"

if [[ ! -f "$token_file" ]]; then
    mkdir -p "$(dirname "$token_file")"
    openssl rand -hex 32 > "$token_file"
    chmod 600 "$token_file"
fi

launchctl bootout "$domain/$label" 2>/dev/null || true
launchctl bootstrap "$domain" "$plist_path"

for _ in $(seq 1 50); do
    if curl -fsS http://127.0.0.1:8391/v1/liveness >/dev/null 2>&1; then
        printf 'Inlay server is running. Log: %s/server.log\nAdmin token file: %s\n' "$log_dir" "$token_file"
        exit 0
    fi
    sleep 0.2
done
printf 'Server did not answer within 10 seconds; see %s/server.log\n' "$log_dir" >&2
exit 1
