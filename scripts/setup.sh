#!/bin/bash
set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd)
cd "$project_dir"

fail() { printf 'setup: %s\n' "$1" >&2; exit 1; }

case "$(uname -s)" in
    Darwin)
        [[ "$(uname -m)" == arm64 ]] || fail "macOS builds require Apple Silicon (arm64)."
        command -v swift >/dev/null || fail "Install Xcode 26+ (Swift 6.2+) from the App Store."
        swift -e '
        #if compiler(<6.2)
        #error("Swift 6.2 or newer is required.")
        #endif
        ' >/dev/null 2>&1 || fail "Swift 6.2 or newer is required; update Xcode."
        xcrun metal --version >/dev/null 2>&1 ||
            fail "Metal toolchain missing; run: xcodebuild -downloadComponent MetalToolchain"
        ;;
    Linux) ;;
    *) fail "Unsupported platform $(uname -s); Inlay builds on macOS (Apple Silicon) or Linux." ;;
esac

command -v git >/dev/null || fail "Install git."
command -v cmake >/dev/null || fail "Install CMake (brew install cmake, or your package manager)."
command -v bun >/dev/null || fail "Install Bun 1.4.2: https://bun.sh"
[[ "$(bun --version)" == "1.4.2" ]] ||
    fail "Bun 1.4.2 is required (found $(bun --version)); run: bun upgrade --canary or reinstall 1.4.2."

printf 'Initializing submodules…\n'
git submodule update --init --recursive
bun install --frozen-lockfile
./scripts/download-model.sh
./scripts/download-text-model.sh
./scripts/build-server.sh

cat <<'NEXT'

Setup complete. Next steps:
  ./scripts/run-dev.sh          # dev server + Inlay Dev pair
  ./scripts/install-service.sh  # macOS only: install the server as a LaunchAgent
NEXT
