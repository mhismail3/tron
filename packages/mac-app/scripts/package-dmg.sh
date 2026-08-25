#!/usr/bin/env bash
# Sole owner of fail-closed Mac DMG assembly and mounted-image verification.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
NODE_ARM64_SHA256="913b144fdb40638b1acef7974ab3c33fbd527cc0974cb5da467ab1e6ac51b4d4"
NODE_X64_SHA256="bf0e0ff20d4e5a16436d1ec372e47161e52be8e487db8070ae3f06b01efbba0c"

usage() {
    echo "Usage: package-dmg.sh --app PATH --output PATH --volume-name NAME --layout structural|release"
}

die() {
    echo "error: $*" >&2
    exit 1
}

app=""
output=""
volume_name=""
layout=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --app|--output|--volume-name|--layout)
            [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 requires a value"
            key="${1#--}"
            key="${key//-/_}"
            [ -z "${!key}" ] || die "$1 may be supplied only once"
            printf -v "$key" '%s' "$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "unknown argument: $1"
            ;;
    esac
done

[ -n "$app" ] && [ -n "$output" ] && [ -n "$volume_name" ] && [ -n "$layout" ] \
    || die "--app, --output, --volume-name, and --layout are required"
case "$layout" in structural|release) ;; *) die "--layout must be structural or release" ;; esac
[ -d "$app" ] || die "app bundle not found: $app"
bundle="$(basename "$app")"
[[ "$bundle" == *.app ]] || die "--app must name an .app bundle"
helper="Contents/Library/LoginItems/Tron Agent.app/Contents/MacOS/tron"
gateway_root="Contents/Resources/Gateway"
launch_agent="Contents/Library/LaunchAgents/com.tron.server.plist"

verify_app_bundle() {
    local root="$1"
    local required_file
    local required_directory
    local manifest="$root/$gateway_root/manifest.json"
    local expected_fingerprint actual_fingerprint runtime expected_arch actual_arch entitlements helper_archs node_version
    local required_files=(
        "$helper"
        "$launch_agent"
        "$gateway_root/manifest.json"
        "$gateway_root/app/dist/index.js"
        "$gateway_root/app/package.json"
        "$gateway_root/app/package-lock.json"
        "$gateway_root/app/PushService.xcconfig"
        "$gateway_root/runtime/node-arm64"
        "$gateway_root/runtime/node-x64"
    )
    local required_directories=("$gateway_root/app/node_modules")

    for required_file in "${required_files[@]}"; do
        [ -f "$root/$required_file" ] || die "app bundle is missing required Gateway file: $root/$required_file"
    done
    for required_directory in "${required_directories[@]}"; do
        [ -d "$root/$required_directory" ] || die "app bundle is missing required Gateway directory: $root/$required_directory"
    done
    "$REPO_ROOT/scripts/validate-push-service-config.sh" "$root/$gateway_root/app/PushService.xcconfig" >/dev/null \
        || die "app bundle Gateway PushService.xcconfig is invalid or empty"
    [ -x "$root/$helper" ] || die "app bundle helper is not executable: $root/$helper"
    codesign --verify --deep --strict "$root" >/dev/null 2>&1 \
        || die "app bundle deep strict signature is invalid: $root"
    codesign --verify --deep --strict "$root/Contents/Library/LoginItems/Tron Agent.app" >/dev/null 2>&1 \
        || die "Tron Agent helper signature is invalid"
    helper_archs="$(lipo -archs "$root/$helper" 2>/dev/null || true)"
    [[ " $helper_archs " == *" arm64 "* && " $helper_archs " == *" x86_64 "* ]] \
        || die "Tron Agent helper is not universal arm64/x86_64"

    expected_fingerprint="$(plutil -extract payloadFingerprint raw -o - "$manifest" 2>/dev/null || true)"
    [[ "$expected_fingerprint" =~ ^[0-9a-f]{64}$ ]] \
        || die "Gateway manifest has an invalid payload fingerprint"
    [[ "$(plutil -extract kind raw -o - "$manifest" 2>/dev/null || true)" == "tron-gateway-payload" ]] \
        || die "Gateway manifest kind is invalid"
    [[ "$(plutil -extract channel raw -o - "$manifest" 2>/dev/null || true)" == "stable" ]] \
        || die "Gateway manifest channel is not stable"
    node_version="$(cat "$(cd "$(dirname "$0")/../../.." && pwd -P)/.node-version" 2>/dev/null || true)"
    [[ "$(plutil -extract nodeVersion raw -o - "$manifest" 2>/dev/null || true)" == "$node_version" ]] \
        || die "Gateway manifest Node version is not canonical"
    actual_fingerprint="$("$root/$helper" --fingerprint "$root/$gateway_root" 2>/dev/null || true)"
    [[ "$actual_fingerprint" == "$expected_fingerprint" ]] \
        || die "Gateway payload fingerprint does not match its authoritative manifest"

    for expected_arch in arm64 x86_64; do
        if [[ "$expected_arch" == arm64 ]]; then
            runtime="$root/$gateway_root/runtime/node-arm64"
        else
            runtime="$root/$gateway_root/runtime/node-x64"
        fi
        [ -x "$runtime" ] || die "Node $expected_arch runtime is not executable"
        if [[ "$expected_arch" == arm64 ]]; then expected_sha="$NODE_ARM64_SHA256"; else expected_sha="$NODE_X64_SHA256"; fi
        [[ "$(shasum -a 256 "$runtime" | awk '{print $1}')" == "$expected_sha" ]] \
            || die "Node $expected_arch runtime checksum is not canonical"
        codesign --verify --strict "$runtime" >/dev/null 2>&1 \
            || die "Node $expected_arch runtime signature is invalid"
        entitlements="$(codesign -d --entitlements :- "$runtime" 2>/dev/null || true)"
        [[ "$(grep -c '<key>' <<<"$entitlements")" == 1 \
            && "$entitlements" == *'<key>com.apple.security.cs.allow-jit</key>'*'<true/>'* ]] \
            || die "Node $expected_arch runtime does not have the exact allow-jit entitlement"
        actual_arch="$(lipo -archs "$runtime" 2>/dev/null || true)"
        [[ "$actual_arch" == "$expected_arch" ]] \
            || die "Node runtime architecture mismatch: expected $expected_arch, got $actual_arch"
    done
}

verify_app_bundle "$app"

work="$(mktemp -d)"
source="$work/source"
mount_point="$work/mount"
attached=0
cleanup() {
    local status=$?
    trap - EXIT
    if [ "$attached" -eq 1 ] && ! hdiutil detach "$mount_point" >/dev/null 2>&1; then
        echo "error: failed to detach DMG mount: $mount_point" >&2
        status=1
    fi
    # Bundled payloads are deliberately immutable. Restore owner write access
    # only inside this private packaging scratch directory before removing it.
    chmod -R u+w "$work" 2>/dev/null || true
    rm -rf "$work"
    exit "$status"
}
trap cleanup EXIT

mkdir -p "$source" "$mount_point" "$(dirname "$output")"
# `ditto` applies an immutable directory's mode before copying its children and
# then cannot populate the complete read-only payload tree. `cp -R` materializes
# children first; the verification below proves signatures, bytes, and modes
# survived the copy before the image is created.
cp -R "$app" "$source/$bundle"
verify_app_bundle "$source/$bundle"
rm -f "$output"

if [ "$layout" = structural ]; then
    args=(--skip-jenkins --volname "$volume_name")
else
    args=(--volname "$volume_name" --window-size 540 340 --icon "$bundle" 135 170)
fi
args+=(--app-drop-link 405 170)
[ "$layout" = structural ] || args+=(--hide-extension "$bundle")
args+=(--hdiutil-quiet "$output" "$source")

create-dmg "${args[@]}"
[ -s "$output" ] || die "DMG was not created: $output"
hdiutil attach -readonly -nobrowse -mountpoint "$mount_point" "$output"
attached=1
[ -d "$mount_point/$bundle" ] || die "mounted DMG is missing $bundle"
verify_app_bundle "$mount_point/$bundle"
[ -L "$mount_point/Applications" ] || die "mounted DMG is missing Applications link"
[ "$(readlink "$mount_point/Applications")" = "/Applications" ] \
    || die "mounted DMG Applications link does not target /Applications"
