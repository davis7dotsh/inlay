#!/bin/bash
set -euo pipefail

model_dir="${INLAY_MODEL_DIR:-$HOME/Library/Application Support/Inlay/Models}"
model_name="ggml-parakeet-tdt-0.6b-v3-f16.bin"
model_sha="833bffc9513b2cae867ee9e51633cfd11e4d51aaa5597c8ac02159385a2b426f"
model_url="https://huggingface.co/ggml-org/parakeet-GGUF/resolve/35156454d1a39de06863303dd209fd2bed6ee079/$model_name"
mkdir -p "$model_dir"

verify_model() {
    local actual_sha
    actual_sha=$(shasum -a 256 "$1" | cut -d ' ' -f 1)
    [[ "$actual_sha" == "$model_sha" ]]
}

if [[ -f "$model_dir/$model_name" ]] && verify_model "$model_dir/$model_name"; then
    printf 'Verified model already installed: %s\n' "$model_dir/$model_name"
    exit 0
fi

printf 'Downloading Parakeet TDT 0.6B v3 (1.26 GB).\n'
curl --fail --location --retry 3 --connect-timeout 20 --continue-at - \
    --output "$model_dir/$model_name.download" "$model_url"
printf 'Verifying SHA-256…\n'
if ! verify_model "$model_dir/$model_name.download"; then
    rm -f "$model_dir/$model_name.download"
    printf 'Model integrity check failed; run this command again.\n' >&2
    exit 1
fi
mv -f "$model_dir/$model_name.download" "$model_dir/$model_name"
printf 'Ready: %s\n' "$model_dir/$model_name"
