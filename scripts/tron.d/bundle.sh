#!/bin/bash
# bundle.sh - workspace bundle construction/signing; sourced by scripts/tron.

create_app_bundle() {
    local bundle_path="$1"
    local binary_src="$2"
    local version_fields canonical_version marketing_version build_version key value
    version_fields="$("$SCRIPT_DIR/tron-version" print)" || {
        print_error "Cannot create app bundle without valid version metadata"
        return 1
    }
    while IFS='=' read -r key value; do
        case "$key" in
            TRON_VERSION) canonical_version="$value" ;;
            TRON_APPLE_MARKETING_VERSION) marketing_version="$value" ;;
            TRON_APPLE_BUILD) build_version="$value" ;;
        esac
    done <<< "$version_fields"
    if [ -z "${canonical_version:-}" ] || [ -z "${marketing_version:-}" ] || [ -z "${build_version:-}" ]; then
        print_error "Version helper omitted required bundle metadata"
        return 1
    fi

    # Delete the entire .app bundle, not just its contents. macOS App
    # Management TCC protects files *inside* .app bundles from modification
    # by non-authorized processes (launchd agents). But deleting the .app
    # itself is a parent-directory operation on ~/.tron/internal/, which is
    # not protected. codesign_bundle re-signs the new bundle afterward.
    rm -rf "$bundle_path"

    mkdir -p "$bundle_path/Contents/MacOS"
    mkdir -p "$bundle_path/Contents/Resources"

    cat > "$bundle_path/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>$TRON_BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>Tron</string>
    <key>CFBundleDisplayName</key>
    <string>Tron</string>
    <key>CFBundleExecutable</key>
    <string>tron</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleVersion</key>
    <string>$build_version</string>
    <key>CFBundleShortVersionString</key>
    <string>$marketing_version</string>
    <key>TRONCanonicalVersion</key>
    <string>$canonical_version</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSBackgroundOnly</key>
    <true/>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

    local app_icon="$PROJECT_DIR/packages/mac-app/Sources/Resources/AppIcon.icns"
    if [ ! -f "$app_icon" ] || [ -L "$app_icon" ]; then
        print_error "Canonical Mac app icon is missing: $app_icon"
        return 1
    fi
    cp "$app_icon" "$bundle_path/Contents/Resources/AppIcon.icns"

    cp "$binary_src" "$bundle_path/Contents/MacOS/tron"
    chmod +x "$bundle_path/Contents/MacOS/tron"
}

codesign_bundle() {
    local bundle="$1"
    local identity entitlements

    # Find valid identity — filter revoked, prefer Developer ID > Apple Development
    identity=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -v "REVOKED" \
        | grep '"Developer ID Application' \
        | head -1 \
        | sed -n 's/.*"\(.*\)".*/\1/p')
    if [ -z "$identity" ]; then
        identity=$(security find-identity -v -p codesigning 2>/dev/null \
            | grep -v "REVOKED" \
            | grep '"Apple Development' \
            | head -1 \
            | sed -n 's/.*"\(.*\)".*/\1/p')
    fi
    if [ -z "$identity" ]; then
        identity=$(security find-identity -v -p codesigning 2>/dev/null \
            | grep -v "REVOKED" \
            | grep '"' \
            | head -1 \
            | sed -n 's/.*"\(.*\)".*/\1/p')
    fi

    # Locate entitlements file
    entitlements=""
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    for candidate in \
        "$script_dir/tron-agent.entitlements" \
        "$CONTRIBUTOR_DIR/tron-agent.entitlements"; do
        if [ -f "$candidate" ]; then
            entitlements="$candidate"
            break
        fi
    done

    # Tier 1: Full signing (cert + hardened runtime + entitlements)
    if [ -n "$identity" ] && [ -n "$entitlements" ]; then
        if codesign --force --deep --sign "$identity" \
               --identifier "$TRON_BUNDLE_ID" \
               --options runtime \
               --entitlements "$entitlements" \
               "$bundle" 2>/dev/null && \
           codesign --verify --strict "$bundle" 2>/dev/null; then
            print_status "Signed bundle (${identity})"
            return 0
        fi
    fi

    # Tier 2: Cert + hardened runtime without entitlements
    if [ -n "$identity" ]; then
        if codesign --force --deep --sign "$identity" \
               --identifier "$TRON_BUNDLE_ID" \
               --options runtime \
               "$bundle" 2>/dev/null && \
           codesign --verify --strict "$bundle" 2>/dev/null; then
            print_status "Signed bundle without entitlements (${identity})"
            return 0
        fi
    fi

    # Tier 3: Ad-hoc signing (no cert — works for dev, not distribution)
    if codesign --force --deep --sign - \
           --identifier "$TRON_BUNDLE_ID" \
           "$bundle" 2>/dev/null && \
       codesign --verify --strict "$bundle" 2>/dev/null; then
        print_status "Ad-hoc signed bundle"
        return 0
    fi

    print_error "Code signing failed"
    return 1
}
