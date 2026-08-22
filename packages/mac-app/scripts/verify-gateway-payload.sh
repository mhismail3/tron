#!/usr/bin/env bash
# Verify a generated Gateway payload without changing it. The verifier compiles
# a fresh launcher from the tracked C source; it never trusts the staged helper.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd -P)"
PAYLOAD_DIR="${1:-}"
HELPER="${2:-}"
NODE_VERSION_FILE="$REPO_ROOT/.node-version"
NODE_ARM64_SHA256="913b144fdb40638b1acef7974ab3c33fbd527cc0974cb5da467ab1e6ac51b4d4"
NODE_X64_SHA256="bf0e0ff20d4e5a16436d1ec372e47161e52be8e487db8070ae3f06b01efbba0c"

[[ $# -eq 2 ]] || { echo "usage: verify-gateway-payload.sh PAYLOAD_ROOT STAGED_HELPER" >&2; exit 64; }
fail() { echo "Gateway payload verification failed: $*" >&2; exit 78; }
assert_no_symlink_ancestors() {
    local path="$1" cursor="$1"
    while [[ "$cursor" == /* ]]; do
        [[ ! -L "$cursor" ]] || fail "symlinked ancestor in generated path: $path"
        [[ "$cursor" == "/" ]] && break
        cursor="$(dirname "$cursor")"
    done
}
[[ -d "$PAYLOAD_DIR" && ! -L "$PAYLOAD_DIR" ]] || fail "payload root is not a regular directory"
HELPER_PARENT="$(dirname "$HELPER")"
assert_no_symlink_ancestors "$PAYLOAD_DIR"
assert_no_symlink_ancestors "$HELPER_PARENT"
HELPER_CONTENTS_INPUT="$HELPER_PARENT/.."
[[ ! -L "$HELPER_PARENT" && ! -L "$HELPER_CONTENTS_INPUT" && ! -L "$HELPER_CONTENTS_INPUT/Resources" ]] ||
    fail "staged helper contains an escaping symlink"
PAYLOAD_DIR="$(realpath "$PAYLOAD_DIR")"
HELPER="$(realpath "$HELPER_PARENT")/$(basename "$HELPER")"
[[ -f "$NODE_VERSION_FILE" ]] || { echo "missing canonical Node version file" >&2; exit 3; }
NODE_VERSION="$(<"$NODE_VERSION_FILE")"
NODE_VERSION_LINES="$(awk 'END { print NR }' "$NODE_VERSION_FILE")"
[[ "$NODE_VERSION_LINES" == 1 && "$NODE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "invalid canonical Node version" >&2; exit 3;
}

[[ -d "$PAYLOAD_DIR" && ! -L "$PAYLOAD_DIR" ]] || fail "payload root is not a regular directory"
[[ -d "$PAYLOAD_DIR/app" && ! -L "$PAYLOAD_DIR/app" ]] || fail "app directory is missing or symlinked"
[[ -d "$PAYLOAD_DIR/runtime" && ! -L "$PAYLOAD_DIR/runtime" ]] || fail "runtime directory is missing or symlinked"
[[ -f "$PAYLOAD_DIR/manifest.json" && ! -L "$PAYLOAD_DIR/manifest.json" ]] || fail "manifest is missing or symlinked"
[[ -f "$HELPER" && ! -L "$HELPER" && -x "$HELPER" ]] || fail "staged helper is missing, symlinked, or not executable"

# Check the publication mode before invoking any verifier. The C verifier also
# checks this recursively, including the manifest, while this explicit check
# keeps the policy visible and rejects writable special paths before Xcode.
if find "$PAYLOAD_DIR" -type f -perm -022 -print -quit | grep -q . ||
   find "$PAYLOAD_DIR" -type d -perm -022 -print -quit | grep -q .; then
    fail "published payload tree is writable"
fi

for required_directory in \
    "$PAYLOAD_DIR/app/dist" "$PAYLOAD_DIR/app/scripts" "$PAYLOAD_DIR/app/node_modules" \
    "$PAYLOAD_DIR/runtime"; do
    [[ -d "$required_directory" && ! -L "$required_directory" ]] || fail "required directory missing: $required_directory"
done
for required_file in \
    "$PAYLOAD_DIR/manifest.json" "$PAYLOAD_DIR/app/dist/index.js" \
    "$PAYLOAD_DIR/app/package.json" "$PAYLOAD_DIR/app/package-lock.json" \
    "$PAYLOAD_DIR/app/scripts/ensure-node-pty-helper.mjs" \
    "$PAYLOAD_DIR/app/scripts/gateway-payload-deploy.mjs" \
    "$PAYLOAD_DIR/runtime/node-arm64" "$PAYLOAD_DIR/runtime/node-x64"; do
    [[ -f "$required_file" && ! -L "$required_file" ]] || fail "required file missing or symlinked: $required_file"
done

validate_runtime() {
    local arch="$1" expected_sha="$2" expected_arch="arm64" path="$PAYLOAD_DIR/runtime/node-$1"
    [[ "$arch" == x64 ]] && expected_arch="x86_64"
    local actual_sha file_description lipo_arches
    actual_sha="$(shasum -a 256 "$path" | awk '{print $1}')" || fail "cannot hash Node $arch runtime"
    [[ "$actual_sha" == "$expected_sha" ]] || fail "Node $arch runtime checksum mismatch"
    file_description="$(file "$path" 2>/dev/null)" || fail "cannot inspect Node $arch runtime"
    [[ "$file_description" == *Mach-O* ]] || fail "Node $arch runtime is not Mach-O"
    lipo_arches="$(lipo -archs "$path" 2>/dev/null)" || fail "cannot inspect Node $arch architecture"
    [[ "$lipo_arches" == "$expected_arch" ]] || fail "Node $arch runtime architecture mismatch"
}
validate_runtime arm64 "$NODE_ARM64_SHA256"
validate_runtime x64 "$NODE_X64_SHA256"

# The helper must remain unsigned until Xcode's signing phases. This keeps the
# deterministic pre-signing byte comparison meaningful and makes signing the
# explicit boundary protecting the immutable resource tree.
HELPER_CONTENTS="$(cd "$(dirname "$HELPER")/.." && pwd -P)"
[[ "$(realpath "$HELPER")" == "$HELPER" && ! -L "$HELPER_CONTENTS" && ! -L "$HELPER_CONTENTS/MacOS" && ! -L "$HELPER_CONTENTS/Resources" ]] ||
    fail "staged helper contains an escaping symlink"
[[ -f "$HELPER_CONTENTS/Info.plist" && ! -L "$HELPER_CONTENTS/Info.plist" ]] || fail "helper Info.plist is missing"
[[ -d "$HELPER_CONTENTS/MacOS" && -d "$HELPER_CONTENTS/Resources" ]] || fail "helper app directories are incomplete"
helper_file="$(file "$HELPER" 2>/dev/null)" || fail "cannot inspect staged helper"
[[ "$helper_file" == *Mach-O* ]] || fail "staged helper is not Mach-O"
helper_arches="$(lipo -archs "$HELPER" 2>/dev/null)" || fail "cannot inspect staged helper architectures"
helper_has_arm64=0
helper_has_x86_64=0
helper_arch_count=0
for helper_arch in $helper_arches; do
    ((helper_arch_count += 1))
    [[ "$helper_arch" == arm64 ]] && helper_has_arm64=1
    [[ "$helper_arch" == x86_64 ]] && helper_has_x86_64=1
done
[[ "$helper_arch_count" == 2 && "$helper_has_arm64" == 1 && "$helper_has_x86_64" == 1 ]] ||
    fail "staged helper is not the expected universal executable"
TRUSTED_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/tron-gateway-verifier.XXXXXX")"
trap 'rm -rf "$TRUSTED_TEMP"' EXIT
TRUSTED_VERIFIER="$TRUSTED_TEMP/tron"
xcrun --sdk macosx clang -O2 -Wall -Wextra -Werror -Wno-deprecated-declarations \
    -arch arm64 -arch x86_64 -mmacosx-version-min=15.0 \
    "$SCRIPT_DIR/tron-gateway-launcher.c" -o "$TRUSTED_VERIFIER" || fail "trusted verifier compilation failed"
[[ ! -d "$HELPER_CONTENTS/_CodeSignature" ]] || fail "staged helper must be unsigned before Xcode signing"
# The linker emits a fresh LC_UUID on each build. Normalize only that
# non-source identity field before comparing every remaining helper byte.
normalize_helper_uuid() {
    local input="$1" output="$2"
    perl -0777 -pe 'my $count = s/\x1b\x00\x00\x00\x18\x00\x00\x00[\s\S]{16}/\x1b\x00\x00\x00\x18\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00/gs; die "unexpected Mach-O UUID command count: $count\\n" unless $count == 2;' "$input" > "$output"
}
normalize_helper_uuid "$TRUSTED_VERIFIER" "$TRUSTED_TEMP/trusted-normalized"
normalize_helper_uuid "$HELPER" "$TRUSTED_TEMP/staged-normalized"
cmp -s "$TRUSTED_TEMP/trusted-normalized" "$TRUSTED_TEMP/staged-normalized" || fail "staged helper differs from freshly compiled trusted source"
GATEWAY_VERSION="$(plutil -extract version raw -o - "$REPO_ROOT/packages/gateway/package.json" 2>/dev/null || true)"
SOURCE_REVISION="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)"
[[ "$GATEWAY_VERSION" =~ ^[A-Za-z0-9._-]{1,127}$ && "$SOURCE_REVISION" =~ ^[0-9a-f]{40}$ ]] || fail "source identity is unavailable"
"$TRUSTED_VERIFIER" --verify-payload "$PAYLOAD_DIR" "$NODE_VERSION" "$GATEWAY_VERSION" "$SOURCE_REVISION" ||
    fail "manifest, symlink, required-path, immutability, or fingerprint check failed"

printf 'verified Tron Gateway payload (Node %s, immutable fingerprint and universal helper)\n' "$NODE_VERSION"
