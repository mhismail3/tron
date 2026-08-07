#!/usr/bin/env python3
"""Persist and recover iOS release credential cleanup ownership.

The release workflow creates signing keychains and may install provisioning
profiles in the long-lived release user's home. A process kill can bypass an
``if: always()`` cleanup step, so this helper records cleanup ownership before
each mutation and can replay that cleanup at the start of a later job.

The ledger never contains passwords, certificate material, API keys, profile
contents, or other secrets. Paths are not trusted merely because they were
persisted: every operation derives the only allowed paths again from the
release home and the canonical run/attempt or profile UUID.

Runtime commands:

``begin``
    Create the current attempt ledger before creating its signing keychain.
``plan-profile``
    Atomically add a profile UUID before installing that profile.
``recover``
    Restore the known baseline keychain preferences and remove all validated
    stale attempt-owned targets and strictly named orphan signing keychains.
``complete``
    Remove the current ledger only after every recorded target is absent.
``audit``
    Fail if any attempt ledger, atomic-write remnant, or job-owned keychain is
    present.
``self-test``
    Exercise the persistence and recovery contract without macOS Security.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import uuid
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterator, Protocol, Sequence


SCHEMA = "tron.ios-release-credential-attempt.v1"
STATE_DIRECTORY_NAME = ".tron-ios-release-state"
LOCK_NAME = ".credential-ledger.lock"
BASELINE_KEYCHAIN_NAME = "tron-runner-baseline.keychain-db"
MAX_LEDGER_BYTES = 64 * 1024
MAX_PROFILES_PER_ATTEMPT = 16

IDENTIFIER_PATTERN = re.compile(r"^[1-9][0-9]{0,19}$")
UUID_PATTERN = re.compile(
    r"^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$"
)
LEDGER_NAME_PATTERN = re.compile(
    r"^attempt-([1-9][0-9]{0,19})-([1-9][0-9]{0,19})\.json$"
)
TEMP_NAME_PATTERN = re.compile(
    r"^\.(attempt-[1-9][0-9]{0,19}-[1-9][0-9]{0,19}\.json)"
    r"\.tmp-[0-9a-f]{32}$"
)
KEYCHAIN_NAME_PATTERN = re.compile(
    r"^tron-ios-signing-([1-9][0-9]{0,19})-([1-9][0-9]{0,19})\.keychain-db$"
)


class LedgerError(RuntimeError):
    """A fail-closed ledger, path, permission, or cleanup error."""


class CommandRunner(Protocol):
    """Narrow command boundary used only for macOS keychain preferences."""

    def run(self, arguments: Sequence[str], purpose: str) -> bool:
        """Return whether an exact argv command completed successfully."""


class SubprocessCommandRunner:
    """Production command runner; command output is intentionally discarded."""

    def run(self, arguments: Sequence[str], purpose: str) -> bool:
        del purpose
        try:
            completed = subprocess.run(
                list(arguments),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
        except OSError:
            return False
        return completed.returncode == 0


@dataclass(frozen=True)
class LoadedLedger:
    """A validated canonical ledger and its exact producer bytes."""

    path: Path
    document: dict[str, Any]
    contents: bytes

    @property
    def run_id(self) -> str:
        return self.document["run"]["id"]

    @property
    def run_attempt(self) -> str:
        return self.document["run"]["attempt"]

    @property
    def keychain_path(self) -> Path:
        return Path(self.document["keychain"]["path"])

    @property
    def profile_paths(self) -> tuple[Path, ...]:
        return tuple(Path(item["path"]) for item in self.document["profiles"])


def canonical_json_bytes(document: dict[str, Any]) -> bytes:
    return (json.dumps(document, indent=2, sort_keys=True) + "\n").encode("utf-8")


def strict_json_document(contents: bytes, owner: str) -> dict[str, Any]:
    def reject_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise LedgerError(f"{owner} contains duplicate JSON key {key!r}")
            result[key] = value
        return result

    try:
        value = json.loads(contents.decode("utf-8"), object_pairs_hook=reject_duplicates)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise LedgerError(f"{owner} is not strict UTF-8 JSON") from error
    if not isinstance(value, dict):
        raise LedgerError(f"{owner} must be a JSON object")
    if contents != canonical_json_bytes(value):
        raise LedgerError(f"{owner} is not canonical producer JSON")
    return value


def exact_keys(value: dict[str, Any], expected: set[str], owner: str) -> None:
    actual = set(value)
    if actual != expected:
        raise LedgerError(
            f"{owner} keys differ (missing={sorted(expected - actual)}, "
            f"extra={sorted(actual - expected)})"
        )


def positive_identifier(value: str, owner: str) -> str:
    if not isinstance(value, str) or not IDENTIFIER_PATTERN.fullmatch(value):
        raise LedgerError(f"{owner} must be a canonical positive integer identifier")
    return value


def canonical_profile_uuid(value: str) -> str:
    if not isinstance(value, str) or not UUID_PATTERN.fullmatch(value):
        raise LedgerError("profile UUID must use canonical uppercase UUID syntax")
    return value


def mode_bits(metadata: os.stat_result) -> int:
    return stat.S_IMODE(metadata.st_mode)


class CredentialLedgerStore:
    """Own strict attempt ledgers and replay their bounded cleanup effects."""

    def __init__(self, home: Path, runner: CommandRunner):
        raw_home = os.fspath(home)
        if not os.path.isabs(raw_home) or os.path.normpath(raw_home) != raw_home:
            raise LedgerError("release home must be an absolute normalized path")
        self.home = Path(raw_home)
        self.runner = runner
        self.state_dir = self.home / STATE_DIRECTORY_NAME
        self.lock_path = self.state_dir / LOCK_NAME
        self.keychains_dir = self.home / "Library" / "Keychains"
        self.profiles_dir = (
            self.home
            / "Library"
            / "Developer"
            / "Xcode"
            / "UserData"
            / "Provisioning Profiles"
        )
        self.baseline_keychain = self.keychains_dir / BASELINE_KEYCHAIN_NAME
        self._validate_directory(self.home, "release home")

    @classmethod
    def production(cls) -> "CredentialLedgerStore":
        return cls(Path.home(), SubprocessCommandRunner())

    def ledger_name(self, run_id: str, run_attempt: str) -> str:
        positive_identifier(run_id, "run id")
        positive_identifier(run_attempt, "run attempt")
        return f"attempt-{run_id}-{run_attempt}.json"

    def ledger_path(self, run_id: str, run_attempt: str) -> Path:
        return self.state_dir / self.ledger_name(run_id, run_attempt)

    def job_keychain_path(self, run_id: str, run_attempt: str) -> Path:
        positive_identifier(run_id, "run id")
        positive_identifier(run_attempt, "run attempt")
        return self.keychains_dir / (
            f"tron-ios-signing-{run_id}-{run_attempt}.keychain-db"
        )

    def profile_path(self, profile_uuid: str) -> Path:
        canonical_profile_uuid(profile_uuid)
        return self.profiles_dir / f"{profile_uuid}.mobileprovision"

    def _validate_directory(
        self, path: Path, owner: str, *, exact_mode: int | None = None
    ) -> os.stat_result:
        try:
            metadata = os.lstat(path)
        except FileNotFoundError as error:
            raise LedgerError(f"{owner} is missing") from error
        if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
            raise LedgerError(f"{owner} must be a real directory")
        if metadata.st_uid != os.geteuid():
            raise LedgerError(f"{owner} has the wrong owner")
        if exact_mode is not None and mode_bits(metadata) != exact_mode:
            raise LedgerError(f"{owner} must have mode {exact_mode:04o}")
        return metadata

    def _validate_descendant_directory(self, path: Path, owner: str) -> None:
        try:
            relative = path.relative_to(self.home)
        except ValueError as error:
            raise LedgerError(f"{owner} escaped the release home") from error
        cursor = self.home
        self._validate_directory(cursor, "release home")
        for component in relative.parts:
            if component in {"", ".", ".."}:
                raise LedgerError(f"{owner} contains an unsafe path component")
            cursor = cursor / component
            self._validate_directory(cursor, owner)

    def _validate_optional_descendant_directory(
        self, path: Path, owner: str
    ) -> bool:
        """Validate an existing descendant chain, or prove it becomes absent.

        Recovery must work before the first provisioning-profile directory is
        created and after a prior cleanup removed an empty directory. A missing
        component proves every target below it is absent; any component that
        does exist must still be an owned, non-symlink directory.
        """

        try:
            relative = path.relative_to(self.home)
        except ValueError as error:
            raise LedgerError(f"{owner} escaped the release home") from error
        cursor = self.home
        self._validate_directory(cursor, "release home")
        for component in relative.parts:
            if component in {"", ".", ".."}:
                raise LedgerError(f"{owner} contains an unsafe path component")
            cursor = cursor / component
            try:
                os.lstat(cursor)
            except FileNotFoundError:
                return False
            self._validate_directory(cursor, owner)
        return True

    def _ensure_descendant_directory(self, path: Path, owner: str) -> None:
        """Create an owned descendant one component at a time without following links."""

        try:
            relative = path.relative_to(self.home)
        except ValueError as error:
            raise LedgerError(f"{owner} escaped the release home") from error
        cursor = self.home
        self._validate_directory(cursor, "release home")
        for component in relative.parts:
            if component in {"", ".", ".."}:
                raise LedgerError(f"{owner} contains an unsafe path component")
            parent = cursor
            cursor = parent / component
            try:
                os.mkdir(cursor, 0o700)
            except FileExistsError:
                pass
            except OSError as error:
                raise LedgerError(f"could not create {owner}") from error
            else:
                self._fsync_directory(parent)
            self._validate_directory(cursor, owner)

    def _ensure_state_directory(self) -> None:
        created = False
        try:
            os.mkdir(self.state_dir, 0o700)
            created = True
        except FileExistsError:
            pass
        except OSError as error:
            raise LedgerError("could not create release credential state directory") from error
        self._validate_directory(
            self.state_dir, "release credential state directory", exact_mode=0o700
        )
        if created:
            self._fsync_directory(self.home)

    def _validate_regular_file(
        self,
        path: Path,
        owner: str,
        *,
        exact_mode: int | None = None,
    ) -> os.stat_result:
        try:
            metadata = os.lstat(path)
        except FileNotFoundError as error:
            raise LedgerError(f"{owner} is missing") from error
        if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
            raise LedgerError(f"{owner} must be a real regular file")
        if metadata.st_uid != os.geteuid():
            raise LedgerError(f"{owner} has the wrong owner")
        if metadata.st_nlink != 1:
            raise LedgerError(f"{owner} must not have multiple hard links")
        if exact_mode is not None and mode_bits(metadata) != exact_mode:
            raise LedgerError(f"{owner} must have mode {exact_mode:04o}")
        return metadata

    def _validate_baseline(self) -> None:
        self._validate_descendant_directory(self.keychains_dir, "keychains directory")
        self._validate_regular_file(
            self.baseline_keychain, "baseline keychain", exact_mode=0o600
        )

    @contextmanager
    def _locked(self) -> Iterator[None]:
        self._ensure_state_directory()
        flags = os.O_RDWR | os.O_CREAT
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        try:
            descriptor = os.open(self.lock_path, flags, 0o600)
        except OSError as error:
            raise LedgerError("could not open the credential-ledger lock") from error
        try:
            os.fchmod(descriptor, 0o600)
            metadata = os.fstat(descriptor)
            if (
                not stat.S_ISREG(metadata.st_mode)
                or metadata.st_uid != os.geteuid()
                or metadata.st_nlink != 1
                or mode_bits(metadata) != 0o600
            ):
                raise LedgerError("credential-ledger lock is not a private regular file")
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            yield
        finally:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_UN)
            finally:
                os.close(descriptor)

    def _expected_document(
        self, run_id: str, run_attempt: str, profile_uuids: Sequence[str]
    ) -> dict[str, Any]:
        run_id = positive_identifier(run_id, "run id")
        run_attempt = positive_identifier(run_attempt, "run attempt")
        canonical_uuids = [canonical_profile_uuid(value) for value in profile_uuids]
        if len(canonical_uuids) > MAX_PROFILES_PER_ATTEMPT:
            raise LedgerError("attempt ledger contains too many provisioning profiles")
        if canonical_uuids != sorted(set(canonical_uuids)):
            raise LedgerError("attempt profile UUIDs must be unique and sorted")
        return {
            "baseline": {"keychain_path": os.fspath(self.baseline_keychain)},
            "keychain": {
                "path": os.fspath(self.job_keychain_path(run_id, run_attempt))
            },
            "profiles": [
                {
                    "path": os.fspath(self.profile_path(profile_uuid)),
                    "uuid": profile_uuid,
                }
                for profile_uuid in canonical_uuids
            ],
            "run": {"attempt": run_attempt, "id": run_id},
            "schema": SCHEMA,
        }

    def _validate_document(self, document: dict[str, Any], filename: str) -> None:
        exact_keys(
            document,
            {"schema", "run", "baseline", "keychain", "profiles"},
            "attempt ledger",
        )
        if document["schema"] != SCHEMA:
            raise LedgerError("attempt ledger schema is unsupported")
        run = document["run"]
        if not isinstance(run, dict):
            raise LedgerError("attempt ledger run must be an object")
        exact_keys(run, {"id", "attempt"}, "attempt ledger run")
        run_id = positive_identifier(run["id"], "attempt ledger run id")
        run_attempt = positive_identifier(
            run["attempt"], "attempt ledger run attempt"
        )
        if filename != self.ledger_name(run_id, run_attempt):
            raise LedgerError("attempt ledger filename conflicts with its run identity")

        baseline = document["baseline"]
        keychain = document["keychain"]
        profiles = document["profiles"]
        if not isinstance(baseline, dict) or not isinstance(keychain, dict):
            raise LedgerError("attempt ledger keychain bindings must be objects")
        exact_keys(baseline, {"keychain_path"}, "attempt ledger baseline")
        exact_keys(keychain, {"path"}, "attempt ledger keychain")
        if not isinstance(profiles, list):
            raise LedgerError("attempt ledger profiles must be an array")
        profile_uuids: list[str] = []
        for index, profile in enumerate(profiles):
            if not isinstance(profile, dict):
                raise LedgerError(f"attempt ledger profile {index} must be an object")
            exact_keys(profile, {"uuid", "path"}, f"attempt ledger profile {index}")
            profile_uuids.append(canonical_profile_uuid(profile["uuid"]))
        expected = self._expected_document(run_id, run_attempt, profile_uuids)
        if document != expected:
            raise LedgerError("attempt ledger paths differ from recomputed job-owned paths")

    def _read_ledger(self, path: Path) -> LoadedLedger:
        metadata = self._validate_regular_file(
            path, f"attempt ledger {path.name}", exact_mode=0o600
        )
        if metadata.st_size > MAX_LEDGER_BYTES:
            raise LedgerError(f"attempt ledger {path.name} exceeds its size limit")
        try:
            contents = path.read_bytes()
        except OSError as error:
            raise LedgerError(f"could not read attempt ledger {path.name}") from error
        document = strict_json_document(contents, f"attempt ledger {path.name}")
        self._validate_document(document, path.name)
        return LoadedLedger(path=path, document=document, contents=contents)

    def _scan_state(self) -> tuple[list[LoadedLedger], list[Path]]:
        self._validate_directory(
            self.state_dir, "release credential state directory", exact_mode=0o700
        )
        ledgers: list[LoadedLedger] = []
        temporary_files: list[Path] = []
        try:
            entries = sorted(os.scandir(self.state_dir), key=lambda entry: entry.name)
        except OSError as error:
            raise LedgerError("could not enumerate release credential state") from error
        for entry in entries:
            if entry.name == LOCK_NAME:
                self._validate_regular_file(
                    Path(entry.path), "credential-ledger lock", exact_mode=0o600
                )
                continue
            path = Path(entry.path)
            if LEDGER_NAME_PATTERN.fullmatch(entry.name):
                ledgers.append(self._read_ledger(path))
                continue
            if TEMP_NAME_PATTERN.fullmatch(entry.name):
                self._validate_regular_file(
                    path, f"atomic ledger remnant {entry.name}", exact_mode=0o600
                )
                temporary_files.append(path)
                continue
            raise LedgerError(
                f"unexpected entry in release credential state: {entry.name}"
            )
        return ledgers, temporary_files

    def _fsync_directory(self, path: Path) -> None:
        flags = os.O_RDONLY
        if hasattr(os, "O_DIRECTORY"):
            flags |= os.O_DIRECTORY
        descriptor = os.open(path, flags)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)

    def _fsync_state_directory(self) -> None:
        self._fsync_directory(self.state_dir)

    def _atomic_write(self, destination: Path, document: dict[str, Any]) -> None:
        if destination.parent != self.state_dir:
            raise LedgerError("attempt ledger destination escaped its state directory")
        self._validate_document(document, destination.name)
        contents = canonical_json_bytes(document)
        if len(contents) > MAX_LEDGER_BYTES:
            raise LedgerError("attempt ledger exceeds its size limit")
        if destination.exists() or destination.is_symlink():
            self._validate_regular_file(
                destination, f"attempt ledger {destination.name}", exact_mode=0o600
            )
        temporary = self.state_dir / (
            f".{destination.name}.tmp-{uuid.uuid4().hex}"
        )
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = -1
        try:
            descriptor = os.open(temporary, flags, 0o600)
            os.fchmod(descriptor, 0o600)
            offset = 0
            while offset < len(contents):
                written = os.write(descriptor, contents[offset:])
                if written <= 0:
                    raise LedgerError("atomic attempt ledger write made no progress")
                offset += written
            os.fsync(descriptor)
            os.close(descriptor)
            descriptor = -1
            self._validate_regular_file(
                temporary, "atomic attempt ledger", exact_mode=0o600
            )
            os.replace(temporary, destination)
            self._fsync_state_directory()
        except OSError as error:
            raise LedgerError("could not atomically persist attempt ledger") from error
        finally:
            if descriptor >= 0:
                os.close(descriptor)
            try:
                metadata = os.lstat(temporary)
            except FileNotFoundError:
                pass
            else:
                if stat.S_ISREG(metadata.st_mode) and metadata.st_uid == os.geteuid():
                    try:
                        os.unlink(temporary)
                    except OSError:
                        pass

    def _target_metadata(self, path: Path, owner: str) -> os.stat_result | None:
        try:
            metadata = os.lstat(path)
        except FileNotFoundError:
            return None
        if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
            raise LedgerError(f"{owner} must be a real regular file")
        if metadata.st_uid != os.geteuid():
            raise LedgerError(f"{owner} has the wrong owner")
        if metadata.st_nlink != 1:
            raise LedgerError(f"{owner} must not have multiple hard links")
        return metadata

    def _scan_orphan_keychains(self) -> list[Path]:
        self._validate_descendant_directory(self.keychains_dir, "keychains directory")
        orphans: list[Path] = []
        try:
            entries = sorted(os.scandir(self.keychains_dir), key=lambda entry: entry.name)
        except OSError as error:
            raise LedgerError("could not enumerate the keychains directory") from error
        for entry in entries:
            match = KEYCHAIN_NAME_PATTERN.fullmatch(entry.name)
            if match is None:
                continue
            run_id, run_attempt = match.groups()
            expected = self.job_keychain_path(run_id, run_attempt)
            path = Path(entry.path)
            if path != expected:
                raise LedgerError("job-owned keychain path did not recompute exactly")
            self._target_metadata(path, f"job-owned keychain {entry.name}")
            orphans.append(path)
        return orphans

    def _validate_ledger_targets(self, ledger: LoadedLedger) -> None:
        expected_keychain = self.job_keychain_path(ledger.run_id, ledger.run_attempt)
        if ledger.keychain_path != expected_keychain:
            raise LedgerError("attempt keychain path failed exact recomputation")
        self._target_metadata(
            ledger.keychain_path,
            f"attempt keychain {ledger.run_id}/{ledger.run_attempt}",
        )
        if ledger.profile_paths:
            self._validate_optional_descendant_directory(
                self.profiles_dir, "provisioning profiles directory"
            )
        seen_profiles: set[Path] = set()
        for profile in ledger.document["profiles"]:
            expected_profile = self.profile_path(profile["uuid"])
            actual_profile = Path(profile["path"])
            if actual_profile != expected_profile or actual_profile in seen_profiles:
                raise LedgerError("attempt profile path failed exact recomputation")
            seen_profiles.add(actual_profile)
            self._target_metadata(
                actual_profile,
                f"attempt profile {profile['uuid']}",
            )

    def _reset_keychain_preferences(self) -> None:
        self._validate_baseline()
        baseline = os.fspath(self.baseline_keychain)
        commands = (
            (
                [
                    "/usr/bin/security",
                    "list-keychains",
                    "-d",
                    "user",
                    "-s",
                    baseline,
                ],
                "reset-list-keychains",
            ),
            (
                [
                    "/usr/bin/security",
                    "default-keychain",
                    "-d",
                    "user",
                    "-s",
                    baseline,
                ],
                "reset-default-keychain",
            ),
        )
        failures = [
            purpose
            for arguments, purpose in commands
            if not self.runner.run(arguments, purpose)
        ]
        if failures:
            raise LedgerError(
                "could not restore baseline keychain preferences: "
                + ", ".join(failures)
            )

    def _unlink_validated_file(self, path: Path, owner: str) -> None:
        metadata = self._target_metadata(path, owner)
        if metadata is None:
            return
        try:
            os.unlink(path)
            self._fsync_directory(path.parent)
        except OSError as error:
            raise LedgerError(f"could not remove {owner}") from error
        if os.path.lexists(path):
            raise LedgerError(f"{owner} remains after cleanup")

    def _remove_keychain(self, path: Path) -> None:
        metadata = self._target_metadata(path, f"job-owned keychain {path.name}")
        if metadata is None:
            return
        # Security.framework removal is preferred so its keychain registry is
        # updated. An exact no-follow unlink is the bounded fallback used by the
        # existing workflow when Security cannot remove a stale file.
        self.runner.run(
            ["/usr/bin/security", "delete-keychain", os.fspath(path)],
            "delete-keychain",
        )
        if os.path.lexists(path):
            self._unlink_validated_file(path, f"job-owned keychain {path.name}")
        else:
            self._fsync_directory(path.parent)

    def _ledger_targets_absent(self, ledger: LoadedLedger) -> bool:
        if self._target_metadata(
            ledger.keychain_path,
            f"attempt keychain {ledger.run_id}/{ledger.run_attempt}",
        ) is not None:
            return False
        return all(
            self._target_metadata(path, f"attempt profile {path.name}") is None
            for path in ledger.profile_paths
        )

    def _unlink_loaded_ledger(self, ledger: LoadedLedger) -> None:
        current = self._read_ledger(ledger.path)
        if current.contents != ledger.contents:
            raise LedgerError("attempt ledger changed while cleanup was in progress")
        if not self._ledger_targets_absent(current):
            raise LedgerError("attempt ledger targets remain after cleanup")
        try:
            os.unlink(current.path)
            self._fsync_state_directory()
        except OSError as error:
            raise LedgerError(f"could not remove attempt ledger {current.path.name}") from error

    def begin(self, run_id: str, run_attempt: str) -> dict[str, Any]:
        run_id = positive_identifier(run_id, "run id")
        run_attempt = positive_identifier(run_attempt, "run attempt")
        with self._locked():
            ledgers, temporary_files = self._scan_state()
            orphans = self._scan_orphan_keychains()
            if ledgers or temporary_files or orphans:
                raise LedgerError("stale release credential state must be recovered before begin")
            self._validate_baseline()
            document = self._expected_document(run_id, run_attempt, ())
            destination = self.ledger_path(run_id, run_attempt)
            if os.path.lexists(destination):
                raise LedgerError("current attempt ledger already exists")
            self._atomic_write(destination, document)
            return document

    def prepare_profile_directory(self) -> dict[str, str]:
        with self._locked():
            ledgers, temporary_files = self._scan_state()
            if ledgers or temporary_files or self._scan_orphan_keychains():
                raise LedgerError(
                    "stale release credential state must be recovered before profile setup"
                )
            self._ensure_descendant_directory(
                self.profiles_dir, "provisioning profiles directory"
            )
            return {"path": os.fspath(self.profiles_dir)}

    def plan_profile(
        self, run_id: str, run_attempt: str, profile_uuid: str
    ) -> dict[str, Any]:
        run_id = positive_identifier(run_id, "run id")
        run_attempt = positive_identifier(run_attempt, "run attempt")
        profile_uuid = canonical_profile_uuid(profile_uuid)
        with self._locked():
            ledgers, temporary_files = self._scan_state()
            if temporary_files or len(ledgers) != 1:
                raise LedgerError("profile planning requires exactly one clean attempt ledger")
            ledger = ledgers[0]
            if (ledger.run_id, ledger.run_attempt) != (run_id, run_attempt):
                raise LedgerError("profile planning run/attempt differs from the active ledger")
            self._validate_descendant_directory(
                self.profiles_dir, "provisioning profiles directory"
            )
            profile_path = self.profile_path(profile_uuid)
            existing_uuids = [item["uuid"] for item in ledger.document["profiles"]]
            if profile_uuid in existing_uuids:
                return ledger.document
            if self._target_metadata(
                profile_path, f"planned profile {profile_uuid}"
            ) is not None:
                raise LedgerError(
                    "refusing to claim a provisioning profile that predates this attempt"
                )
            document = self._expected_document(
                run_id, run_attempt, sorted(existing_uuids + [profile_uuid])
            )
            self._atomic_write(ledger.path, document)
            return document

    def recover(self) -> dict[str, int]:
        with self._locked():
            ledgers, temporary_files = self._scan_state()
            orphan_keychains = self._scan_orphan_keychains()
            for ledger in ledgers:
                self._validate_ledger_targets(ledger)
            # Validate every target before the first external or filesystem
            # mutation. Malformed ledgers and symlink/hard-link substitutions
            # therefore fail without partially cleaning trusted evidence.
            ledger_keychains = {ledger.keychain_path for ledger in ledgers}
            keychains = sorted(ledger_keychains | set(orphan_keychains))
            profiles = sorted(
                {path for ledger in ledgers for path in ledger.profile_paths}
            )
            present_keychains = {
                path
                for path in keychains
                if self._target_metadata(path, f"job-owned keychain {path.name}")
                is not None
            }
            present_profiles = {
                path
                for path in profiles
                if self._target_metadata(path, f"attempt profile {path.name}")
                is not None
            }
            self._reset_keychain_preferences()

            failures: list[str] = []
            for path in keychains:
                try:
                    self._remove_keychain(path)
                except LedgerError as error:
                    failures.append(str(error))
            for path in profiles:
                try:
                    self._unlink_validated_file(path, f"attempt profile {path.name}")
                except LedgerError as error:
                    failures.append(str(error))

            removed_ledgers = 0
            # If any target deletion was not durably confirmed, retain every
            # ledger. A later recovery can then prove absence and clear it; a
            # partially successful pass must never discard its retry owner.
            if not failures:
                for ledger in ledgers:
                    try:
                        if self._ledger_targets_absent(ledger):
                            self._unlink_loaded_ledger(ledger)
                            removed_ledgers += 1
                        else:
                            failures.append(
                                f"targets remain for attempt {ledger.run_id}/{ledger.run_attempt}"
                            )
                    except LedgerError as error:
                        failures.append(str(error))

            removed_temporaries = 0
            for path in temporary_files:
                try:
                    self._validate_regular_file(
                        path, f"atomic ledger remnant {path.name}", exact_mode=0o600
                    )
                    os.unlink(path)
                    removed_temporaries += 1
                except (LedgerError, OSError) as error:
                    failures.append(f"could not remove atomic ledger remnant: {error}")
            if temporary_files:
                self._fsync_state_directory()

            remaining_orphans = self._scan_orphan_keychains()
            if remaining_orphans:
                failures.append("job-owned keychains remain after recovery")
            if failures:
                raise LedgerError("credential recovery incomplete: " + "; ".join(failures))
            return {
                "keychains_removed": len(present_keychains),
                "ledgers_removed": removed_ledgers,
                "profiles_removed": len(present_profiles),
                "temporary_files_removed": removed_temporaries,
            }

    def complete(self, run_id: str, run_attempt: str) -> dict[str, str]:
        run_id = positive_identifier(run_id, "run id")
        run_attempt = positive_identifier(run_attempt, "run attempt")
        with self._locked():
            ledgers, temporary_files = self._scan_state()
            if temporary_files or len(ledgers) != 1:
                raise LedgerError("completion requires exactly one clean attempt ledger")
            ledger = ledgers[0]
            if (ledger.run_id, ledger.run_attempt) != (run_id, run_attempt):
                raise LedgerError("completion run/attempt differs from the active ledger")
            self._validate_ledger_targets(ledger)
            if not self._ledger_targets_absent(ledger):
                raise LedgerError("cannot complete while attempt-owned targets remain")
            self._unlink_loaded_ledger(ledger)
            return {"run_id": run_id, "run_attempt": run_attempt}

    def audit(self) -> dict[str, int]:
        with self._locked():
            ledgers, temporary_files = self._scan_state()
            orphan_keychains = self._scan_orphan_keychains()
            if ledgers or temporary_files or orphan_keychains:
                raise LedgerError(
                    "stale release credential state is present "
                    f"(ledgers={len(ledgers)}, temporary_files={len(temporary_files)}, "
                    f"keychains={len(orphan_keychains)})"
                )
            return {"ledgers": 0, "temporary_files": 0, "keychains": 0}


def expect_failure(callback: Any, label: str) -> None:
    try:
        callback()
    except LedgerError:
        return
    raise AssertionError(f"credential ledger self-test accepted {label}")


def self_test() -> None:
    class FakeRunner:
        def __init__(self, failures: set[str] | None = None):
            self.failures = failures or set()
            self.calls: list[tuple[tuple[str, ...], str]] = []

        def run(self, arguments: Sequence[str], purpose: str) -> bool:
            self.calls.append((tuple(arguments), purpose))
            return purpose not in self.failures

    def fixture(root: Path, name: str, runner: FakeRunner | None = None):
        home = root / name
        home.mkdir(mode=0o700)
        keychains = home / "Library" / "Keychains"
        profiles = (
            home
            / "Library"
            / "Developer"
            / "Xcode"
            / "UserData"
            / "Provisioning Profiles"
        )
        keychains.mkdir(parents=True, mode=0o700)
        profiles.mkdir(parents=True, mode=0o700)
        baseline = keychains / BASELINE_KEYCHAIN_NAME
        baseline.write_bytes(b"fixture baseline")
        baseline.chmod(0o600)
        selected_runner = runner or FakeRunner()
        return CredentialLedgerStore(home, selected_runner), selected_runner

    profile_a = "12345678-1234-1234-1234-1234567890AB"
    profile_b = "ABCDEFAB-CDEF-CDEF-CDEF-ABCDEFABCDEF"

    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)

        store, runner = fixture(root, "round-trip")
        recovery = store.recover()
        if recovery != {
            "keychains_removed": 0,
            "ledgers_removed": 0,
            "profiles_removed": 0,
            "temporary_files_removed": 0,
        }:
            raise AssertionError("empty recovery returned the wrong counts")
        if [purpose for _, purpose in runner.calls] != [
            "reset-list-keychains",
            "reset-default-keychain",
        ]:
            raise AssertionError("recovery did not reset both baseline preferences")
        document = store.begin("123", "2")
        ledger_path = store.ledger_path("123", "2")
        if mode_bits(os.lstat(store.state_dir)) != 0o700:
            raise AssertionError("state directory is not mode 0700")
        if mode_bits(os.lstat(ledger_path)) != 0o600:
            raise AssertionError("attempt ledger is not mode 0600")
        if ledger_path.read_bytes() != canonical_json_bytes(document):
            raise AssertionError("attempt ledger is not canonical")
        document = store.plan_profile("123", "2", profile_b)
        document = store.plan_profile("123", "2", profile_a)
        if [profile["uuid"] for profile in document["profiles"]] != [
            profile_a,
            profile_b,
        ]:
            raise AssertionError("planned profiles are not canonical and sorted")
        if store.plan_profile("123", "2", profile_a) != document:
            raise AssertionError("repeated profile planning is not idempotent")
        store.job_keychain_path("123", "2").write_bytes(b"keychain")
        for profile in (profile_a, profile_b):
            store.profile_path(profile).write_bytes(b"profile")
        expect_failure(store.audit, "active attempt during audit")
        recovery = store.recover()
        if recovery["ledgers_removed"] != 1 or recovery["profiles_removed"] != 2:
            raise AssertionError("stale recovery returned the wrong ownership counts")
        if any(
            os.path.lexists(path)
            for path in (
                ledger_path,
                store.job_keychain_path("123", "2"),
                store.profile_path(profile_a),
                store.profile_path(profile_b),
            )
        ):
            raise AssertionError("stale recovery left attempt-owned targets")
        store.audit()

        store, _ = fixture(root, "complete")
        store.begin("200", "3")
        active_keychain = store.job_keychain_path("200", "3")
        active_keychain.write_bytes(b"keychain")
        expect_failure(
            lambda: store.complete("200", "3"),
            "completion with a remaining keychain",
        )
        if not store.ledger_path("200", "3").exists():
            raise AssertionError("failed completion removed its recovery ledger")
        active_keychain.unlink()
        store.complete("200", "3")
        store.audit()

        store, _ = fixture(root, "exact-attempt")
        store.begin("300", "4")
        expect_failure(
            lambda: store.plan_profile("300", "5", profile_a),
            "profile planning for another attempt",
        )
        expect_failure(
            lambda: store.complete("301", "4"),
            "completion for another run",
        )
        expect_failure(
            lambda: store.plan_profile("300", "4", profile_a.lower()),
            "noncanonical profile UUID",
        )
        store.complete("300", "4")

        store, _ = fixture(root, "preexisting-profile")
        store.begin("310", "1")
        store.profile_path(profile_a).write_bytes(b"preexisting")
        expect_failure(
            lambda: store.plan_profile("310", "1", profile_a),
            "claim of a pre-existing profile",
        )
        if store.profile_path(profile_a).read_bytes() != b"preexisting":
            raise AssertionError("profile planning changed a pre-existing profile")

        store, _ = fixture(root, "missing-profile-directory")
        store.profiles_dir.rmdir()
        store.recover()
        prepared = store.prepare_profile_directory()
        if prepared["path"] != os.fspath(store.profiles_dir):
            raise AssertionError("profile directory preparation returned the wrong path")
        store._validate_descendant_directory(
            store.profiles_dir, "prepared provisioning profiles directory"
        )
        store.begin("311", "1")
        store.complete("311", "1")

        store, _ = fixture(root, "profile-directory-symlink")
        store.profiles_dir.rmdir()
        user_data = store.profiles_dir.parent
        user_data.rmdir()
        outside_profiles = root / "outside-user-data"
        outside_profiles.mkdir(mode=0o700)
        user_data.symlink_to(outside_profiles, target_is_directory=True)
        expect_failure(
            store.prepare_profile_directory,
            "symlinked provisioning profile ancestor",
        )
        if (outside_profiles / "Provisioning Profiles").exists():
            raise AssertionError("profile directory preparation crossed a symlink")

        store, _ = fixture(root, "missing-planned-profile-directory")
        store.begin("312", "1")
        store.plan_profile("312", "1", profile_a)
        store.profiles_dir.rmdir()
        recovered = store.recover()
        if recovered["ledgers_removed"] != 1 or recovered["profiles_removed"] != 0:
            raise AssertionError("missing planned-profile directory was not proven absent")

        store, runner = fixture(root, "orphan")
        orphan = store.job_keychain_path("400", "7")
        orphan.write_bytes(b"orphan")
        unrelated = store.keychains_dir / "tron-ios-signing-0-7.keychain-db"
        unrelated.write_bytes(b"not a canonical job name")
        expect_failure(store.audit, "strictly named orphan keychain")
        store.recover()
        if orphan.exists() or not unrelated.exists():
            raise AssertionError("orphan recovery crossed its strict name boundary")
        if "delete-keychain" not in [purpose for _, purpose in runner.calls]:
            raise AssertionError("orphan recovery did not ask Security to delete the keychain")

        failing_runner = FakeRunner({"delete-keychain"})
        store, _ = fixture(root, "delete-fallback", failing_runner)
        orphan = store.job_keychain_path("401", "1")
        orphan.write_bytes(b"orphan")
        store.recover()
        if orphan.exists():
            raise AssertionError("exact unlink fallback left a stale keychain")

        for case_name, mutate in (
            (
                "noncanonical",
                lambda path: path.write_text(
                    json.dumps(json.loads(path.read_text(encoding="utf-8"))),
                    encoding="utf-8",
                ),
            ),
            ("wrong-ledger-mode", lambda path: path.chmod(0o644)),
        ):
            store, _ = fixture(root, case_name)
            store.begin("500", "1")
            ledger = store.ledger_path("500", "1")
            mutate(ledger)
            expect_failure(store.recover, case_name)
            if not ledger.exists():
                raise AssertionError(f"{case_name} recovery removed invalid evidence")

        store, _ = fixture(root, "duplicate-json")
        store.begin("501", "1")
        ledger = store.ledger_path("501", "1")
        ledger.write_bytes(b'{"schema":"x","schema":"y"}\n')
        ledger.chmod(0o600)
        expect_failure(store.recover, "duplicate ledger JSON keys")

        store, _ = fixture(root, "path-traversal")
        store.begin("502", "1")
        ledger = store.ledger_path("502", "1")
        changed = json.loads(ledger.read_text(encoding="utf-8"))
        changed["keychain"]["path"] = os.fspath(store.home / ".." / "outside")
        ledger.write_bytes(canonical_json_bytes(changed))
        ledger.chmod(0o600)
        expect_failure(store.recover, "persisted keychain path traversal")

        store, _ = fixture(root, "profile-path-traversal")
        store.begin("5021", "1")
        store.plan_profile("5021", "1", profile_a)
        ledger = store.ledger_path("5021", "1")
        changed = json.loads(ledger.read_text(encoding="utf-8"))
        changed["profiles"][0]["path"] = os.fspath(store.home / ".." / "outside")
        ledger.write_bytes(canonical_json_bytes(changed))
        ledger.chmod(0o600)
        expect_failure(store.recover, "persisted profile path traversal")

        store, _ = fixture(root, "filename-mismatch")
        store.begin("503", "1")
        original = store.ledger_path("503", "1")
        mismatched = store.ledger_path("504", "1")
        original.rename(mismatched)
        expect_failure(store.recover, "ledger filename/run mismatch")

        store, _ = fixture(root, "state-mode")
        store.begin("505", "1")
        store.state_dir.chmod(0o755)
        expect_failure(store.audit, "world-readable state-directory mode")

        store, _ = fixture(root, "state-symlink")
        real_state = root / "real-state"
        real_state.mkdir(mode=0o700)
        store.state_dir.symlink_to(real_state, target_is_directory=True)
        expect_failure(store.audit, "symlink state directory")

        store, _ = fixture(root, "baseline-mode")
        store.baseline_keychain.chmod(0o644)
        expect_failure(store.recover, "non-private baseline keychain mode")

        symlink_home = root / "symlink-home"
        real_home = root / "real-home"
        real_home.mkdir(mode=0o700)
        symlink_home.symlink_to(real_home, target_is_directory=True)
        expect_failure(
            lambda: CredentialLedgerStore(symlink_home, FakeRunner()),
            "symlink release home",
        )
        expect_failure(
            lambda: CredentialLedgerStore(root / "real-home" / "..", FakeRunner()),
            "non-normalized release home",
        )

        store, _ = fixture(root, "ledger-symlink")
        store.begin("506", "1")
        ledger = store.ledger_path("506", "1")
        outside = root / "outside-ledger"
        outside.write_text("outside", encoding="utf-8")
        ledger.unlink()
        ledger.symlink_to(outside)
        expect_failure(store.recover, "symlink attempt ledger")
        if outside.read_text(encoding="utf-8") != "outside":
            raise AssertionError("ledger symlink validation touched its target")

        store, _ = fixture(root, "keychain-symlink")
        outside = root / "outside-keychain"
        outside.write_text("outside", encoding="utf-8")
        store.job_keychain_path("507", "1").symlink_to(outside)
        expect_failure(store.recover, "symlink job-owned keychain")
        if outside.read_text(encoding="utf-8") != "outside":
            raise AssertionError("keychain symlink validation touched its target")

        store, _ = fixture(root, "profile-symlink")
        store.begin("508", "1")
        store.plan_profile("508", "1", profile_a)
        outside = root / "outside-profile"
        outside.write_text("outside", encoding="utf-8")
        store.profile_path(profile_a).symlink_to(outside)
        expect_failure(store.recover, "symlink planned profile")
        if outside.read_text(encoding="utf-8") != "outside":
            raise AssertionError("profile symlink validation touched its target")

        store, _ = fixture(root, "hard-link")
        store.begin("509", "1")
        keychain = store.job_keychain_path("509", "1")
        keychain.write_bytes(b"keychain")
        hard_link = root / "keychain-hard-link"
        os.link(keychain, hard_link)
        expect_failure(store.recover, "multiply linked job-owned keychain")
        if not keychain.exists() or not hard_link.exists():
            raise AssertionError("hard-link rejection removed a target")

        store, _ = fixture(root, "unexpected-state")
        store.recover()
        unexpected = store.state_dir / "notes.txt"
        unexpected.write_text("unexpected", encoding="utf-8")
        unexpected.chmod(0o600)
        expect_failure(store.audit, "unexpected state-directory entry")

        store, _ = fixture(root, "atomic-remnant")
        store.begin("510", "1")
        temporary_path = store.state_dir / (
            ".attempt-510-1.json.tmp-" + "a" * 32
        )
        temporary_path.write_bytes(b"partial")
        temporary_path.chmod(0o600)
        expect_failure(store.audit, "atomic-write remnant")
        recovered = store.recover()
        if recovered["temporary_files_removed"] != 1 or temporary_path.exists():
            raise AssertionError("recovery did not remove a validated atomic remnant")

        for purpose in ("reset-list-keychains", "reset-default-keychain"):
            failing_runner = FakeRunner({purpose})
            store, _ = fixture(root, f"failure-{purpose}", failing_runner)
            store.begin("511", "1")
            keychain = store.job_keychain_path("511", "1")
            keychain.write_bytes(b"keychain")
            expect_failure(store.recover, f"{purpose} failure")
            if not keychain.exists() or not store.ledger_path("511", "1").exists():
                raise AssertionError("baseline-reset failure mutated recovery ownership")

        store, _ = fixture(root, "target-directory")
        store.begin("512", "1")
        store.job_keychain_path("512", "1").mkdir()
        expect_failure(store.recover, "directory substituted for keychain file")
        if not store.ledger_path("512", "1").exists():
            raise AssertionError("unsafe target validation removed its ledger")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest="command", required=True)
    for name in ("begin", "complete"):
        command = commands.add_parser(name)
        command.add_argument("--run-id", required=True)
        command.add_argument("--run-attempt", required=True)
    profile = commands.add_parser("plan-profile")
    profile.add_argument("--run-id", required=True)
    profile.add_argument("--run-attempt", required=True)
    profile.add_argument("--profile-uuid", required=True)
    commands.add_parser("recover")
    commands.add_parser("prepare-profile-directory")
    commands.add_parser("audit")
    commands.add_parser("self-test")
    return result


def main() -> int:
    arguments = parser().parse_args()
    try:
        if arguments.command == "self-test":
            self_test()
            print("iOS release credential ledger self-test passed")
            return 0
        store = CredentialLedgerStore.production()
        if arguments.command == "begin":
            result = store.begin(arguments.run_id, arguments.run_attempt)
        elif arguments.command == "plan-profile":
            result = store.plan_profile(
                arguments.run_id, arguments.run_attempt, arguments.profile_uuid
            )
        elif arguments.command == "recover":
            result = store.recover()
        elif arguments.command == "prepare-profile-directory":
            result = store.prepare_profile_directory()
        elif arguments.command == "complete":
            result = store.complete(arguments.run_id, arguments.run_attempt)
        elif arguments.command == "audit":
            result = store.audit()
        else:  # pragma: no cover - argparse owns this boundary.
            raise LedgerError(f"unsupported command {arguments.command}")
    except LedgerError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
