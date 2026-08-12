#!/usr/bin/env bash
# Sole owner of fail-closed Mac DMG assembly and mounted-image verification.

set -euo pipefail

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
gateway="Contents/Resources/Gateway/app/dist/index.js"
runtime="Contents/Resources/Gateway/runtime/node-arm64"
[ -x "$app/$helper" ] || die "app bundle is missing executable helper: $app/$helper"
[ -f "$app/$gateway" ] || die "app bundle is missing gateway entrypoint: $app/$gateway"
[ -x "$app/$runtime" ] || die "app bundle is missing Node runtime: $app/$runtime"

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
    else
        rm -rf "$work"
    fi
    exit "$status"
}
trap cleanup EXIT

mkdir -p "$source" "$mount_point" "$(dirname "$output")"
ditto "$app" "$source/$bundle"
[ -x "$source/$bundle/$helper" ] || die "copied app bundle is missing executable helper"
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
[ -x "$mount_point/$bundle/$helper" ] || die "mounted DMG is missing executable helper"
[ -L "$mount_point/Applications" ] || die "mounted DMG is missing Applications link"
[ "$(readlink "$mount_point/Applications")" = "/Applications" ] \
    || die "mounted DMG Applications link does not target /Applications"
