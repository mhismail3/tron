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

# Remove only generated roots after a failed verification. lstat-style checks
# ensure a symlink is unlinked as a link and never traversed into its target.
safe_remove_tree() {
    local path="$1" entry
    [[ -e "$path" || -L "$path" ]] || return 0
    if [[ -L "$path" ]]; then
        unlink "$path"
    elif [[ -d "$path" ]]; then
        chmod u+w "$path"
        while IFS= read -r -d '' entry; do safe_remove_tree "$entry"; done < <(find "$path" -mindepth 1 -maxdepth 1 -print0)
        rmdir "$path"
    else
        unlink "$path"
    fi
}
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
    for path in "$RESOURCES_DIR/Library" "$RESOURCES_DIR/Library/LoginItems" "$HELPER_APP" "$HELPER_CONTENTS"; do
        if [[ -L "$path" ]]; then
            case "$path" in
                "$HELPER_APP"|"$HELPER_CONTENTS") unlink "$path" ;;
                *) echo "tracked Resources ancestor is a symlink: $path" >&2; exit 78 ;;
            esac
        elif [[ -e "$path" && ! -d "$path" ]]; then
            echo "tracked Resources ancestor is not a directory: $path" >&2
            exit 78
        fi
    done
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
safe_remove_tree "$PAYLOAD_DIR"
safe_remove_tree "$HELPER_CONTENTS/MacOS"
safe_remove_tree "$HELPER_CONTENTS/Resources/AppIcon.icns"
mkdir -p "$RESOURCES_DIR" "$HELPER_CONTENTS/MacOS" "$HELPER_CONTENTS/Resources"
run_bundle
run_bundle --verify-only
printf 'Mac Gateway payload is ready after rebuild (verified immutable publication)\n'
