#!/usr/bin/env python3
"""Compile only: one universal C Node-API8 client; no signing, loading or launch.

The four C headers are authenticated independently of the staged Node binaries.
Only the --test artifact substitutes the NSXPC edge and exports fault controls.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[3]
OWNER = "packages/mac-app/native-gateway-client"
INPUTS = (
    ".node-version",
    f"{OWNER}/addon.mm",
    f"{OWNER}/transport.h",
    f"{OWNER}/transport.mm",
    f"{OWNER}/build.py",
    f"{OWNER}/node-headers.json",
    "packages/mac-app/Sources/Support/Onboarding/NativeCaptureService.h",
)
HEADERS = {"node_api.h", "node_api_types.h", "js_native_api.h", "js_native_api_types.h"}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def validate_output(output):
    metadata = output.with_suffix(".inputs.json")
    for candidate in [output, metadata]:
        if candidate.exists() or candidate.is_symlink():
            raise ValueError("output and metadata must both be fresh, not symlinks")
        if any(p.is_symlink() for p in candidate.parents):
            raise ValueError("output ancestors must not be symlinks")
    home = Path.home().resolve()
    resolved = output.resolve()
    if resolved.is_relative_to(home / ".pi") or resolved.is_relative_to(home / ".tron-dev") or (
        resolved.is_relative_to(home / ".tron") and not resolved.is_relative_to(home / ".tron/workspace/files")
    ):
        raise ValueError("canonical runtime/settings/state outputs are prohibited")
    if any(resolved.is_relative_to(p) for p in [Path("/Applications"), Path("/System"), Path("/Library")]):
        raise ValueError("installation/system outputs are prohibited")
    return metadata


def publish(artifact, output, manifest):
    # The compile-time freshness check is not publication authority. Pin the
    # parent and exclusively create BOTH names without following a raced link.
    # A partial publication stays as failed evidence; never unlink or overwrite.
    metadata = validate_output(output)
    parent = os.open(output.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
        with os.fdopen(os.open(output.name, flags, 0o644, dir_fd=parent), "wb") as destination:
            with artifact.open("rb") as source:
                shutil.copyfileobj(source, destination)
            destination.flush()
            os.fsync(destination.fileno())
        with os.fdopen(os.open(metadata.name, flags, 0o644, dir_fd=parent), "wb") as destination:
            destination.write((json.dumps(manifest, sort_keys=True, indent=2) + "\n").encode())
            destination.flush()
            os.fsync(destination.fileno())
        os.fsync(parent)
        pinned = os.fstat(parent)
        observed = os.stat(output.parent, follow_symlinks=False)
        if (pinned.st_dev, pinned.st_ino) != (observed.st_dev, observed.st_ino):
            raise ValueError("output directory changed during publication")
    finally:
        os.close(parent)


def build(output, headers=None, test=False):
    name = "tron-native-capture-test.node" if test else "tron-native-capture.node"
    output = Path(os.path.abspath(output))
    if output.name != name:
        raise ValueError(f"output must be a fresh {name}")
    validate_output(output)
    snapshot = {name: (ROOT / name).read_bytes() for name in INPUTS}
    pin = json.loads(snapshot[f"{OWNER}/node-headers.json"])
    version = snapshot[".node-version"].decode().strip()
    if pin["version"] != version or set(pin["sha256"]) != HEADERS:
        raise ValueError("canonical Node version/header inputs changed; review header pins")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="tron-native-capture-build-") as temporary:
        frozen = Path(temporary)
        for name, data in snapshot.items():
            target = frozen / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        include = frozen / "headers"
        include.mkdir()
        for name in sorted(HEADERS):
            if headers:
                data = (Path(headers) / name).read_bytes()
            else:
                url = f"https://raw.githubusercontent.com/nodejs/node/v{version}/src/{name}"
                with urllib.request.urlopen(url, timeout=30) as response:
                    data = response.read(1024 * 1024)
            if digest(data) != pin["sha256"][name]:
                raise ValueError(f"Node {version} C header integrity mismatch: {name}")
            (include / name).write_bytes(data)
        artifact = frozen / output.name
        command = [
            "xcrun", "--sdk", "macosx", "clang++", "-std=c++17", "-fobjc-arc", "-fblocks",
            "-DNAPI_VERSION=8", "-DBUILDING_NODE_EXTENSION", "-I", str(include),
            "-arch", "arm64", "-arch", "x86_64", "-mmacosx-version-min=15.0",
            "-Wall", "-Wextra", "-Werror", "-O2", "-fvisibility=hidden",
            "-bundle", "-undefined", "dynamic_lookup", "-framework", "Foundation", "-framework", "Security",
            *(["-DTRON_CAPTURE_TEST=1"] if test else []),
            str(frozen / OWNER / "addon.mm"), str(frozen / OWNER / "transport.mm"), "-o", str(artifact),
        ]
        print(" ".join(command), flush=True)
        subprocess.run(command, check=True)
        architectures = set(subprocess.check_output(["lipo", "-archs", str(artifact)], text=True).split())
        if architectures != {"arm64", "x86_64"}:
            raise ValueError("addon is not exactly universal arm64/x86_64")
        symbols = subprocess.check_output(["nm", "-u", str(artifact)], text=True)
        if any(symbol in symbols for symbol in ["__ZN2v8", "__ZN4node", "_uv_"]):
            raise ValueError("addon uses a forbidden Node/V8/libuv ABI")
        if any((ROOT / name).read_bytes() != data for name, data in snapshot.items()):
            raise ValueError("native client source changed during frozen compilation")
        manifest = {"schema": 1, "testOnly": test, "inputs": {name: digest(data) for name, data in snapshot.items()}}
        # Signing is deliberately left to the existing Mac nested-Mach-O phase;
        # its final runtime fingerprint covers these metadata and signed bytes.
        publish(artifact, output, manifest)
        print(f"compiled {output} sha256={digest(artifact.read_bytes())}")


def verify_inputs(metadata):
    descriptor = os.open(metadata, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as source:
        if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
            raise ValueError("native capture input manifest must be regular")
        data = source.read(65537)
    if len(data) > 65536:
        raise ValueError("native capture input manifest exceeds bounds")
    expected = {"schema": 1, "testOnly": False,
                "inputs": {name: digest((ROOT / name).read_bytes()) for name in INPUTS}}
    if json.loads(data) != expected:
        raise ValueError("native capture inputs changed; prepare a new signed Mac payload (not a source-only update)")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    operation = parser.add_mutually_exclusive_group(required=True)
    operation.add_argument("--output", type=Path)
    operation.add_argument("--verify-inputs", type=Path, help="check production metadata against the exact source inputs")
    parser.add_argument("--headers", type=Path, help="build-only local headers, still checked against exact pins")
    parser.add_argument("--test", action="store_true", help="offline transport artifact; NEVER stage or sign as production")
    args = parser.parse_args()
    if args.verify_inputs:
        if args.test or args.headers:
            parser.error("verification accepts only --verify-inputs")
        verify_inputs(args.verify_inputs)
    else:
        build(args.output, args.headers, args.test)
