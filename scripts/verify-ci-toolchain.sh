#!/usr/bin/env bash
# Fail when the selected Apple/release tools differ from repository pins.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/config/ci-toolchain.env"
NODE_VERSION_FILE="$ROOT/.node-version"
[[ -f "$NODE_VERSION_FILE" ]] || { echo "missing canonical Node version file: $NODE_VERSION_FILE" >&2; exit 1; }
TRON_NODE_VERSION="$(<"$NODE_VERSION_FILE")"
CHECKOUT_PIN='11d5960a326750d5838078e36cf38b85af677262'
SETUP_NODE_PIN='49933ea5288caeca8642d1e84afbd3f7d6820020'
UPLOAD_ARTIFACT_PIN='ea165f8d65b6e75b540449e92b4886f43607fa02'
node_version_lines="$(awk 'END { print NR }' "$NODE_VERSION_FILE")"
[[ "$node_version_lines" == 1 && "$TRON_NODE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || { echo "canonical Node version must be one strict x.y.z line (found $TRON_NODE_VERSION)" >&2; exit 1; }
workflow_action_count() {
  local action="$1" pin="$2" expected actual
  expected="$(grep -RhEc "uses:[[:space:]]*actions/${action}@${pin}[[:space:]]+# v4[[:space:]]*$" "$ROOT/.github/workflows" 2>/dev/null | awk '{ total += $1 } END { print total + 0 }')"
  actual="$(grep -RhEc "uses:[[:space:]]*actions/${action}@" "$ROOT/.github/workflows" 2>/dev/null | awk '{ total += $1 } END { print total + 0 }')"
  [[ "$expected" == "$actual" && "$actual" != 0 ]] || {
    echo "CI actions/${action} uses must be pinned to ${pin} with a trailing v4 comment" >&2
    return 1
  }
}
workflow_action_count checkout "$CHECKOUT_PIN"
workflow_action_count setup-node "$SETUP_NODE_PIN"
workflow_action_count upload-artifact "$UPLOAD_ARTIFACT_PIN"

for tool in "$@"; do
  case "$tool" in
    node)
      [[ "$(node --version 2>/dev/null || true)" == "v${TRON_NODE_VERSION}" ]] \
        || { echo "Node must be exactly ${TRON_NODE_VERSION}" >&2; exit 1; }
      setup_node_count="$(grep -Rho 'uses:[[:space:]]*actions/setup-node@' "$ROOT/.github/workflows" 2>/dev/null | wc -l | tr -d ' ')"
      workflow_count="$(grep -Rho 'node-version-file: \.node-version' "$ROOT/.github/workflows" 2>/dev/null | wc -l | tr -d ' ')"
      [[ "$setup_node_count" == "$workflow_count" && "$workflow_count" != 0 ]] || { echo "CI setup-node uses must mirror .node-version dynamically" >&2; exit 1; }
      ! grep -RqsE 'node-version:[[:space:]]*[0-9]' "$ROOT/.github/workflows" \
        || { echo "CI contains a duplicated Node version literal" >&2; exit 1; }
      ! grep -qE '^NODE_VERSION="[0-9]' "$ROOT/packages/mac-app/scripts/bundle-gateway.sh" \
        || { echo "Mac bundle script contains a duplicated Node version literal" >&2; exit 1; }
      grep -qF 'NODE_VERSION_FILE="$REPO_ROOT/.node-version"' "$ROOT/packages/mac-app/scripts/bundle-gateway.sh" \
        || { echo "Mac bundle script does not read .node-version" >&2; exit 1; }
      ;;
    xcode)
      xcodebuild -version | grep -F "Xcode $TRON_CI_XCODE_VERSION" >/dev/null
      ;;
    ios)
      xcodebuild -version | grep -F "Xcode $TRON_CI_XCODE_VERSION" >/dev/null
      xcrun simctl list runtimes | grep -F "iOS $TRON_CI_IOS_RUNTIME_VERSION" >/dev/null
      ;;
    xcodegen)
      xcodegen --version | grep -F "$TRON_CI_XCODEGEN_VERSION" >/dev/null
      presets="$(cd "$(dirname "$(command -v xcodegen)")/../share/xcodegen/SettingPresets" 2>/dev/null && pwd -P)" \
        || { echo "xcodegen setting presets are unavailable" >&2; exit 1; }
      [[ -f "$presets/base.yml" && -f "$presets/Platforms/iOS.yml" && -f "$presets/Platforms/macOS.yml" ]] \
        || { echo "xcodegen setting presets are incomplete" >&2; exit 1; }
      ;;
    asc)
      asc version 2>&1 | grep -F "$TRON_CI_ASC_VERSION" >/dev/null
      ;;
    *) echo "unsupported tool verification: $tool" >&2; exit 64 ;;
  esac
done
