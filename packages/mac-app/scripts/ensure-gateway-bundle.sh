#!/usr/bin/env bash
# Ensure the generated Mac Gateway payload is authenticated before Xcode copies
# it into the app. Invalid existing output is rebuilt once, then verified again.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
VERIFY="$SCRIPT_DIR/bundle-gateway.sh"
RESOURCES_DIR="$SCRIPT_DIR/../Sources/Resources"
PAYLOAD_DIR="$RESOURCES_DIR/Gateway"
HELPER_APP="$RESOURCES_DIR/Library/LoginItems/Tron Agent.app"
HELPER_CONTENTS="$HELPER_APP/Contents"

assert_no_symlink_ancestors() {
    local path="$1" cursor="$1"
    while [[ "$cursor" == /* ]]; do
        [[ ! -L "$cursor" ]] || { echo "generated path has a symlinked ancestor: $path" >&2; exit 78; }
        [[ "$cursor" == "/" ]] && break
        cursor="$(dirname "$cursor")"
    done
}
assert_no_symlink_ancestors "$RESOURCES_DIR"
assert_no_symlink_ancestors "$(dirname "$HELPER_CONTENTS")"

# Before touching any generated child, inspect the complete tracked Resources
# chain with lstat semantics. The app and Contents nodes are disposable
# skeletons: if either is a symlink, unlink that exact node and recreate it;
# every other tracked ancestor fails closed rather than being traversed.
prepare_helper_tree() {
    local path
    for path in "$RESOURCES_DIR/Library" "$RESOURCES_DIR/Library/LoginItems" "$HELPER_APP" "$HELPER_CONTENTS" \
        "$HELPER_CONTENTS/MacOS" "$HELPER_CONTENTS/Resources"; do
        if [[ -L "$path" ]]; then
            case "$path" in
                "$HELPER_APP"|"$HELPER_CONTENTS"|"$HELPER_CONTENTS/MacOS"|"$HELPER_CONTENTS/Resources") unlink "$path" ;;
                *) echo "tracked Resources ancestor is a symlink: $path" >&2; exit 78 ;;
            esac
        elif [[ -e "$path" && ! -d "$path" ]]; then
            case "$path" in
                "$HELPER_APP"|"$HELPER_CONTENTS"|"$HELPER_CONTENTS/MacOS"|"$HELPER_CONTENTS/Resources") unlink "$path" ;;
                *) echo "tracked Resources ancestor is not a directory: $path" >&2; exit 78 ;;
            esac
        fi
    done
    if [[ -L "$PAYLOAD_DIR" || ( -e "$PAYLOAD_DIR" && ! -d "$PAYLOAD_DIR" ) ]]; then
        unlink "$PAYLOAD_DIR"
    fi
}

run_bundle() {
    if [[ "${CONFIGURATION:-}" != "Release" ]]; then
        "$VERIFY" "$@" --allow-unconfigured-push
    else
        "$VERIFY" "$@"
    fi
}
if run_bundle --verify-only; then
    echo "Mac Gateway payload is ready (embedded Gateway, production dependencies, and Node runtimes)"
    exit 0
fi

echo "==> Mac Gateway payload failed verification; explicitly rebuilding it"
prepare_helper_tree
mkdir -p "$RESOURCES_DIR" "$HELPER_CONTENTS/MacOS" "$HELPER_CONTENTS/Resources"
# bundle-gateway publishes from a private verified staging root and restores the
# prior generated projection if any bounded publication rename is interrupted.
# Do not erase the prior projection before that transaction is ready.
run_bundle
run_bundle --verify-only
printf 'Mac Gateway payload is ready after rebuild (verified immutable publication)\n'
