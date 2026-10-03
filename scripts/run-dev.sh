#!/bin/bash
set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd)
cd "$project_dir"
action="${1:-start}"
if [[ "$action" == --skip-build ]]; then action=start; skip_build=true; else skip_build=false; fi
if [[ "${2:-}" == --skip-build ]]; then skip_build=true; fi
server_binary="$project_dir/build/server/inlay-server"
state_dir="$project_dir/.local"
pid_file="$state_dir/server.pid"
log_file="$state_dir/server.log"
server_port="${INLAY_SERVER_PORT:-8391}"
client_dir="$state_dir/client"
mkdir -p "$state_dir"
chmod 700 "$state_dir"

launch_client() {
    [[ "$(uname -s)" == Darwin ]] || return 0
    local client_app="$project_dir/build/Inlay Dev.app"
    if [[ ! -x "$client_app/Contents/MacOS/Inlay" ]]; then
        printf 'Build the client with scripts/build-dev-app.sh; the server remains running.\n' >&2
        return 1
    fi
    mkdir -p "$client_dir"
    chmod 700 "$client_dir"
    # LaunchServices does not inherit the shell environment. Pass only the
    # workspace preference root and the local endpoint; credentials use Keychain.
    open --env "INLAY_CLIENT_DATA_DIR=$client_dir" \
        --env "INLAY_SERVER_URL=http://127.0.0.1:$server_port" "$client_app"
}

server_pid=""
recorded_port=""
recorded_extra=""
server_command=""

valid_port() {
    [[ "$1" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

is_running() {
    [[ -f "$pid_file" ]] || return 1
    read -r server_pid recorded_port recorded_extra < "$pid_file" || return 1
    [[ "$server_pid" =~ ^[0-9]+$ && "$server_pid" -gt 1 ]] || return 1
    kill -0 "$server_pid" 2>/dev/null || return 1
    # A stale PID file must never target an unrelated process.
    server_command="$(ps -p "$server_pid" -o command=)" || return 1
    case "$server_command" in
        "$server_binary "*) return 0 ;;
        *) return 1 ;;
    esac
}

use_running_port() {
    # The launch prefix also recovers the endpoint from older PID-only records.
    # Check it against the record so stale or damaged state cannot select a
    # different server for a health check or client launch.
    local arguments="${server_command#"$server_binary "}"
    local port_pattern='^--host 127\.0\.0\.1 --port ([0-9]{1,5})( |$)'
    if [[ "$arguments" =~ $port_pattern ]]; then
        local running_port="${BASH_REMATCH[1]}"
        if valid_port "$running_port" && [[ -z "$recorded_extra" ]] && \
            { [[ -z "$recorded_port" ]] || \
              { valid_port "$recorded_port" && ((10#$recorded_port == 10#$running_port)); }; }; then
            server_port="$((10#$running_port))"
            return 0
        fi
    fi
    printf 'Cannot verify the running dev server port (PID %s). Check %s and its launch arguments.\n' "$server_pid" "$pid_file" >&2
    return 1
}

stop_server() {
    if ! is_running; then
        rm -f "$pid_file"
        printf 'The dev server is stopped.\n'
        return
    fi
    kill -TERM "$server_pid"
    for ((attempt = 0; attempt < 50; attempt++)); do
        if ! kill -0 "$server_pid" 2>/dev/null; then break; fi
        sleep 0.1
    done
    if is_running; then
        printf 'The dev server is still stopping (PID %s). See %s.\n' "$server_pid" "$log_file" >&2
        return 1
    fi
    rm -f "$pid_file"
    printf 'Stopped the dev server.\n'
}

case "$action" in
    stop) stop_server; exit 0 ;;
    status)
        if is_running; then
            use_running_port
            printf 'Dev server PID %s: http://localhost:%s\n' "$server_pid" "$server_port"
            curl --fail --silent --show-error --max-time 3 "http://127.0.0.1:$server_port/v1/health"
            printf '\n'
        else
            printf 'The dev server is stopped.\n'
        fi
        exit 0 ;;
    restart) stop_server ;;
    start) ;;
    *) printf 'Usage: %s [start|stop|status|restart] [--skip-build]\n' "$0" >&2; exit 2 ;;
esac

if is_running; then
    use_running_port
    printf 'Dev server already running: http://localhost:%s (PID %s).\n' "$server_port" "$server_pid"
    launch_client
    exit 0
fi
rm -f "$pid_file"
if ! valid_port "$server_port"; then
    printf 'INLAY_SERVER_PORT must be an integer from 1 to 65535.\n' >&2
    exit 1
fi
server_port="$((10#$server_port))"
if [[ "$skip_build" != true ]]; then
    ./scripts/build-server.sh
    if [[ "$(uname -s)" == Darwin ]]; then ./scripts/build-dev-app.sh; fi
fi
if [[ ! -x "$server_binary" ]]; then
    printf 'Build the server first with scripts/build-server.sh.\n' >&2
    exit 1
fi

speech_model="${INLAY_SPEECH_MODEL:-}"
proof_model="${INLAY_TEXT_MODEL:-}"
if [[ "$(uname -s)" == Darwin ]]; then
    # Reuse model weights only. User recordings, preferences, and credentials
    # are never imported from the installed app.
    speech_model="${speech_model:-$HOME/Library/Application Support/Inlay/Models/ggml-large-v3-turbo.bin}"
    proof_model="${proof_model:-$HOME/.inlay/models/Qwen3-4B-Instruct-2507-MLX-4bit}"
fi
if [[ ! -f "$speech_model" || ! -e "$proof_model" ]]; then
    printf 'Set INLAY_SPEECH_MODEL and INLAY_TEXT_MODEL to installed Whisper and Qwen weights.\n' >&2
    exit 1
fi
server_args=(--host 127.0.0.1 --port "$server_port" --dev
    --data-dir "${INLAY_SERVER_DATA_DIR:-$state_dir/server}"
    --speech-helper "${INLAY_ENGINE_PATH:-$project_dir/build/server/helpers/inlay-engine}"
    --speech-model "$speech_model"
    --vad-model "${INLAY_VAD_PATH:-$project_dir/build/server/resources/silero-vad.bin}"
    --proof-helper "${INLAY_TEXT_ENGINE_PATH:-$project_dir/build/server/helpers/inlay-text-engine}"
    --proof-model "$proof_model")
if [[ -n "${INLAY_SERVER_TOKEN_FILE:-}" ]]; then server_args+=(--token-file "$INLAY_SERVER_TOKEN_FILE"); fi
umask 077
nohup "$server_binary" "${server_args[@]}" >> "$log_file" 2>&1 < /dev/null &
server_pid=$!
printf '%s %s\n' "$server_pid" "$server_port" > "$pid_file"
for ((attempt = 0; attempt < 100; attempt++)); do
    if ! kill -0 "$server_pid" 2>/dev/null; then
        rm -f "$pid_file"
        printf 'The dev server exited during startup. See %s.\n' "$log_file" >&2
        exit 1
    fi
    if curl --fail --silent --max-time 1 "http://127.0.0.1:$server_port/v1/health" > /dev/null; then
        printf 'Dev server: http://localhost:%s (PID %s)\nLog: %s\n' "$server_port" "$server_pid" "$log_file"
        launch_client
        exit 0
    fi
    sleep 0.1
done
printf 'The dev server is starting slowly. See %s; use scripts/run-dev.sh status to check it.\n' "$log_file" >&2
exit 1
