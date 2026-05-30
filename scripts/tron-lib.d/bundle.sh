#!/bin/bash
# bundle.sh - sourced by tron-lib.sh; do not execute directly.

create_app_bundle() {
    local bundle_path="$1"
    local binary_src="$2"
    local canonical_version="${3:-}"
    local worker_src
    worker_src="$(dirname "$binary_src")/tron-program-worker"
    if [ ! -x "$worker_src" ]; then
        print_error "Cannot create app bundle: sibling tron-program-worker missing or not executable at $worker_src"
        return 1
    fi
    if [ -z "$canonical_version" ]; then
        canonical_version="$(tron_version_env_value TRON_VERSION)" || {
            print_error "Cannot create app bundle without VERSION.env"
            return 1
        }
    fi
    local marketing_version
    marketing_version="$(tron_marketing_version "$canonical_version")"
    local build_version
    build_version="$(tron_version_env_value TRON_APPLE_BUILD)" || {
        print_error "Cannot create app bundle without TRON_APPLE_BUILD in VERSION.env"
        return 1
    }

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

    # Copy icon if available
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    for candidate in \
        "$script_dir/AppIcon.icns" \
        "$CONTRIBUTOR_DIR/AppIcon.icns"; do
        if [ -f "$candidate" ]; then
            cp "$candidate" "$bundle_path/Contents/Resources/AppIcon.icns"
            break
        fi
    done

    cp "$binary_src" "$bundle_path/Contents/MacOS/tron"
    chmod +x "$bundle_path/Contents/MacOS/tron"
    cp "$worker_src" "$bundle_path/Contents/MacOS/tron-program-worker"
    chmod +x "$bundle_path/Contents/MacOS/tron-program-worker"
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
           "$bundle" 2>/dev/null; then
        print_status "Ad-hoc signed bundle"
        return 0
    fi

    print_status "Code signing failed — bundle will be unsigned"
}

notarize_bundle() {
    local bundle="$1"
    local temp_zip=""

    # Cleanup fires on any return path (success, skip, or error).
    # RETURN trap is function-scoped in bash; we clear it before returning
    # to avoid inheriting into the caller's frame on some bash versions.
    trap 'if [ -n "$temp_zip" ] && [ -f "$temp_zip" ]; then rm -f "$temp_zip"; fi; trap - RETURN' RETURN

    # Precondition 1: bundle exists
    if [ -z "$bundle" ] || [ ! -d "$bundle" ]; then
        print_status "Notarization skipped: bundle not found at ${bundle:-<empty>}"
        return 0
    fi

    # Precondition 2: bundle is signed with Developer ID Application.
    # Ad-hoc and Apple Development certs cannot be notarized.
    local sig_info
    sig_info=$(codesign -dvvv "$bundle" 2>&1 || true)
    if echo "$sig_info" | grep -q "Signature=adhoc"; then
        print_status "Notarization skipped: bundle is ad-hoc signed (requires Developer ID)"
        return 0
    fi
    if ! echo "$sig_info" | grep -q "Authority=Developer ID Application"; then
        print_status "Notarization skipped: bundle not signed with Developer ID Application"
        return 0
    fi

    # Precondition 3: xcrun notarytool must be available
    if ! command -v xcrun >/dev/null 2>&1 || ! xcrun --find notarytool >/dev/null 2>&1; then
        print_warning "Notarization skipped: xcrun notarytool not available (install Xcode Command Line Tools)"
        return 0
    fi

    # Precondition 4: keychain profile must exist and credentials must work.
    # We probe with `notarytool history` because there is no offline credential
    # check. This makes a small network call (~1-2s) but gives us a clean
    # fast-fail before zipping the bundle on misconfigured machines.
    local history_err
    if ! history_err=$(xcrun notarytool history --keychain-profile "$NOTARIZE_PROFILE" 2>&1); then
        # Distinguish "credentials missing" from "network / service issue"
        # so the hint we print is actually useful.
        if echo "$history_err" | grep -qiE "keychain profile|no such keychain|credentials|could not find"; then
            print_warning "Notarization skipped: keychain profile '$NOTARIZE_PROFILE' not configured"
            echo "  One-time setup:"
            echo "    xcrun notarytool store-credentials \"$NOTARIZE_PROFILE\" \\"
            echo "      --apple-id <email> --team-id <TEAM_ID>"
            echo "  Get an app-specific password at: https://appleid.apple.com"
        else
            print_warning "Notarization skipped: notarytool check failed (network or service issue)"
            echo "$history_err" | tail -3 | sed 's/^/    /'
        fi
        return 0
    fi

    # Create temp zip. mktemp creates the file; ditto needs a non-existent
    # target, so we remove it first.
    temp_zip=$(mktemp -t tron-notarize.XXXXXX).zip
    rm -f "$temp_zip"
    print_status "Preparing bundle for notarization..."
    if ! ditto -c -k --keepParent "$bundle" "$temp_zip" 2>/dev/null; then
        print_warning "Notarization skipped: failed to create zip archive"
        return 0
    fi

    # Submit and wait (up to 15 minutes — typical submission is 1-5 minutes).
    print_status "Submitting to Apple notary service (may take a few minutes)..."
    local notarize_output
    if notarize_output=$(xcrun notarytool submit "$temp_zip" \
            --keychain-profile "$NOTARIZE_PROFILE" \
            --wait --timeout 15m 2>&1); then

        if echo "$notarize_output" | grep -q "status: Accepted"; then
            print_success "Notarization accepted"

            # Staple the ticket to the bundle so it works offline.
            # Stapling writes to Contents/CodeResources — safe even if the
            # bundle's binary is currently running.
            if xcrun stapler staple "$bundle" >/dev/null 2>&1; then
                print_success "Stapled notarization ticket"
            else
                print_warning "Stapling failed (notarization is still valid on Apple's servers, ticket just isn't embedded)"
            fi
            return 0
        fi

        # Submission completed but not accepted (Invalid / Rejected)
        print_warning "Notarization was not accepted by Apple:"
        echo "$notarize_output" | tail -20 | sed 's/^/    /'

        # Try to surface the submission ID so the user can fetch detailed logs
        local submission_id
        submission_id=$(echo "$notarize_output" \
            | grep -oE 'id: [a-f0-9-]{36}' \
            | head -1 \
            | awk '{print $2}')
        if [ -n "$submission_id" ]; then
            echo "  For details:"
            echo "    xcrun notarytool log $submission_id --keychain-profile $NOTARIZE_PROFILE"
        fi
        return 0
    else
        # Submission itself failed (network timeout, auth error, ...).
        print_warning "Notarization submission failed (non-fatal):"
        echo "$notarize_output" | tail -10 | sed 's/^/    /'
        return 0
    fi
}

sign_and_notarize() {
    local bundle="$1"
    codesign_bundle "$bundle"
    notarize_bundle "$bundle"
}
