#!/bin/bash
set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd)
derived="$project_dir/.build/text-mlx"
packages="$project_dir/.build/text-packages"
output="$project_dir/.build/text-native"
mkdir -p "$output"
if ! xcrun metal --version >/dev/null 2>&1; then
    printf 'Install the Xcode Metal compiler first: xcodebuild -downloadComponent MetalToolchain\n' >&2
    exit 1
fi

# Xcode compiles MLX's Metal shaders; plain `swift build` does not. Package the
# metallib beside the helper so it never relies on a DerivedData fallback.
cd "$project_dir/TextEngine"
xcodebuild -scheme InlayTextEngine -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$derived" \
    -clonedSourcePackagesDirPath "$packages" -onlyUsePackageVersionsFromResolvedFile \
    -jobs "${INLAY_BUILD_JOBS:-8}" \
    ARCHS=arm64 MACOSX_DEPLOYMENT_TARGET=14.0 CODE_SIGNING_ALLOWED=NO build

products="$derived/Build/Products/Release"
test -x "$products/inlay-text-engine"
test -f "$products/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" || \
    test -f "$products/mlx-swift_Cmlx.bundle/default.metallib"
cp "$products/inlay-text-engine" "$output/inlay-text-engine"
if [[ -f "$products/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" ]]; then
    cp "$products/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" "$output/mlx.metallib"
else
    cp "$products/mlx-swift_Cmlx.bundle/default.metallib" "$output/mlx.metallib"
fi

# Preserve dependency resources alongside the helper as SwiftPM expects.
rm -rf "$output/resources"
mkdir -p "$output/resources"
for bundle in "$products/"*.bundle; do
    [[ -d "$bundle" ]] || continue
    [[ "$(basename "$bundle")" == mlx-swift_Cmlx.bundle ]] && continue
    ditto "$bundle" "$output/resources/$(basename "$bundle")"
done
