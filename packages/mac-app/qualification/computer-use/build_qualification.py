#!/usr/bin/env python3
"""Build a new qualification artifact; never install, replace, or grant consent."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import stat
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
BUNDLE_ID = "com.tron.qualification.computer-use"


def run(args, cwd=None, env=None, timeout=60):
    # Only this command's newly owned process group is retired on timeout. No
    # Gateway, user application or pre-existing PID is a cleanup candidate.
    process = subprocess.Popen([str(a) for a in args], cwd=cwd, env=env,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=True)
    try:
        out, err = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
        raise RuntimeError(f"Timed out: {args[0]}")
    if process.returncode:
        raise RuntimeError(f"Command failed ({process.returncode}): {args}\n{out.decode(errors='replace')}\n{err.decode(errors='replace')}")
    return out.decode(), err.decode()


def git(root, *args):
    return run(["git", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-C", root, *args])[0].strip()


def sha(data):
    return hashlib.sha256(data).hexdigest()


def verify_checkout(root, revision, repository=None):
    """Compare actual bytes/modes to Git objects, including assume-unchanged files."""
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("Expected an exact Git revision")
    root = Path(root).resolve(strict=True)
    if git(root, "rev-parse", "HEAD") != revision:
        raise ValueError(f"Wrong revision: {root}")
    origin = git(root, "remote", "get-url", "origin")
    if repository is not None and origin != repository:
        raise ValueError(f"Wrong source repository: {root}")
    if git(root, "status", "--porcelain", "--untracked-files=all", "--ignored", "--ignore-submodules=none"):
        raise ValueError(f"Source checkout is not clean: {root}")
    listing = run(["git", "-C", root, "ls-tree", "-r", "-z", "--full-tree", "HEAD"])[0]
    blobs = {}
    links = {}
    for row in listing.split("\0"):
        if not row:
            continue
        metadata, name = row.split("\t", 1)
        mode, kind, oid = metadata.split()
        path = root / name
        if kind == "commit":
            links[name] = oid
            continue
        if mode == "120000":
            if not path.is_symlink() or not path.resolve().is_relative_to(root):
                raise ValueError(f"Unsafe source link: {path}")
            data = os.readlink(path).encode()
        else:
            info = path.lstat()
            if not stat.S_ISREG(info.st_mode):
                raise ValueError(f"Source is not a regular file: {path}")
            expected_executable = mode == "100755"
            if bool(info.st_mode & stat.S_IXUSR) != expected_executable:
                raise ValueError(f"Source executable mode changed: {path}")
            data = path.read_bytes()
        actual = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
        if actual != oid:
            raise ValueError(f"Source bytes differ from pinned object: {path}")
        blobs[name] = {"mode": mode, "sha256": sha(data)}
    return {"revision": revision, "tree": git(root, "rev-parse", "HEAD^{tree}"),
            "origin": origin, "files": blobs, "gitlinks": links}


def check_licenses(root, entry):
    expected = entry["licenseSha256"]
    expected = expected if isinstance(expected, list) else [expected]
    actual = [sha((root / name).read_bytes()) for name in entry["licenseFiles"]]
    if actual != expected:
        raise ValueError(f"License content drift: {root}")


def verify_declared_patch(source, candidate, patch_root=ROOT):
    declared = patch_root / candidate["patchFile"]
    path = declared.resolve(strict=True)
    if not path.is_relative_to(patch_root.resolve()) or declared.is_symlink():
        raise ValueError("Native patch escaped its declared source root")
    expected = candidate["patchSHA256"]
    if sha(path.read_bytes()) != expected:
        raise ValueError("Native patch bytes changed")
    base, revision = candidate["upstreamRevision"], candidate["revision"]
    if not all(re.fullmatch(r"[0-9a-f]{40}", value) for value in [base, revision]):
        raise ValueError("Native patch requires exact revisions")
    run(["git", "-C", source, "merge-base", "--is-ancestor", base, revision])
    delta = run(["git", "-C", source, "diff", "--binary", base, revision])[0].encode()
    if sha(delta) != expected:
        raise ValueError("Native candidate does not match the declared downstream patch")


def candidate_snapshot(source, graph):
    candidate = graph["candidate"]
    result = {"root": verify_checkout(source, candidate["revision"], candidate["repository"])}
    verify_declared_patch(source, candidate)
    check_licenses(source, candidate)
    expected_links = {entry["name"]: entry["revision"] for entry in graph["submodules"]}
    if result["root"]["gitlinks"] != expected_links:
        raise ValueError("Pinned root gitlinks do not match the declared submodule closure")
    for entry in graph["submodules"]:
        path = source / entry["name"]
        result[entry["name"]] = verify_checkout(path, entry["revision"], entry["repository"])
        check_licenses(path, entry)
    return result


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


def artifact_files(app):
    result = {}
    for path in sorted(app.rglob("*")):
        if path.is_symlink():
            raise ValueError("Unexpected link in qualification app")
        if path.is_file():
            result[str(path.relative_to(app))] = sha(path.read_bytes())
    return result


def qualification_snapshot():
    return {str(p.relative_to(ROOT)): sha(p.read_bytes()) for p in ROOT.rglob("*")
            if p.is_file() and not any(part in {".build", "__pycache__"} for part in p.relative_to(ROOT).parts)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True, help="Exact pinned Peekaboo checkout")
    parser.add_argument("--output", type=Path, required=True, help="New, nonexistent artifact directory")
    parser.add_argument("--identity", help="Existing Apple Development certificate SHA1 (never '-')")
    parser.add_argument("--preflight", action="store_true", help="Launch only this new app via LaunchServices for non-prompting permission checks")
    args = parser.parse_args()
    source = args.source.resolve(strict=True)
    output = args.output.absolute()
    if output.exists() or output.is_symlink():
        raise ValueError("Output must not exist; previous artifacts are never replaced")
    # The source project is the signing-policy authority, not a caller-supplied team.
    project = (ROOT.parents[1] / "project.yml").read_text()
    teams = re.findall(r"^    DEVELOPMENT_TEAM: ([A-Z0-9]{10})$", project, re.M)
    if len(teams) != 1:
        raise ValueError("Expected one canonical Mac signing team")
    team = teams[0]
    inventory = run(["security", "find-identity", "-v", "-p", "codesigning"])[0]
    identity = signing_policy(args.identity, inventory, team)
    unit_out, unit_err = run([sys.executable, "-m", "unittest", "-v", "test_build_qualification.py"], cwd=ROOT)
    graph = json.loads((ROOT / "dependency-graph.json").read_text())
    before = candidate_snapshot(source, graph)
    own_sources = qualification_snapshot()
    output.mkdir(parents=True, mode=0o700)
    (output / "build-policy-tests.log").write_text(unit_out + unit_err)
    env = dict(os.environ, TRON_PEEKABOO_SOURCE=str(source))
    resolved = (ROOT / "Package.resolved").read_bytes()
    # Resolution may fetch only the already frozen versions. No floating update.
    run(["swift", "package", "--package-path", ROOT, "resolve", "--force-resolved-versions"], env=env, timeout=300)
    if (ROOT / "Package.resolved").read_bytes() != resolved:
        raise ValueError("SwiftPM changed the frozen resolution")
    state = json.loads((ROOT / ".build/workspace-state.json").read_text())
    remote_before = {}
    pins = {entry["state"]["revision"]: entry for entry in json.loads(resolved)["pins"]}
    license_pins = {entry["revision"]: entry for entry in graph["swiftPackagePins"]}
    for entry in state["object"]["dependencies"]:
        if entry["state"]["name"] != "sourceControlCheckout":
            continue
        revision = entry["state"]["checkoutState"]["revision"]
        pin = pins[revision]
        if entry["packageRef"]["location"] != pin["location"]:
            raise ValueError("Resolved dependency location drift")
        path = ROOT / ".build/checkouts" / entry["subpath"]
        remote_before[entry["subpath"]] = verify_checkout(path, revision)
        check_licenses(path, license_pins[revision])
    if len(remote_before) != len(pins):
        raise ValueError("Resolved dependency closure is incomplete")
    tests, test_errors = run(["swift", "test", "--package-path", ROOT, "--force-resolved-versions", "--jobs", "4"], env=env, timeout=900)
    (output / "swift-test.log").write_text(tests + test_errors)
    build, build_errors = run(["swift", "build", "--package-path", ROOT, "--force-resolved-versions", "--jobs", "4", "-c", "release", "--product", "TronComputerUseQualification"], env=env, timeout=900)
    (output / "swift-build.log").write_text(build + build_errors)
    if before != candidate_snapshot(source, graph):
        raise ValueError("Candidate changed during build")
    for subpath, evidence in remote_before.items():
        if evidence != verify_checkout(ROOT / ".build/checkouts" / subpath, evidence["revision"]):
            raise ValueError("Resolved dependency changed during build")
    if (ROOT / "Package.resolved").read_bytes() != resolved:
        raise ValueError("Resolution changed during build")
    binary_dir = Path(run(["swift", "build", "--package-path", ROOT, "-c", "release", "--show-bin-path"], env=env)[0].strip())
    app = output / "TronComputerUseQualification.app"
    executable = app / "Contents/MacOS/TronComputerUseQualification"
    executable.parent.mkdir(parents=True)
    executable.write_bytes((binary_dir / executable.name).read_bytes())
    executable.chmod(0o755)
    plist = {"CFBundleDisplayName": "Tron Computer Use Qualification", "CFBundleExecutable": executable.name,
             "CFBundleIdentifier": BUNDLE_ID, "CFBundleName": executable.name, "CFBundlePackageType": "APPL",
             "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1", "LSMinimumSystemVersion": "15.0",
             "LSUIElement": True, "NSPrincipalClass": "NSApplication"}
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(plist))
    run(["codesign", "--sign", identity, "--options", "runtime", "--timestamp=none", app])
    requirement = f'identifier "{BUNDLE_ID}" and anchor apple generic and certificate leaf[subject.OU] = "{team}"'
    run(["codesign", "--verify", "--strict", "-R", "=" + requirement, app])
    _, signature = run(["codesign", "-d", "-r-", "--verbose=4", app])
    if f"TeamIdentifier={team}\n" not in signature or "(runtime)" not in signature or "Signature=adhoc" in signature:
        raise ValueError("Signed artifact does not match the required hardened team identity")
    files = artifact_files(app)
    preflight = None
    if args.preflight:
        # A fresh GUI launch is separate from invoking a Gateway-child binary;
        # no permission-attribution inheritance is assumed from either route.
        run(["/usr/bin/open", "-n", "-g", "-W", "--stdout", output / "preflight.json",
             "--stderr", output / "preflight.err", app, "--args", "--preflight"], timeout=30)
        preflight = json.loads((output / "preflight.json").read_text())
        if preflight["bundleIdentifier"] != BUNDLE_ID or preflight["executablePath"] != str(executable):
            raise ValueError("Preflight did not come from the exact built app")
        if preflight["nativeActions"] != "available-but-not-attempted" or preflight["capture"] != "not-attempted":
            raise ValueError("Unexpected native activity in preflight")
        if files != artifact_files(app):
            raise ValueError("App changed during preflight")
    if own_sources != qualification_snapshot() or project != (ROOT.parents[1] / "project.yml").read_text():
        raise ValueError("Qualification source or signing policy changed during build")
    source_manifest = {"candidate": before, "remotePackages": remote_before, "qualification": own_sources,
                       "macProjectSHA256": sha(project.encode())}
    (output / "source-manifest.json").write_text(json.dumps(source_manifest, sort_keys=True, indent=2) + "\n")
    (output / "codesign.txt").write_text(signature)
    receipt = {"schema": "tron.computer-use.g0-build.v1", "app": str(app), "bundleIdentifier": BUNDLE_ID,
               "signingCertificateSHA1": identity, "expectedTeam": team, "requiredSignature": requirement,
               "executableSHA256": files["Contents/MacOS/TronComputerUseQualification"], "appFiles": files,
               "appTreeSHA256": sha(json.dumps(files, sort_keys=True).encode()),
               "sourceManifestSHA256": sha((output / "source-manifest.json").read_bytes()),
               "preflight": preflight, "nativeAutomationQualified": False, "stopQualified": False}
    (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps({"app": str(app), "receipt": str(output / "receipt.json"), "preflight": preflight}, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, OSError, KeyError) as error:
        print(f"Qualification build refused: {error}", file=sys.stderr)
        sys.exit(1)
