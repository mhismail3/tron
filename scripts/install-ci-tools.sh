#!/bin/bash
# Install checksum-pinned CI tools into an isolated, crash-recoverable directory.

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
    local url="$1" destination="$2" checksum="$3" partial
    if [[ -f "$destination" ]] \
        && verify_sha256 "$destination" "$checksum" >/dev/null 2>&1; then
        return
    fi

    partial="$(mktemp "${destination}.partial.XXXXXX")"
    if ! curl \
        --fail \
        --location \
        --silent \
        --show-error \
        --connect-timeout 20 \
        --max-time 600 \
        --retry 5 \
        --retry-all-errors \
        --retry-delay 2 \
        "$url" \
        --output "$partial"; then
        rm -f "$partial"
        return 1
    fi
    if ! verify_sha256 "$partial" "$checksum"; then
        rm -f "$partial"
        return 1
    fi
    mv -f "$partial" "$destination"
}

write_prefix_manifest() {
    local prefix="$1" tool="$2" version="$3"
    python3 - "$prefix" "$tool" "$version" <<'PY'
import hashlib
import json
import os
import stat
import sys
from pathlib import Path

root = Path(sys.argv[1])
tool = sys.argv[2]
version = sys.argv[3]
manifest = root / ".tron-ci-install-manifest.json"


def entry(path: Path) -> dict:
    relative = path.relative_to(root).as_posix()
    metadata = path.lstat()
    mode = stat.S_IMODE(metadata.st_mode)
    if path.is_symlink():
        return {
            "mode": mode,
            "path": relative,
            "target": os.readlink(path),
            "type": "symlink",
        }
    if path.is_dir():
        return {"mode": mode, "path": relative, "type": "directory"}
    if path.is_file():
        payload = path.read_bytes()
        return {
            "mode": mode,
            "path": relative,
            "sha256": hashlib.sha256(payload).hexdigest(),
            "size": len(payload),
            "type": "file",
        }
    raise SystemExit(f"error: unsupported installed payload: {relative}")


entries = []
for directory, directory_names, file_names in os.walk(root, followlinks=False):
    base = Path(directory)
    for name in list(directory_names):
        candidate = base / name
        entries.append(entry(candidate))
        if candidate.is_symlink():
            directory_names.remove(name)
    for name in file_names:
        candidate = base / name
        if candidate != manifest:
            entries.append(entry(candidate))
entries.sort(key=lambda item: item["path"])
if not entries:
    raise SystemExit("error: refusing to seal an empty CI tool prefix")
document = {
    "entries": entries,
    "schema": "tron.ci-tool-prefix.v1",
    "tool": tool,
    "version": version,
}
temporary = manifest.with_name(f".{manifest.name}.{os.getpid()}.tmp")
temporary.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
os.chmod(temporary, 0o600)
os.replace(temporary, manifest)
PY
}

verify_prefix_manifest() {
    local prefix="$1" tool="$2" version="$3"
    python3 - "$prefix" "$tool" "$version" <<'PY'
import hashlib
import json
import os
import stat
import sys
from pathlib import Path

root = Path(sys.argv[1])
tool = sys.argv[2]
version = sys.argv[3]
manifest = root / ".tron-ci-install-manifest.json"
if root.is_symlink() or not root.is_dir() or manifest.is_symlink() or not manifest.is_file():
    raise SystemExit("error: installed CI tool prefix is incomplete")


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate key {key!r}")
        result[key] = value
    return result


try:
    document = json.loads(manifest.read_text(), object_pairs_hook=unique_object)
except (OSError, UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
    raise SystemExit(f"error: installed CI tool manifest is invalid: {error}") from error
if (
    not isinstance(document, dict)
    or set(document) != {"entries", "schema", "tool", "version"}
    or document["schema"] != "tron.ci-tool-prefix.v1"
    or document["tool"] != tool
    or document["version"] != version
    or not isinstance(document["entries"], list)
    or not document["entries"]
):
    raise SystemExit("error: installed CI tool manifest has the wrong identity")


def entry(path: Path) -> dict:
    relative = path.relative_to(root).as_posix()
    metadata = path.lstat()
    mode = stat.S_IMODE(metadata.st_mode)
    if path.is_symlink():
        return {
            "mode": mode,
            "path": relative,
            "target": os.readlink(path),
            "type": "symlink",
        }
    if path.is_dir():
        return {"mode": mode, "path": relative, "type": "directory"}
    if path.is_file():
        payload = path.read_bytes()
        return {
            "mode": mode,
            "path": relative,
            "sha256": hashlib.sha256(payload).hexdigest(),
            "size": len(payload),
            "type": "file",
        }
    raise SystemExit(f"error: unsupported installed payload: {relative}")


actual = []
for directory, directory_names, file_names in os.walk(root, followlinks=False):
    base = Path(directory)
    for name in list(directory_names):
        candidate = base / name
        actual.append(entry(candidate))
        if candidate.is_symlink():
            directory_names.remove(name)
    for name in file_names:
        candidate = base / name
        if candidate != manifest:
            actual.append(entry(candidate))
actual.sort(key=lambda item: item["path"])
if actual != document["entries"]:
    raise SystemExit("error: installed CI tool payload differs from its verified manifest")
PY
}

validate_xcodegen_prefix() {
    local prefix="$1" required
    verify_prefix_manifest "$prefix" xcodegen "$TRON_CI_XCODEGEN_VERSION" || return 1
    [[ -x "$prefix/bin/xcodegen" ]] || return 1
    [[ "$("$prefix/bin/xcodegen" --version 2>&1)" == *"$TRON_CI_XCODEGEN_VERSION"* ]] || return 1
    for required in \
        base.yml \
        Configs/debug.yml \
        Configs/release.yml \
        Platforms/iOS.yml \
        Platforms/macOS.yml; do
        [[ -f "$prefix/share/xcodegen/SettingPresets/$required" ]] || return 1
    done
}

validate_create_dmg_prefix() {
    local prefix="$1" required
    verify_prefix_manifest "$prefix" create-dmg "$TRON_CI_CREATE_DMG_VERSION" || return 1
    [[ -x "$prefix/bin/create-dmg" ]] || return 1
    [[ "$("$prefix/bin/create-dmg" --version 2>&1)" == *"$TRON_CI_CREATE_DMG_VERSION"* ]] || return 1
    for required in template.applescript eula-resources-template.xml; do
        [[ -f "$prefix/share/create-dmg/support/$required" ]] || return 1
    done
}

validate_asc_prefix() {
    local prefix="$1"
    verify_prefix_manifest "$prefix" asc "$TRON_CI_ASC_VERSION" || return 1
    [[ -x "$prefix/asc" ]] || return 1
    [[ "$("$prefix/asc" version 2>&1)" == *"$TRON_CI_ASC_VERSION"* ]] || return 1
}

validate_buildkite_agent_prefix() {
    local prefix="$1"
    verify_prefix_manifest "$prefix" buildkite-agent "$TRON_CI_BUILDKITE_AGENT_VERSION" || return 1
    [[ -x "$prefix/buildkite-agent" ]] || return 1
    [[ "$("$prefix/buildkite-agent" --version 2>&1)" == *"version $TRON_CI_BUILDKITE_AGENT_VERSION"* ]] || return 1
}

acquire_prefix_lock() {
    local prefix="$1" attempt owner stale
    local lock="${prefix}.install-lock"
    for attempt in $(seq 1 100); do
        if mkdir "$lock" 2>/dev/null; then
            printf '%s\n' "$$" > "$lock/pid"
            printf '%s\n' "$lock"
            return 0
        fi
        owner="$(sed -n '1p' "$lock/pid" 2>/dev/null || true)"
        if [[ "$owner" =~ ^[1-9][0-9]*$ ]] && kill -0 "$owner" 2>/dev/null; then
            sleep 0.1
            continue
        fi
        stale="${lock}.stale.$$.${attempt}"
        if mv "$lock" "$stale" 2>/dev/null; then
            rm -rf -- "$stale"
        fi
    done
    echo "error: timed out waiting for CI tool prefix lock: $lock" >&2
    return 1
}

release_prefix_lock() {
    local lock="$1"
    rm -f -- "$lock/pid"
    rmdir "$lock" 2>/dev/null || true
}

publish_staged_prefix() {
    local staging="$1" prefix="$2" retired=""
    if [[ -e "$prefix" || -L "$prefix" ]]; then
        retired="$(mktemp -d "${prefix}.retired.XXXXXX")"
        rmdir "$retired"
        mv "$prefix" "$retired"
    fi
    if mv "$staging" "$prefix"; then
        if [[ -n "$retired" ]]; then
            rm -rf -- "$retired"
        fi
        return 0
    fi
    if [[ -n "$retired" && ! -e "$prefix" && ! -L "$prefix" ]]; then
        mv "$retired" "$prefix" || true
    fi
    return 1
}

ensure_version_prefix() {
    local tool="$1" version="$2" prefix="$3" builder="$4" validator="$5"
    local lock staging status
    shift 5
    if "$validator" "$prefix" >/dev/null 2>&1; then
        return 0
    fi

    lock="$(acquire_prefix_lock "$prefix")"
    if "$validator" "$prefix" >/dev/null 2>&1; then
        release_prefix_lock "$lock"
        return 0
    fi
    staging="$(mktemp -d "${prefix}.staging.XXXXXX")"
    set +e
    (
        set -euo pipefail
        "$builder" "$staging" "$@"
        write_prefix_manifest "$staging" "$tool" "$version"
        "$validator" "$staging"
        publish_staged_prefix "$staging" "$prefix"
    )
    status=$?
    set -e
    if [[ -e "$staging" || -L "$staging" ]]; then
        rm -rf -- "$staging"
    fi
    release_prefix_lock "$lock"
    return "$status"
}

build_xcodegen_prefix() {
    local staging="$1" archive="$2"
    local source="$staging/.source"
    mkdir -p "$source"
    ditto -x -k "$archive" "$source"
    PREFIX="$staging" "$source/xcodegen/install.sh"
    mv "$source/xcodegen/LICENSE" "$staging/LICENSE"
    rm -rf -- "$source"
}

build_create_dmg_prefix() {
    local staging="$1" archive="$2" source
    local source_root="$staging/.source"
    mkdir -p "$source_root" "$staging/bin" "$staging/share/create-dmg"
    tar -xzf "$archive" -C "$source_root"
    source="$source_root/create-dmg-$TRON_CI_CREATE_DMG_VERSION"
    cp "$source/create-dmg" "$staging/bin/create-dmg"
    cp -R "$source/support" "$staging/share/create-dmg/support"
    chmod 755 "$staging/bin/create-dmg"
    rm -rf -- "$source_root"
}

build_asc_prefix() {
    local staging="$1" binary="$2"
    cp "$binary" "$staging/asc"
    chmod 755 "$staging/asc"
}

build_buildkite_agent_prefix() {
    local staging="$1" archive="$2"
    tar -xzf "$archive" -C "$staging" ./buildkite-agent
    chmod 755 "$staging/buildkite-agent"
}

install_xcodegen() {
    local archive="$downloads/xcodegen-$TRON_CI_XCODEGEN_VERSION.zip"
    local prefix="$tools_root/xcodegen-$TRON_CI_XCODEGEN_VERSION"
    download "$TRON_CI_XCODEGEN_URL" "$archive" "$TRON_CI_XCODEGEN_SHA256"
    ensure_version_prefix \
        xcodegen "$TRON_CI_XCODEGEN_VERSION" "$prefix" \
        build_xcodegen_prefix validate_xcodegen_prefix "$archive"
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
    ensure_version_prefix \
        create-dmg "$TRON_CI_CREATE_DMG_VERSION" "$prefix" \
        build_create_dmg_prefix validate_create_dmg_prefix "$archive"
    ln -sfn "$prefix/bin/create-dmg" "$bin_dir/create-dmg"
    mkdir -p "$tools_root/share/create-dmg"
    ln -sfn "$prefix/share/create-dmg/support" "$tools_root/share/create-dmg/support"
}

install_asc() {
    local arch url checksum binary prefix
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
    binary="$downloads/asc-$TRON_CI_ASC_VERSION-$arch"
    prefix="$tools_root/asc-$TRON_CI_ASC_VERSION-$arch"
    download "$url" "$binary" "$checksum"
    ensure_version_prefix \
        asc "$TRON_CI_ASC_VERSION" "$prefix" \
        build_asc_prefix validate_asc_prefix "$binary"
    ln -sfn "$prefix/asc" "$bin_dir/asc"
}

install_buildkite_agent() {
    local platform url checksum archive prefix
    case "$(uname -s):$(uname -m)" in
        Linux:x86_64)
            platform="linux-amd64"
            url="$TRON_CI_BUILDKITE_AGENT_LINUX_AMD64_URL"
            checksum="$TRON_CI_BUILDKITE_AGENT_LINUX_AMD64_SHA256"
            ;;
        Darwin:arm64)
            platform="darwin-arm64"
            url="$TRON_CI_BUILDKITE_AGENT_DARWIN_ARM64_URL"
            checksum="$TRON_CI_BUILDKITE_AGENT_DARWIN_ARM64_SHA256"
            ;;
        *)
            echo "error: unsupported Buildkite agent platform: $(uname -s) $(uname -m)" >&2
            return 1
            ;;
    esac

    archive="$downloads/buildkite-agent-$TRON_CI_BUILDKITE_AGENT_VERSION-$platform.tar.gz"
    prefix="$tools_root/buildkite-agent-$TRON_CI_BUILDKITE_AGENT_VERSION-$platform"
    download "$url" "$archive" "$checksum"
    ensure_version_prefix \
        buildkite-agent "$TRON_CI_BUILDKITE_AGENT_VERSION" "$prefix" \
        build_buildkite_agent_prefix validate_buildkite_agent_prefix "$archive"
    ln -sfn "$prefix/buildkite-agent" "$bin_dir/buildkite-agent"
}

build_self_test_prefix() {
    local staging="$1"
    mkdir -p "$staging/bin" "$staging/share/support"
    printf '#!/bin/bash\nprintf "fixture 1.0\\n"\n' > "$staging/bin/fixture"
    printf 'support payload\n' > "$staging/share/support/payload.txt"
    chmod 755 "$staging/bin/fixture"
}

validate_self_test_prefix() {
    local prefix="$1"
    verify_prefix_manifest "$prefix" fixture 1.0 || return 1
    [[ -x "$prefix/bin/fixture" ]]
    [[ -f "$prefix/share/support/payload.txt" ]]
}

self_test() {
    local test_root prefix moved
    test_root="$(mktemp -d "${TMPDIR:-/tmp}/tron-ci-tools-self-test.XXXXXX")"
    prefix="$test_root/fixture-1.0"
    ensure_version_prefix fixture 1.0 "$prefix" \
        build_self_test_prefix validate_self_test_prefix
    validate_self_test_prefix "$prefix"

    moved="$test_root/missing-support.txt"
    mv "$prefix/share/support/payload.txt" "$moved"
    if validate_self_test_prefix "$prefix" >/dev/null 2>&1; then
        echo "self-test failed: incomplete tool prefix was accepted" >&2
        return 1
    fi
    ensure_version_prefix fixture 1.0 "$prefix" \
        build_self_test_prefix validate_self_test_prefix
    validate_self_test_prefix "$prefix"
    [[ "$(<"$prefix/share/support/payload.txt")" == "support payload" ]]

    printf 'corrupt\n' > "$prefix/bin/fixture"
    if validate_self_test_prefix "$prefix" >/dev/null 2>&1; then
        echo "self-test failed: corrupt tool prefix was accepted" >&2
        return 1
    fi
    ensure_version_prefix fixture 1.0 "$prefix" \
        build_self_test_prefix validate_self_test_prefix
    validate_self_test_prefix "$prefix"
    rm -rf -- "$test_root"
    echo "CI tool installer self-test passed"
}

verify_installed_prefix() {
    local tool="$1" prefix="$2"
    case "$tool" in
        xcodegen) validate_xcodegen_prefix "$prefix" ;;
        create-dmg) validate_create_dmg_prefix "$prefix" ;;
        asc) validate_asc_prefix "$prefix" ;;
        buildkite-agent) validate_buildkite_agent_prefix "$prefix" ;;
        *) echo "error: unsupported installed prefix: $tool" >&2; return 2 ;;
    esac
}

case "${1:-}" in
    --self-test)
        [[ $# -eq 1 ]] || { echo "error: --self-test takes no arguments" >&2; exit 2; }
        self_test
        exit 0
        ;;
    --verify-prefix)
        [[ $# -eq 3 ]] || { echo "usage: scripts/install-ci-tools.sh --verify-prefix <tool> <prefix>" >&2; exit 2; }
        verify_installed_prefix "$2" "$3"
        exit 0
        ;;
esac

if [[ $# -eq 0 ]]; then
    set -- xcodegen create-dmg asc
fi
for tool in "$@"; do
    case "$tool" in
        xcodegen) install_xcodegen ;;
        create-dmg) install_create_dmg ;;
        asc) install_asc ;;
        buildkite-agent) install_buildkite_agent ;;
        *) echo "error: unsupported CI tool: $tool" >&2; exit 2 ;;
    esac
done

if [[ -n "${GITHUB_PATH:-}" ]]; then
    printf '%s\n' "$bin_dir" >> "$GITHUB_PATH"
else
    echo "Add this directory to PATH: $bin_dir"
fi
