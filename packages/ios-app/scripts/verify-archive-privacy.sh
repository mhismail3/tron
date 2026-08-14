#!/bin/bash
set -euo pipefail

archive_path="${1:?usage: verify-archive-privacy.sh <path-to-xcarchive>}"
applications="$archive_path/Products/Applications"
app_count="$(find "$applications" -maxdepth 1 -type d -name '*.app' -print | wc -l | tr -d ' ')"
if [[ "$app_count" != "1" ]]; then
  echo "expected exactly one app in archive, found $app_count" >&2
  exit 1
fi

app="$(find "$applications" -maxdepth 1 -type d -name '*.app' -print)"
app_manifest="$app/PrivacyInfo.xcprivacy"
extension_count="$(find "$app/PlugIns" -maxdepth 1 -type d -name '*.appex' -print | wc -l | tr -d ' ')"
if [[ "$extension_count" != "1" ]]; then
  echo "expected exactly one extension in archive, found $extension_count" >&2
  exit 1
fi
extension="$(find "$app/PlugIns" -maxdepth 1 -type d -name '*.appex' -print)"
extension_manifest="$extension/PrivacyInfo.xcprivacy"

for manifest in "$app_manifest" "$extension_manifest"; do
  if [[ ! -f "$manifest" ]]; then
    echo "missing privacy manifest: $manifest" >&2
    exit 1
  fi
  plutil -lint "$manifest" >/dev/null
done

echo "privacy manifests verified for app and extension"
