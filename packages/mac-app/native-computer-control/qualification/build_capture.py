#!/usr/bin/env python3
"""Freeze, build and sign a closed native qualification product; never launch it."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import stat
import subprocess

ROOT = Path(__file__).resolve().parent.parent
MAC = ROOT.parent
REPO = MAC.parent.parent
PRODUCT = {"executable": "TronNativeCaptureQualification",
           "bundleIdentifier": "com.tron.qualification.native-capture",
           "displayName": "Tron Native Capture Qualification", "minimumSystem": "15.2",
           "schema": "tron.native-capture-qualification.artifact.v1"}


def arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True)
    parser.add_argument("--identity", help="Existing Apple Development certificate SHA-1")
    return parser.parse_args(argv)


def build_command(package, scratch):
    return ["xcrun", "swift", "build", "--package-path", package, "--scratch-path", scratch,
            "--configuration", "release", "--product", PRODUCT["executable"]]


def signing_policy(identity, inventory, team):
    if not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise ValueError("Invalid canonical signing team")
    identities = re.findall(r'\b([0-9A-F]{40}) "Apple Development:[^"\n]+"', inventory)
    if identity is None:
        if len(identities) != 1:
            raise ValueError("Select one existing Apple Development certificate using --identity SHA1")
        identity = identities[0]
    if identity not in identities:
        raise ValueError("Signing identity must be a listed Apple Development certificate SHA1; ad-hoc signing is forbidden")
    return identity


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_inventory(root):
    """Only actual package inputs; generated/cache trees never enter the build."""
    entries = {}
    for item in [root / "Package.swift", root / "Sources", root / "Tests", root / "qualification"]:
        if not item.exists() and not item.is_symlink():
            continue
        paths = [item] + (sorted(item.rglob("*")) if item.is_dir() and not item.is_symlink() else [])
        for path in paths:
            if "__pycache__" in path.parts or path.suffix == ".pyc":
                continue
            if path.is_symlink():
                raise ValueError("Source symlinks are not admitted: " + str(path))
            info = path.stat()
            if stat.S_ISDIR(info.st_mode):
                continue
            if not stat.S_ISREG(info.st_mode):
                raise ValueError("Non-regular package input")
            entries[str(path.relative_to(root))] = {"sha256": digest(path), "mode": stat.S_IMODE(info.st_mode)}
    if "Package.swift" not in entries:
        raise ValueError("Missing package manifest")
    return entries


def freeze_sources(root, destination):
    before = source_inventory(root)
    destination.mkdir(mode=0o700)
    for name in before:
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / name, target)
    if before != source_inventory(root) or before != source_inventory(destination):
        raise ValueError("Package inputs changed while freezing")
    return before


def output_path(value, repository=REPO):
    supplied = Path(value)
    if not supplied.is_absolute():
        raise ValueError("Output must be absolute")
    resolved = supplied.resolve()
    if supplied.exists() or supplied.is_symlink():
        raise ValueError("Refusing to replace existing output")
    for home_name in [".tron", ".tron-dev", ".pi"]:
        home = (Path.home() / home_name).resolve()
        if home == resolved or home in resolved.parents:
            files = home / "workspace/files"
            if home_name == ".pi" or files not in resolved.parents:
                raise ValueError("Output cannot enter runtime/settings/capability stores")
    for protected in [Path("/Applications"), Path("/System"), Path("/Library"), repository.resolve()]:
        if resolved == protected or protected in resolved.parents:
            raise ValueError("Output must be outside installation/system/source trees")
    return resolved


def run(arguments, log, timeout=60):
    """Own only this build command's process group, with finite execution."""
    with log.open("wb") as output:
        process = subprocess.Popen([str(a) for a in arguments], stdout=output, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        try:
            code = process.wait(timeout=timeout)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=5)
    if code:
        raise RuntimeError("Command failed; retained log: " + str(log))
    return log.read_text()


def main():
    args = arguments()
    product = PRODUCT
    output = output_path(args.output)
    output.mkdir(mode=0o700)  # Parent must already exist; never create installation trees.
    frozen = output / "source"
    sources = freeze_sources(ROOT, frozen)
    context = output / "source-context"
    context.mkdir()
    # The capture builder owns its signing policy; project.yml owns the team.
    inputs = [MAC / "project.yml"]
    context_hashes = {}
    for path in inputs:
        expected = digest(path)
        target = context / path.name
        shutil.copy2(path, target)
        if digest(target) != expected or digest(path) != expected:
            raise ValueError("Build context changed while freezing")
        context_hashes[path.name] = expected
    teams = re.findall(r"^    DEVELOPMENT_TEAM: ([A-Z0-9]{10})$", (context / "project.yml").read_text(), re.M)
    if len(teams) != 1:
        raise ValueError("Expected one canonical Mac development team")
    inventory = run(["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"], output / "identity.log")
    identity = signing_policy(args.identity, inventory, teams[0])
    toolchain = run(["xcrun", "swift", "--version"], output / "toolchain.log")
    xcode = run(["xcodebuild", "-version"], output / "xcode.log")
    scratch = output / "scratch"
    command = build_command(frozen, scratch)
    run(command, output / "build.log", timeout=300)
    bin_path = run(["xcrun", "swift", "build", "--package-path", frozen, "--scratch-path", scratch,
                    "--configuration", "release", "--show-bin-path"], output / "bin-path.log").strip()
    if sources != source_inventory(frozen):
        raise ValueError("Frozen package changed during compilation")
    app = output / (product["executable"] + ".app")
    executable = app / "Contents/MacOS" / product["executable"]
    executable.parent.mkdir(parents=True)
    shutil.copy2(Path(bin_path) / executable.name, executable)
    executable.chmod(0o755)
    plist = {"CFBundleDisplayName": product["displayName"], "CFBundleExecutable": executable.name,
             "CFBundleIdentifier": product["bundleIdentifier"], "CFBundleName": executable.name, "CFBundlePackageType": "APPL",
             "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1", "LSMinimumSystemVersion": product["minimumSystem"],
             "LSUIElement": True, "NSPrincipalClass": "NSApplication"}
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(plist, sort_keys=True))
    run(["/usr/bin/codesign", "--sign", identity, "--options", "runtime", "--timestamp=none", app], output / "sign.log")
    requirement = f'identifier "{product["bundleIdentifier"]}" and anchor apple generic and certificate leaf[subject.OU] = "{teams[0]}"'
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", "-R", "=" + requirement, app], output / "verify.log")
    signature = run(["/usr/bin/codesign", "-d", "-r-", "--verbose=4", app], output / "signature.log")
    if "(runtime)" not in signature or "Signature=adhoc" in signature or f"TeamIdentifier={teams[0]}" not in signature:
        raise ValueError("Unexpected signing identity/runtime flags")
    certificates = output / "certificate"
    run(["/usr/bin/codesign", "-d", "--extract-certificates=" + str(certificates), app], output / "certificate.log")
    if hashlib.sha1(Path(str(certificates) + "0").read_bytes()).hexdigest().upper() != identity.upper():
        raise ValueError("Signed leaf certificate does not match selected identity")
    if sources != source_inventory(frozen) or any(digest(context / name) != value for name, value in context_hashes.items()):
        raise ValueError("Frozen build inputs changed before attestation")
    if any(p.is_symlink() for p in app.rglob("*")):
        raise ValueError("Unexpected link in signed artifact")
    app_files = {str(p.relative_to(app)): digest(p) for p in sorted(app.rglob("*")) if p.is_file()}
    manifest = {"schema": product["schema"], "bundleIdentifier": product["bundleIdentifier"], "product": "capture",
                "sources": sources, "context": context_hashes, "toolchain": toolchain, "xcode": xcode,
                "buildCommand": [str(a) for a in command], "appFiles": app_files,
                "signingCertificateSHA1": identity, "teamIdentifier": teams[0], "designatedRequirement": requirement,
                "codesign": signature, "qualificationExecuted": False}
    manifest_path = output / "artifact-manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"app": str(app), "manifest": str(manifest_path)}))


if __name__ == "__main__":
    def interrupted(number, _frame):
        raise SystemExit(128 + number)
    signal.signal(signal.SIGINT, interrupted)
    signal.signal(signal.SIGTERM, interrupted)
    main()
