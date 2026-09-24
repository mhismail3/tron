#!/usr/bin/env python3
"""Stage a Mac wizard UserDefaults value into the owned WizardState record.

This is an operator-only bridge for the retired ``tron.mac.wizardStep`` key.
It never removes the preference and never runs during wrapper startup.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid


VERSION = 1
LEGACY_KEY = "tron.mac.wizardStep"
PROFILES = {
    "stable": ("com.tron.mac", ".tron"),
    "debug": ("com.tron.mac.dev", ".tron-dev"),
}
STEPS = {"welcome", "tailscale", "install", "permissions", "iosBeta", "pairingInfo", "done"}
MAX_RECORD_BYTES = 64 * 1024


class MigrationError(Exception):
    pass


def fail(message):
    raise MigrationError(message)


def lstat(path):
    try:
        return path.lstat()
    except FileNotFoundError:
        return None


def reject_symlinks(path, allow_missing_leaf=True):
    """Reject links in every existing component of an operator-owned path."""
    path = Path(path)
    if not path.is_absolute():
        fail(f"path must be absolute: {path}")
    current = Path(path.anchor)
    for component in path.parts[1:]:
        current /= component
        info = lstat(current)
        if info is None:
            if allow_missing_leaf:
                break
            fail(f"missing path component: {current}")
        if os.path.islink(current):
            # macOS exposes /tmp and /var as system aliases. They are outside
            # the operator-owned roots; normalize those aliases while still
            # rejecting any link at or below the supplied home/staging path.
            if current in {Path("/tmp"), Path("/var")}:
                continue
            fail(f"symlink is not an admitted migration path: {current}")


def secure_directory(path, create=False):
    path = Path(path)
    reject_symlinks(path)
    if create and lstat(path) is None:
        missing = []
        current = path
        while lstat(current) is None:
            missing.append(current)
            current = current.parent
        for directory in reversed(missing):
            directory.mkdir(mode=0o700)
            os.chmod(directory, 0o700)
    info = lstat(path)
    if info is None or not path.is_dir():
        fail(f"expected private directory: {path}")
    if info.st_uid != os.getuid() or info.st_mode & 0o077:
        fail(f"directory is not private and user-owned: {path}")


def secure_file(path, required=False, *, allow_shared_read=False):
    path = Path(path)
    reject_symlinks(path)
    info = lstat(path)
    if info is None:
        if required:
            fail(f"missing required file: {path}")
        return None
    forbidden_mode = 0o7133 if allow_shared_read else 0o077
    if not path.is_file() or info.st_uid != os.getuid() or info.st_mode & forbidden_mode:
        fail(f"file has unsafe permissions or ownership: {path}")
    if info.st_size > MAX_RECORD_BYTES:
        fail(f"file is oversized: {path}")
    return info


def record_bytes(step):
    return json.dumps({"version": VERSION, "step": step}, sort_keys=True, separators=(",", ":")).encode() + b"\n"


def canonical_operator_path(path, require_existing=False):
    path = Path(path)
    if not path.is_absolute():
        fail(f"path must be absolute: {path}")
    # Inspect the supplied spelling before resolving it. Only macOS's /tmp and
    # /var aliases are admitted; a user-owned redirect is never normalized.
    reject_symlinks(path, allow_missing_leaf=not require_existing)
    if require_existing and lstat(path) is None:
        fail(f"missing path: {path}")
    return Path(os.path.realpath(path))


def file_digest(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        while True:
            chunk = stream.read(64 * 1024)
            if not chunk:
                return digest.hexdigest()
            digest.update(chunk)


def file_identity(path):
    info = secure_file(path, required=True)
    return {"device": info.st_dev, "inode": info.st_ino, "mode": info.st_mode & 0o777}


def assert_staged_proof(staging, journal):
    staged = Path(staging) / "wizard-state.json"
    record = read_record(staged)
    if record is None:
        fail("staged WizardState record is missing")
    if journal.get("stagedDigest") != file_digest(staged):
        fail("staged WizardState digest changed")
    if journal.get("stagedIdentity") != file_identity(staged):
        fail("staged WizardState identity or mode changed")
    return record


def read_record(path):
    info = secure_file(path)
    if info is None:
        return None
    try:
        value = json.loads(Path(path).read_bytes())
    except (OSError, ValueError) as exc:
        fail(f"malformed WizardState record: {path} ({exc})")
    if not isinstance(value, dict) or set(value) != {"version", "step"}:
        fail(f"malformed WizardState record: {path}")
    if value["version"] != VERSION:
        fail(f"unknown or newer WizardState version: {value.get('version')!r}")
    if not isinstance(value["step"], str) or value["step"] not in STEPS:
        fail(f"invalid WizardState step: {value.get('step')!r}")
    return value


def run_defaults(profile, runner=None):
    domain, _ = PROFILES[profile]
    argv = ["/usr/bin/defaults", "read", domain, LEGACY_KEY]
    if runner is None:
        completed = subprocess.run(argv, capture_output=True, text=True, check=False)
        code, stdout, stderr = completed.returncode, completed.stdout, completed.stderr
    else:
        code, stdout, stderr = runner(argv)
    if code:
        raise MigrationError(f"could not read exact owned preference {domain} {LEGACY_KEY}: {stderr.strip() or code}")
    value = stdout.strip()
    if len(value) > 256 or "\n" in value:
        raise MigrationError("legacy wizard preference is malformed")
    if value.startswith('"'):
        try:
            value = json.loads(value)
        except ValueError:
            raise MigrationError("legacy wizard preference is malformed")
    if not isinstance(value, str) or value not in STEPS:
        raise MigrationError(f"legacy wizard preference has an invalid step: {value!r}")
    return value, argv


def atomic_write(path, data):
    path = Path(path)
    parent = path.parent
    secure_directory(parent, create=True)
    if lstat(path) is not None:
        fail(f"refusing to overwrite existing path: {path}")
    temporary = parent / f".{path.name}.{uuid.uuid4().hex}.tmp"
    try:
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            os.write(fd, data)
            os.fsync(fd)
        finally:
            os.close(fd)
        os.chmod(temporary, 0o600)
        os.rename(temporary, path)
        directory_fd = os.open(parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except Exception:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
        raise


def stage(profile, home, staging, runner=None):
    if profile not in PROFILES:
        fail(f"unknown profile: {profile}")
    home = canonical_operator_path(home, require_existing=True)
    staging_input = Path(staging)
    if lstat(staging_input) is not None and os.path.islink(staging_input):
        fail(f"staging path is a symlink: {staging_input}")
    staging = canonical_operator_path(staging_input.parent, require_existing=True) / staging_input.name
    secure_directory(home)
    secure_directory(staging.parent, create=False)
    if lstat(staging) is not None:
        fail(f"staging path already exists; preserve it for review: {staging}")
    staging.mkdir(mode=0o700)
    try:
        secure_directory(staging)
        domain, _ = PROFILES[profile]
        step, command_argv = run_defaults(profile, runner=runner)
        internal = home / "internal"
        mac = internal / "mac"
        secure_directory(internal, create=True)
        secure_directory(mac, create=True)
        destination = mac / "wizard-state.json"
        if lstat(destination) is not None:
            read_record(destination)  # report malformed/newer/invalid distinctly
            fail(f"WizardState destination already exists; refusing conflict: {destination}")
        marker = home / "internal" / "run" / ".onboarded"
        # The non-secret completion sentinel is written with the app umask.
        # Observe owned, non-writable-by-others bytes without chmodding evidence.
        marker_info = secure_file(marker, allow_shared_read=True)
        marker_digest = file_digest(marker) if marker_info is not None else None
        record_path = staging / "wizard-state.json"
        atomic_write(record_path, record_bytes(step))
        journal = {
            "version": VERSION,
            "profile": profile,
            "home": str(home),
            "profileHomeName": PROFILES[profile][1],
            "domain": domain,
            "legacyKey": LEGACY_KEY,
            "legacyStep": step,
            "defaultsCommand": command_argv,
            "destination": str(destination),
            "onboardedPath": str(marker),
            "onboarded": marker_info is not None,
            "onboardedDigest": marker_digest,
            "stagedDigest": file_digest(record_path),
            "stagedIdentity": file_identity(record_path),
            "phase": "staged",
        }
        atomic_write(staging / "migration.json", json.dumps(journal, sort_keys=True, separators=(",", ":")).encode() + b"\n")
        return journal | {"staging": str(staging)}
    except Exception:
        # A failed stage is deliberately retained as evidence; cleanup is a
        # separate explicit operator action and never runs implicitly.
        raise


def load_journal(staging):
    staging_input = Path(staging)
    if lstat(staging_input) is not None and os.path.islink(staging_input):
        fail(f"staging path is a symlink: {staging_input}")
    staging = canonical_operator_path(staging_input.parent, require_existing=True) / staging_input.name
    secure_directory(staging)
    journal_path = staging / "migration.json"
    secure_file(journal_path, required=True)
    try:
        raw = journal_path.read_bytes()
        if len(raw) > MAX_RECORD_BYTES:
            fail("migration journal is oversized")
        journal = json.loads(raw)
    except (OSError, ValueError) as exc:
        fail(f"invalid migration journal: {exc}")
    if not isinstance(journal, dict) or journal.get("version") != VERSION:
        fail("unknown or malformed migration journal")
    profile = journal.get("profile")
    if journal.get("phase") not in {"staged", "published"}:
        fail("migration journal is not publishable")
    if journal.get("legacyKey") != LEGACY_KEY or profile not in PROFILES:
        fail("migration journal has an unsupported source")
    domain, _ = PROFILES[profile]
    home = journal.get("home")
    if not isinstance(home, str) or canonical_operator_path(home, require_existing=True) != Path(home):
        fail("migration journal home is redirected or invalid")
    if journal.get("profileHomeName") != PROFILES[profile][1] or journal.get("domain") != domain:
        fail("migration journal profile/domain binding is invalid")
    expected_destination = Path(home) / "internal" / "mac" / "wizard-state.json"
    if journal.get("destination") != str(expected_destination):
        fail("migration journal destination is redirected")
    expected_marker = Path(home) / "internal" / "run" / ".onboarded"
    if journal.get("onboardedPath") != str(expected_marker):
        fail("migration journal completion path is redirected")
    if not isinstance(journal.get("stagedDigest"), str) or not isinstance(journal.get("stagedIdentity"), dict):
        fail("migration journal lacks staged identity proof")
    return journal | {"staging": str(staging)}


def verify(staging):
    journal = load_journal(staging)
    staging = Path(journal["staging"])
    record = assert_staged_proof(staging, journal)
    if record["step"] != journal.get("legacyStep"):
        fail("staged WizardState does not match retained legacy evidence")
    destination = Path(journal["destination"])
    reject_symlinks(destination)
    existing = read_record(destination)
    if existing is not None and journal["phase"] != "published":
        fail(f"WizardState destination appeared after staging; use recover only after proving publication: {destination}")
    if journal["phase"] == "published":
        if (existing != record
                or file_digest(destination) != journal.get("publishedDigest")
                or file_identity(destination) != journal.get("publishedIdentity")):
            fail("published WizardState differs from retained staged record")
    return journal | {"staging": str(staging), "verified": True}


def recheck_source(journal, runner=None):
    step, command_argv = run_defaults(journal["profile"], runner=runner)
    if step != journal["legacyStep"] or command_argv != journal["defaultsCommand"]:
        fail("legacy wizard preference changed since staging; refuse publication")


def write_publication_temp(source, destination, temp):
    if lstat(temp) is not None:
        fail(f"publication temporary path already exists: {temp}")
    source_info = secure_file(source, required=True)
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with source.open("rb") as input_stream:
            while True:
                chunk = input_stream.read(64 * 1024)
                if not chunk:
                    break
                os.write(fd, chunk)
        os.fsync(fd)
    finally:
        os.close(fd)
    os.chmod(temp, 0o600)
    if file_digest(temp) != file_digest(source) or (lstat(temp).st_size != source_info.st_size):
        fail("publication temporary digest differs from staged record")


def mark_published(staging, journal, destination):
    journal = dict(journal)
    journal["phase"] = "published"
    journal["publishedDigest"] = file_digest(destination)
    journal["publishedIdentity"] = file_identity(destination)
    journal.pop("publicationTemp", None)
    atomic_replace(Path(staging) / "migration.json", json.dumps(journal, sort_keys=True, separators=(",", ":")).encode() + b"\n")
    return journal | {"staging": str(staging), "published": True}


def publish(staging, runner=None):
    journal = verify(staging)
    if journal["phase"] == "published":
        return journal
    recheck_source(journal, runner=runner)
    staging = Path(journal["staging"])
    destination = Path(journal["destination"])
    secure_directory(destination.parent)
    if lstat(destination) is not None:
        fail(f"WizardState destination collision; run recover only after proving publication: {destination}")
    source = staging / "wizard-state.json"
    temp = destination.parent / f".wizard-state-publish-{uuid.uuid4().hex}.tmp"
    journal["publicationTemp"] = str(temp)
    atomic_replace(staging / "migration.json", json.dumps(journal, sort_keys=True, separators=(",", ":")).encode() + b"\n")
    try:
        write_publication_temp(source, destination, temp)
        # link(2) gives atomic no-clobber publication; unlinking the temporary
        # source leaves a distinct destination inode, so staging remains
        # immutable rollback evidence.
        os.link(temp, destination)
        directory_fd = os.open(destination.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
        temp.unlink()
        directory_fd = os.open(destination.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except FileExistsError:
        fail(f"WizardState destination collision; no write made: {destination}")
    except OSError as exc:
        fail(f"could not publish durable WizardState record: {exc}")
    return mark_published(staging, journal, destination)


def recover(staging, runner=None):
    journal = load_journal(staging)
    if journal["phase"] == "published":
        return verify(staging)
    recheck_source(journal, runner=runner)
    staging = Path(journal["staging"])
    record = assert_staged_proof(staging, journal)
    destination = Path(journal["destination"])
    existing = read_record(destination)
    if existing is None or existing != record or file_digest(destination) != journal["stagedDigest"]:
        fail("publication is not provably complete; preserve staging and destination for review")
    temp_name = journal.get("publicationTemp")
    if temp_name:
        temp = Path(temp_name)
        if temp != destination.parent / temp.name:
            fail("publication temporary path is unsafe or changed")
        reject_symlinks(temp)
        if lstat(temp) is not None:
            secure_file(temp, required=True)
            if file_digest(temp) != journal["stagedDigest"]:
                fail("publication temporary path is unsafe or changed")
            temp.unlink()
    return mark_published(staging, journal, destination)


def atomic_replace(path, data):
    path = Path(path)
    temporary = path.parent / f".{path.name}.{uuid.uuid4().hex}.tmp"
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        os.write(fd, data)
        os.fsync(fd)
    finally:
        os.close(fd)
    os.replace(temporary, path)
    os.chmod(path, 0o600)
    directory_fd = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)


def cleanup(staging):
    journal = load_journal(staging)
    if journal["phase"] == "published":
        fail("published staging is rollback evidence and cannot be cleaned by this command")
    # Refuse recursive deletion if an unexpected entry was added.
    entries = {path.name for path in Path(staging).iterdir()}
    if entries != {"migration.json", "wizard-state.json"}:
        fail("staging contains unexpected entries; preserve it for review")
    for name in entries:
        (Path(staging) / name).unlink()
    Path(staging).rmdir()
    return {"staging": str(staging), "cleaned": True}


def parser():
    result = argparse.ArgumentParser(prog="wizard-migrate")
    sub = result.add_subparsers(dest="operation", required=True)
    stage_parser = sub.add_parser("stage")
    stage_parser.add_argument("--profile", choices=sorted(PROFILES), required=True)
    stage_parser.add_argument("--home", required=True, help="explicit Tron home for this profile")
    stage_parser.add_argument("--staging", required=True)
    for name in ("verify", "publish", "recover", "cleanup"):
        command = sub.add_parser(name)
        command.add_argument("--staging", required=True)
    return result


def main(argv=None):
    args = parser().parse_args(argv)
    try:
        if args.operation == "stage":
            result = stage(args.profile, args.home, args.staging)
        elif args.operation == "verify":
            result = verify(args.staging)
        elif args.operation == "publish":
            result = publish(args.staging)
        elif args.operation == "recover":
            result = recover(args.staging)
        else:
            result = cleanup(args.staging)
    except MigrationError as exc:
        print(f"wizard-migrate: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
