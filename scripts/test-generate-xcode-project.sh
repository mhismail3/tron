#!/usr/bin/env bash
# Hardware-free contract tests for the canonical native-project generator.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/config/ci-toolchain.env"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tron-xcodegen-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
TOOLS="$TMP/tools"
LOG="$TMP/invocations.log"
mkdir -p "$TOOLS/bin" "$TOOLS/share/xcodegen/SettingPresets/Platforms"
printf '%s\n' 'PRODUCT_NAME: $TARGET_NAME' > "$TOOLS/share/xcodegen/SettingPresets/base.yml"
printf '%s\n' 'SUPPORTED_PLATFORMS: iphoneos iphonesimulator' > "$TOOLS/share/xcodegen/SettingPresets/Platforms/iOS.yml"
printf '%s\n' 'SUPPORTED_PLATFORMS: macosx' > "$TOOLS/share/xcodegen/SettingPresets/Platforms/macOS.yml"
cat > "$TOOLS/bin/xcodegen" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then
  printf 'Version: %s\n' "${FAKE_XCODEGEN_VERSION:?}"
  exit 0
fi
printf '%s|%s\n' "$PWD" "$*" >> "${FAKE_XCODEGEN_LOG:?}"
EOF
chmod +x "$TOOLS/bin/xcodegen"

run_generator() {
  TRON_CI_TOOLS_DIR="$TOOLS" \
  FAKE_XCODEGEN_VERSION="$TRON_CI_XCODEGEN_VERSION" \
  FAKE_XCODEGEN_LOG="$LOG" \
    "$ROOT/scripts/generate-xcode-project" "$@"
}

run_generator ios --quiet
run_generator mac --quiet
first_invocation="$(sed -n '1p' "$LOG")"
second_invocation="$(sed -n '2p' "$LOG")"
[[ "$first_invocation" == "$ROOT/packages/ios-app|generate --quiet" ]]
[[ "$second_invocation" == "$ROOT/packages/mac-app|generate --quiet" ]]

if TRON_CI_TOOLS_DIR="$TOOLS" FAKE_XCODEGEN_VERSION=0.0.0 FAKE_XCODEGEN_LOG="$LOG" \
  "$ROOT/scripts/generate-xcode-project" ios; then
  echo "mismatched XcodeGen was accepted" >&2
  exit 1
fi

printf '%s\n' "native project generator contract passed"
