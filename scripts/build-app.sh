#!/bin/bash
set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd)
cd "$project_dir"
if [[ "$(uname -s)" != Darwin ]]; then
    printf 'The desktop client requires macOS.\n' >&2
    exit 1
fi
with_server=0
dist=0
development=0
for arg in "$@"; do
    case "$arg" in
        --dev) development=1 ;;
        --with-server) with_server=1 ;;
        --dist) dist=1 ;;
        *) printf 'Usage: scripts/build-app.sh [--dev] [--with-server] [--dist]\n' >&2; exit 2 ;;
    esac
done
if [[ "$dist" == 1 && "$with_server" != 1 ]]; then
    printf 'Distribution builds bundle the server; add --with-server.\n' >&2; exit 1
fi
if [[ "$dist" == 1 && "$development" == 1 ]]; then
    printf 'Distribution builds are release builds; do not combine --dist with --dev.\n' >&2; exit 1
fi
if [[ "$with_server" == 1 && ! -x "$project_dir/build/server/inlay-server" ]]; then
    printf 'Missing server package at build/server; run ./scripts/build-server.sh first.\n' >&2; exit 1
fi
if [[ "$dist" == 1 ]]; then
    missing=()
    for name in INLAY_CODESIGN_IDENTITY INLAY_NOTARY_KEY_FILE INLAY_NOTARY_KEY_ID INLAY_NOTARY_ISSUER_ID INLAY_CLIENT_VERSION INLAY_CLIENT_BUILD; do
        [[ -n "${!name:-}" ]] || missing+=("$name")
    done
    if (( ${#missing[@]} )); then
        printf 'Error: --dist requires Developer ID credentials; missing: %s\n' "${missing[*]}" >&2; exit 1
    fi
    [[ -f "$INLAY_NOTARY_KEY_FILE" ]] ||
        { printf 'Error: --dist requires a valid INLAY_NOTARY_KEY_FILE path.\n' >&2; exit 1; }
fi
if [[ "$development" == 1 ]]; then
    app_name="Inlay Dev"
    info_plist=Resources/Info-Dev.plist
else
    app_name=Inlay
    info_plist=Resources/Info.plist
fi
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")
build_jobs="${INLAY_BUILD_JOBS:-8}"
macos_sdk=$(xcrun --sdk macosx --show-sdk-path)
swift_flags=(--scratch-path .build/client-swift -c release --jobs "$build_jobs" --product Inlay
    --force-resolved-versions
    -Xswiftc -Xclang-linker -Xswiftc -isysroot
    -Xswiftc -Xclang-linker -Xswiftc "$macos_sdk")
swift build "${swift_flags[@]}"
swift_bin=$(swift build "${swift_flags[@]}" --show-bin-path)

app_path="$project_dir/build/$app_name.app"
mkdir -p build
staging_dir=$(mktemp -d "$project_dir/build/.app.XXXXXX")
trap 'rm -rf "$staging_dir"' EXIT
staged_app="$staging_dir/$app_name.app"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
cp "$swift_bin/Inlay" "$staged_app/Contents/MacOS/Inlay"
cp "$info_plist" "$staged_app/Contents/Info.plist"
if [[ -n "${INLAY_CLIENT_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $INLAY_CLIENT_VERSION" "$staged_app/Contents/Info.plist"
fi
if [[ -n "${INLAY_CLIENT_BUILD:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $INLAY_CLIENT_BUILD" "$staged_app/Contents/Info.plist"
fi
cp Resources/swift-openapi-runtime-LICENSE.txt Resources/swift-http-types-LICENSE.txt \
    THIRD_PARTY_NOTICES.md "$staged_app/Contents/Resources/"
swift scripts/make-icon.swift "$project_dir/.build/Inlay.iconset"
iconutil -c icns .build/Inlay.iconset -o "$staged_app/Contents/Resources/Inlay.icns"
if [[ "$with_server" == 1 ]]; then
    ditto "$project_dir/build/server" "$staged_app/Contents/Resources/Server"
    cp Server/dev.davis.inlay.server-agent.plist "$staged_app/Contents/Resources/"
fi

signing_identity="${INLAY_SIGNING_IDENTITY:-}"
if [[ "$dist" == 1 ]]; then signing_identity="$INLAY_CODESIGN_IDENTITY"; fi
if [[ "$dist" == 1 ]]; then
    # Inside-out, hardened-runtime signing of every bundled Mach-O.
    while IFS= read -r -d '' macho; do
        codesign --force --options runtime --timestamp --sign "$signing_identity" "$macho"
    done < <(find "$staged_app/Contents/Resources/Server" -type f -name '*.dylib' -print0)
    find "$staged_app/Contents/Resources/Server" -type d -name '*.bundle' -print0 |
        while IFS= read -r -d '' bundle; do
            codesign --force --options runtime --timestamp --sign "$signing_identity" "$bundle"
        done
    find "$staged_app/Contents/Resources/Server" -type f -perm -u+x -print0 |
        while IFS= read -r -d '' macho; do
            file "$macho" | grep -q 'Mach-O' || continue
            codesign --force --options runtime --timestamp \
                --entitlements Server/entitlements.plist --sign "$signing_identity" "$macho"
        done
fi
if [[ -z "$signing_identity" ]]; then
    identities=$(security find-identity -v -p codesigning | awk '/"Apple Development:/ {print $2}')
    identity_count=$(printf '%s\n' "$identities" | awk 'NF {n++} END {print n+0}')
    if [[ "$identity_count" == 1 ]]; then signing_identity="$identities"; else signing_identity=-; fi
fi
timestamp_flag=
if [[ "$dist" == 1 ]]; then timestamp_flag=--timestamp; fi
codesign --force --sign "$signing_identity" --options runtime ${timestamp_flag:+"$timestamp_flag"} \
    --entitlements Resources/Inlay.entitlements --identifier "$bundle_id" "$staged_app"
codesign --verify --deep --strict "$staged_app"
if [[ -d "$app_path" ]]; then
    existing_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist")
    if [[ "$existing_id" != "$bundle_id" ]]; then
        printf 'Another app occupies %s; leaving it untouched.\n' "$app_path" >&2
        exit 1
    fi
    rm -rf "$app_path"
fi
mv "$staged_app" "$app_path"
printf '\nBuilt %s\n' "$app_path"
if [[ "$dist" == 1 ]]; then
    notary_args=(--key "$INLAY_NOTARY_KEY_FILE" --key-id "$INLAY_NOTARY_KEY_ID" --issuer "$INLAY_NOTARY_ISSUER_ID" --wait)
    ditto -c -k --keepParent "$app_path" "$project_dir/build/Inlay-notarize.zip"
    xcrun notarytool submit "$project_dir/build/Inlay-notarize.zip" "${notary_args[@]}"
    xcrun stapler staple "$app_path"
    dmg_path=$("$project_dir/scripts/make-dmg.sh" "$app_path" "$project_dir/build/Inlay.dmg")
    codesign --force --timestamp --identifier "dev.davis.inlay.dmg" --sign "$signing_identity" "$dmg_path"
    xcrun notarytool submit "$dmg_path" "${notary_args[@]}"
    xcrun stapler staple "$dmg_path"
    spctl --assess --type open --context context:primary-signature -v "$dmg_path"
    printf 'Distribution DMG (notarized + stapled): %s\n' "$dmg_path"
fi
