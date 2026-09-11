#!/usr/bin/env bash
# Build-only input for the Mac app. No native load, service or Gateway action.
set -euo pipefail
OWNER="$(cd "$(dirname "$0")" && pwd -P)"
: "${DERIVED_FILE_DIR:?Xcode must own the derived output directory}"
mkdir -p "$DERIVED_FILE_DIR"
OUT="$(cd "$DERIVED_FILE_DIR" && pwd -P)"
TEMP="$(mktemp -d "$OUT/native-capture.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
VERSION="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).read_text().strip())' "$OWNER/../../../.node-version")"
HEADERS="${NVM_DIR:-$HOME/.nvm}/versions/node/v$VERSION/include/node"
if [[ -d "$HEADERS" ]]; then
  python3 "$OWNER/build.py" --output "$TEMP/tron-native-capture.node" --headers "$HEADERS"
else
  python3 "$OWNER/build.py" --output "$TEMP/tron-native-capture.node"
fi
# Only these generated Xcode outputs are replaced; input integrity was checked
# during the frozen build and the app's nested signing phase seals final bytes.
install -m 0644 "$TEMP/tron-native-capture.node" "$OUT/tron-native-capture.node"
install -m 0644 "$TEMP/tron-native-capture.inputs.json" "$OUT/tron-native-capture.inputs.json"
