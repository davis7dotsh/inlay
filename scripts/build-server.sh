#!/bin/bash
set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd)
cd "$project_dir"
build_jobs="${INLAY_BUILD_JOBS:-8}"
server_platform=$(uname -s)
server_architecture=$(uname -m)
if [[ "$server_platform" != Darwin && "$server_platform" != Linux ]]; then
    printf 'The Inlay server supports macOS and Linux.\n' >&2
    exit 1
fi
if [[ "$server_platform" == Linux && "$server_architecture" != x86_64 && \
      "$server_architecture" != aarch64 && "$server_architecture" != arm64 ]]; then
    printf 'Linux server packages support x86_64 and ARM64.\n' >&2
    exit 1
fi
dependencies=(bun)
if [[ "${INLAY_SKIP_NATIVE:-0}" != 1 ]]; then
    dependencies+=(cmake)
    if [[ "$server_platform" == Darwin ]]; then dependencies+=(swift); fi
fi
for dependency in "${dependencies[@]}"; do
    if ! command -v "$dependency" >/dev/null; then
        printf 'Missing build dependency: %s\n' "$dependency" >&2
        exit 1
    fi
done
if [[ "${INLAY_SKIP_NATIVE:-0}" != 1 && \
      ( ! -f vendor/whisper.cpp/include/whisper.h || ! -f vendor/llama.cpp/include/llama.h ) ]]; then
    git submodule update --init --recursive
fi

native_flags=(-DCMAKE_BUILD_TYPE=Release "-DINLAY_CUDA=${INLAY_CUDA:-OFF}")
if [[ "$server_platform" == Darwin ]]; then
    if [[ "$server_architecture" != arm64 ]]; then
        printf 'The macOS server uses MLX and requires Apple Silicon.\n' >&2
        exit 1
    fi
    native_flags+=(-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_OSX_ARCHITECTURES=arm64)
fi
if [[ -n "${INLAY_CUDA_ARCHITECTURES:-}" ]]; then
    native_flags+=("-DCMAKE_CUDA_ARCHITECTURES=$INLAY_CUDA_ARCHITECTURES")
fi
if [[ -n "${INLAY_NATIVE:-}" ]]; then
    native_flags+=("-DGGML_NATIVE=$INLAY_NATIVE")
fi
if [[ "${INLAY_SKIP_NATIVE:-0}" == 1 ]]; then
    # Reuse explicitly selected helpers without rebuilding or modifying them.
    # This is useful for isolated server development beside an installed app.
    : "${INLAY_ENGINE_PATH:?Set INLAY_ENGINE_PATH when INLAY_SKIP_NATIVE=1}"
    : "${INLAY_TEXT_ENGINE_PATH:?Set INLAY_TEXT_ENGINE_PATH when INLAY_SKIP_NATIVE=1}"
    : "${INLAY_VAD_PATH:?Set INLAY_VAD_PATH when INLAY_SKIP_NATIVE=1}"
    speech_helper="$INLAY_ENGINE_PATH"
    text_helper="$INLAY_TEXT_ENGINE_PATH"
    text_helper_dir=$(dirname "$text_helper")
    vad_model="$INLAY_VAD_PATH"
else
    cmake -S . -B .build/server-native "${native_flags[@]}"
    cmake --build .build/server-native --target inlay-engine --parallel "$build_jobs"
    if [[ "$server_platform" == Darwin ]]; then
        ./scripts/build-text-engine.sh
        text_helper_dir="$project_dir/.build/text-native"
    else
        cmake -S TextEngine -B .build/server-llama "${native_flags[@]}"
        cmake --build .build/server-llama --target inlay-text-engine --parallel "$build_jobs"
        text_helper_dir="$project_dir/.build/server-llama"
    fi
    ./scripts/download-vad.sh
    speech_helper="$project_dir/.build/server-native/Engine/inlay-engine"
    text_helper="$text_helper_dir/inlay-text-engine"
    vad_model="$project_dir/.build/models/silero-vad.bin"
fi
test -x "$speech_helper"
test -x "$text_helper"
test -f "$vad_model"
bun install --frozen-lockfile

mkdir -p build
staging_dir=$(mktemp -d "$project_dir/build/.server.XXXXXX")
trap 'rm -rf "$staging_dir"' EXIT
mkdir -p "$staging_dir/helpers" "$staging_dir/resources"
bun run --cwd Server build --outfile "$staging_dir/inlay-server"
cp "$speech_helper" "$staging_dir/helpers/inlay-engine"
cp "$text_helper" "$staging_dir/helpers/inlay-text-engine"
if [[ "$server_platform" == Darwin ]]; then
    cp "$text_helper_dir/mlx.metallib" "$staging_dir/helpers/mlx.metallib"
    for bundle in "$text_helper_dir/resources/"*.bundle "$text_helper_dir/"*.bundle; do
        [[ -d "$bundle" ]] || continue
        ditto "$bundle" "$staging_dir/helpers/$(basename "$bundle")"
    done
    codesign --force --sign - "$staging_dir/helpers/inlay-engine"
    codesign --force --sign - "$staging_dir/helpers/inlay-text-engine"
    # Preserve Bun's JIT permissions when signing the bundled runtime.
    codesign --force --sign - --entitlements Server/entitlements.plist "$staging_dir/inlay-server"
fi
cp "$vad_model" "$staging_dir/resources/silero-vad.bin"
# Docker and service installs run the server as a different user than the builder.
chmod 644 "$staging_dir/resources/silero-vad.bin"
for library in whisper llama; do
    license_path="$project_dir/vendor/$library.cpp/LICENSE"
    if [[ ! -f "$license_path" && "${INLAY_SKIP_NATIVE:-0}" == 1 ]]; then
        license_path="$(dirname "$vad_model")/$library-LICENSE.txt"
    fi
    if [[ ! -f "$license_path" ]]; then
        printf 'Missing %s license; initialize submodules or reuse a complete helper/resource package.\n' "$library" >&2
        exit 1
    fi
    cp "$license_path" "$staging_dir/resources/$library-LICENSE.txt"
done
cp Resources/*-LICENSE.txt THIRD_PARTY_NOTICES.md "$staging_dir/resources/"
bun Server/scripts/licenses.ts "$staging_dir/resources/javascript-LICENSES.txt"
cp Server/README.md "$staging_dir/README.md"
prior_package="$project_dir/build/.server-previous-$$"
if [[ -d build/server ]]; then mv build/server "$prior_package"; fi
if ! mv "$staging_dir" "$project_dir/build/server"; then
    if [[ -d "$prior_package" ]]; then mv "$prior_package" "$project_dir/build/server"; fi
    exit 1
fi
rm -rf "$prior_package"
printf '\nBuilt %s/build/server\n' "$project_dir"
