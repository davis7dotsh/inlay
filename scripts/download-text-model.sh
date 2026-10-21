#!/bin/bash
set -euo pipefail

# Verified Qwen text-model download. Pins mirror TextModel.qwen in
# Sources/InlayCore/TextModel.swift (macOS MLX, six files) and
# linuxProofModelPin in Server/src/inference/model-pins.ts (Linux GGUF).
platform=$(uname -s)
if [[ "${1:-}" == --linux ]]; then platform=Linux; shift; fi

sha_of() { shasum -a 256 "$1" 2>/dev/null | cut -d ' ' -f 1 || sha256sum "$1" | cut -d ' ' -f 1; }
size_of() { stat -f %z "$1" 2>/dev/null || stat -c %s "$1"; }

verify_file() { # path expected_bytes expected_sha
    [[ -f "$1" ]] || return 1
    [[ "$(size_of "$1")" == "$2" ]] || return 1
    [[ "$(sha_of "$1")" == "$3" ]]
}

download_verified() { # url target expected_bytes expected_sha
    local url="$1" target="$2" bytes="$3" sha="$4"
    if verify_file "$target" "$bytes" "$sha"; then
        printf 'Verified: %s\n' "$target"
        return 0
    fi
    printf 'Downloading %s\n' "$(basename "$target")"
    curl --fail --location --retry 3 --connect-timeout 20 --continue-at - \
        --output "$target.download" "$url"
    if ! verify_file "$target.download" "$bytes" "$sha"; then
        rm -f "$target.download"
        printf 'Integrity check failed for %s; run this command again.\n' "$(basename "$target")" >&2
        exit 1
    fi
    mv -f "$target.download" "$target"
}

if [[ "$platform" == Linux ]]; then
    model_dir="${INLAY_MODEL_DIR:-$PWD/.local/models}"
    gguf="Qwen3-4B-Instruct-2507-Q4_K_M.gguf"
    mkdir -p "$model_dir"
    download_verified \
        "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/a06e946bb6b655725eafa393f4a9745d460374c9/$gguf" \
        "$model_dir/$gguf" 2497281120 \
        "3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597"
    printf 'Ready: %s\n' "$model_dir/$gguf"
    exit 0
fi

if [[ "$platform" != Darwin ]]; then
    printf 'Unsupported platform %s; use --linux for the GGUF build.\n' "$platform" >&2
    exit 1
fi

model_root="${INLAY_MODEL_DIR:-$HOME/Library/Application Support/Inlay/Models}"
model_name="Qwen3-4B-Instruct-2507-MLX-4bit"
model_dir="$model_root/$model_name"
base_url="https://huggingface.co/mlx-community/Qwen3-4B-Instruct-2507-4bit/resolve/50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b"
mkdir -p "$model_dir"

download_verified "$base_url/model.safetensors" "$model_dir/model.safetensors" 2263022417 \
    "2a73c6c248601ab904e035548abd8e6abb65ea27dcb5f342fb0a8910eb44173f"
download_verified "$base_url/config.json" "$model_dir/config.json" 938 \
    "574349e5a343236546fda55e4744a76e181f534182d7dc60ff1bad7e7a502849"
download_verified "$base_url/tokenizer.json" "$model_dir/tokenizer.json" 11422654 \
    "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"
download_verified "$base_url/tokenizer_config.json" "$model_dir/tokenizer_config.json" 5440 \
    "4397cc477eb6d79715ccd2000accd6b3531928f30029665832fa1b255f24d2b9"
download_verified "$base_url/generation_config.json" "$model_dir/generation_config.json" 238 \
    "835fffe355c9438e7a25be099b3fccaa98350b83451f9fd2d99512e74f1ade48"
download_verified "$base_url/chat_template.jinja" "$model_dir/chat_template.jinja" 4040 \
    "40c21f34cf67d8c760ef72f8ad3ae5afad514299d4b06e91dd9a8d705af7b541"

# The MLX helper rejects extra files at load; fail here, naming them, instead.
expected=$'chat_template.jinja\nconfig.json\ngeneration_config.json\nmodel.safetensors\ntokenizer.json\ntokenizer_config.json'
actual=$(find "$model_dir" -type f -exec basename {} \; | LC_ALL=C sort)
if [[ "$actual" != "$expected" ]]; then
    printf 'Model directory must contain exactly the six pinned files. Found:\n%s\n' "$actual" >&2
    exit 1
fi
printf 'Ready: %s\n' "$model_dir"
