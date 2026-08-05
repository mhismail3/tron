#!/bin/bash
# Install checksum-pinned CI tools into an isolated runner directory.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$repo_root/config/ci-toolchain.env"

tools_root="${TRON_CI_TOOLS_DIR:-${RUNNER_TEMP:-/tmp}/tron-ci-tools}"
bin_dir="$tools_root/bin"
downloads="$tools_root/downloads"
mkdir -p "$bin_dir" "$downloads"

verify_sha256() {
    local path="$1" expected="$2" actual
    actual="$(shasum -a 256 "$path" | awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
        echo "error: checksum mismatch for $path (expected $expected, got $actual)" >&2
        return 1
    fi
}

download() {
    local url="$1" destination="$2" checksum="$3"
    if [[ ! -f "$destination" ]]; then
        curl --fail --location --silent --show-error "$url" --output "$destination"
    fi
    verify_sha256 "$destination" "$checksum"
}

install_xcodegen() {
    local archive="$downloads/xcodegen-$TRON_CI_XCODEGEN_VERSION.zip"
    local prefix="$tools_root/xcodegen-$TRON_CI_XCODEGEN_VERSION"
    download "$TRON_CI_XCODEGEN_URL" "$archive" "$TRON_CI_XCODEGEN_SHA256"
    if [[ ! -x "$prefix/bin/xcodegen" ]]; then
        mkdir -p "$prefix"
        ditto -x -k "$archive" "$prefix.unpack"
        PREFIX="$prefix" "$prefix.unpack/xcodegen/install.sh"
        mv "$prefix.unpack/xcodegen/LICENSE" "$prefix/LICENSE"
        rmdir "$prefix.unpack/xcodegen/bin" "$prefix.unpack/xcodegen/share" 2>/dev/null || true
        rm -r "$prefix.unpack"
    fi
    ln -sfn "$prefix/bin/xcodegen" "$bin_dir/xcodegen"
    mkdir -p "$tools_root/share"
    # XcodeGen resolves SettingPresets beside the invoked bin directory. The
    # release binary alone appears healthy but generates empty product names.
    ln -sfn "$prefix/share/xcodegen" "$tools_root/share/xcodegen"
}

install_create_dmg() {
    local archive="$downloads/create-dmg-$TRON_CI_CREATE_DMG_VERSION.tar.gz"
    local prefix="$tools_root/create-dmg-$TRON_CI_CREATE_DMG_VERSION"
    download "$TRON_CI_CREATE_DMG_URL" "$archive" "$TRON_CI_CREATE_DMG_SHA256"
    if [[ ! -x "$prefix/bin/create-dmg" ]]; then
        mkdir -p "$prefix/bin" "$prefix/share/create-dmg"
        tar -xzf "$archive" -C "$downloads"
        local source="$downloads/create-dmg-$TRON_CI_CREATE_DMG_VERSION"
        cp "$source/create-dmg" "$prefix/bin/create-dmg"
        cp -R "$source/support" "$prefix/share/create-dmg/support"
        chmod +x "$prefix/bin/create-dmg"
        rm -r "$source"
    fi
    ln -sfn "$prefix/bin/create-dmg" "$bin_dir/create-dmg"
    mkdir -p "$tools_root/share/create-dmg"
    ln -sfn "$prefix/share/create-dmg/support" "$tools_root/share/create-dmg/support"
}

install_asc() {
    local arch url checksum
    arch="$(uname -m)"
    case "$arch" in
        arm64)
            url="$TRON_CI_ASC_MACOS_ARM64_URL"
            checksum="$TRON_CI_ASC_MACOS_ARM64_SHA256"
            ;;
        x86_64)
            url="$TRON_CI_ASC_MACOS_AMD64_URL"
            checksum="$TRON_CI_ASC_MACOS_AMD64_SHA256"
            ;;
        *)
            echo "error: unsupported ASC architecture: $arch" >&2
            return 1
            ;;
    esac
    local binary="$downloads/asc-$TRON_CI_ASC_VERSION-$arch"
    download "$url" "$binary" "$checksum"
    chmod +x "$binary"
    ln -sfn "$binary" "$bin_dir/asc"
}

if [[ $# -eq 0 ]]; then
    set -- xcodegen create-dmg asc
fi
for tool in "$@"; do
    case "$tool" in
        xcodegen) install_xcodegen ;;
        create-dmg) install_create_dmg ;;
        asc) install_asc ;;
        *) echo "error: unsupported CI tool: $tool" >&2; exit 2 ;;
    esac
done

if [[ -n "${GITHUB_PATH:-}" ]]; then
    printf '%s\n' "$bin_dir" >> "$GITHUB_PATH"
else
    echo "Add this directory to PATH: $bin_dir"
fi
