#!/usr/bin/env python3
"""Provision and validate one exact repository-owned iOS test simulator."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from typing import Any

DESTINATION_EXIT = 66
SCHEMA = "tron.ios-test-simulator.v1"
OWNER = "tron-ios-test"


class DestinationError(RuntimeError):
    pass


def simctl(*arguments: str, capture: bool = True) -> str:
    command = [os.environ.get("TRON_IOS_XCRUN", "xcrun"), "simctl", *arguments]
    completed = subprocess.run(
        command,
        check=False,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
        text=True,
    )
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout or "simctl failed").strip()
        raise DestinationError(f"{' '.join(command)}: {detail}")
    return completed.stdout if capture else ""


def inventory() -> dict[str, Any]:
    try:
        value = json.loads(simctl("list", "--json"))
    except json.JSONDecodeError as error:
        raise DestinationError(f"simctl returned invalid JSON: {error}") from error
    if not isinstance(value, dict):
        raise DestinationError("simctl inventory is not an object")
    return value


def available(value: dict[str, Any]) -> bool:
    return value.get("isAvailable", True) is not False and not value.get("availabilityError")


def exact_runtime(document: dict[str, Any], version: str) -> dict[str, Any]:
    matches = [
        runtime
        for runtime in document.get("runtimes", [])
        if runtime.get("platform") == "iOS" and runtime.get("version") == version and available(runtime)
    ]
    if len(matches) != 1:
        raise DestinationError(f"expected one available iOS {version} runtime, found {len(matches)}")
    return matches[0]


def exact_device_type(document: dict[str, Any], name: str) -> dict[str, Any]:
    matches = [
        device_type
        for device_type in document.get("devicetypes", [])
        if device_type.get("name") == name and available(device_type)
    ]
    if len(matches) != 1:
        raise DestinationError(f"expected one available simulator device type named {name!r}, found {len(matches)}")
    return matches[0]


def all_devices(document: dict[str, Any]) -> list[tuple[str, dict[str, Any]]]:
    devices = document.get("devices", {})
    if not isinstance(devices, dict):
        raise DestinationError("simctl devices inventory is malformed")
    return [
        (runtime_identifier, device)
        for runtime_identifier, runtime_devices in devices.items()
        if isinstance(runtime_devices, list)
        for device in runtime_devices
        if isinstance(device, dict)
    ]


def atomic_write(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, indent=2, sort_keys=True)
            handle.write("\n")
        os.chmod(temporary_name, 0o600)
        os.replace(temporary_name, path)
    finally:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass


def load_marker(path: Path) -> dict[str, Any] | None:
    if not path.exists():
        return None
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise DestinationError(f"owned simulator marker is unreadable: {path}: {error}") from error
    if not isinstance(value, dict) or value.get("schema") != SCHEMA or value.get("owner") != OWNER:
        raise DestinationError(f"refusing unowned simulator marker: {path}")
    for key in ("udid", "name", "runtime_identifier", "device_type_identifier"):
        if not isinstance(value.get(key), str) or not value[key]:
            raise DestinationError(f"owned simulator marker is missing {key}: {path}")
    return value


def development_udid(arguments: argparse.Namespace) -> str | None:
    if arguments.development_state.exists():
        return arguments.development_state.read_text().splitlines()[0].strip() or None
    return None


def find_device(document: dict[str, Any], udid: str) -> tuple[str, dict[str, Any]] | None:
    matches = [(runtime, device) for runtime, device in all_devices(document) if device.get("udid") == udid]
    if len(matches) > 1:
        raise DestinationError(f"duplicate simulator UDID in inventory: {udid}")
    return matches[0] if matches else None


def validate_marker(
    document: dict[str, Any], marker: dict[str, Any], runtime: dict[str, Any], device_type: dict[str, Any], dev_udid: str | None
) -> dict[str, Any]:
    udid = marker["udid"]
    if udid == dev_udid:
        raise DestinationError("test simulator marker points at the remembered Development simulator")
    match = find_device(document, udid)
    if match is None:
        raise DestinationError(f"owned simulator no longer exists: {udid}")
    runtime_identifier, device = match
    if not available(device):
        raise DestinationError(f"owned simulator is unavailable: {udid}")
    expected = (
        marker["name"],
        marker["runtime_identifier"],
        marker["device_type_identifier"],
    )
    actual = (
        device.get("name"),
        runtime_identifier,
        device.get("deviceTypeIdentifier"),
    )
    if actual != expected:
        raise DestinationError(f"owned simulator identity changed: expected {expected}, found {actual}")
    requested = (runtime.get("identifier"), device_type.get("identifier"))
    if actual[1:] != requested:
        raise DestinationError(f"owned simulator uses stale runtime/device type: {actual[1:]}, expected {requested}")
    return device


def owned_identity_matches(document: dict[str, Any], marker: dict[str, Any]) -> bool:
    match = find_device(document, marker["udid"])
    if match is None:
        return True
    runtime_identifier, device = match
    return (
        device.get("name") == marker["name"]
        and runtime_identifier == marker["runtime_identifier"]
        and device.get("deviceTypeIdentifier") == marker["device_type_identifier"]
    )


def delete_owned(marker_path: Path) -> None:
    marker = load_marker(marker_path)
    if marker is None:
        return
    document = inventory()
    if not owned_identity_matches(document, marker):
        raise DestinationError("refusing to delete a simulator whose current identity does not match its ownership marker")
    current = find_device(document, marker["udid"])
    if current is not None:
        if current[1].get("state") == "Booted":
            simctl("shutdown", marker["udid"])
        simctl("delete", marker["udid"])
    marker_path.unlink(missing_ok=True)


def provision(arguments: argparse.Namespace) -> dict[str, Any]:
    document = inventory()
    runtime = exact_runtime(document, arguments.runtime)
    device_type = exact_device_type(document, arguments.device_type)
    dev_udid = development_udid(arguments)
    marker = load_marker(arguments.marker)

    if marker is not None:
        try:
            device = validate_marker(document, marker, runtime, device_type, dev_udid)
        except DestinationError as error:
            stale_requested = (
                marker["runtime_identifier"] != runtime.get("identifier")
                or marker["device_type_identifier"] != device_type.get("identifier")
                or find_device(document, marker["udid"]) is None
            )
            if not stale_requested or not owned_identity_matches(document, marker):
                raise
            current = find_device(document, marker["udid"])
            if current is not None:
                if current[1].get("state") == "Booted":
                    simctl("shutdown", marker["udid"])
                simctl("delete", marker["udid"])
            arguments.marker.unlink(missing_ok=True)
            marker = None
            document = inventory()

    if marker is None:
        collisions = [device for _, device in all_devices(document) if device.get("name") == arguments.name]
        if collisions:
            raise DestinationError(
                f"refusing to adopt {len(collisions)} unmarked simulator(s) named {arguments.name!r}; remove them manually or choose a unique owned name"
            )
        udid = simctl("create", arguments.name, device_type["identifier"], runtime["identifier"]).strip()
        if not udid:
            raise DestinationError("simctl create returned an empty UDID")
        if udid == dev_udid:
            raise DestinationError("simctl created the remembered Development simulator UDID")
        marker = {
            "schema": SCHEMA,
            "owner": OWNER,
            "udid": udid,
            "name": arguments.name,
            "runtime_identifier": runtime["identifier"],
            "runtime_version": runtime["version"],
            "runtime_build": runtime.get("buildversion"),
            "device_type_identifier": device_type["identifier"],
            "device_type_name": device_type["name"],
            "ephemeral": arguments.ephemeral,
        }
        atomic_write(arguments.marker, marker)
        document = inventory()
        device = validate_marker(document, marker, runtime, device_type, dev_udid)

    if device.get("state") != "Booted":
        simctl("boot", marker["udid"])
    simctl("bootstatus", marker["udid"], "-b")
    document = inventory()
    device = validate_marker(document, marker, runtime, device_type, dev_udid)
    return {**marker, "state": device.get("state"), "udid_sha256": hashlib.sha256(marker["udid"].encode()).hexdigest()}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("provision", "validate", "status", "delete"))
    parser.add_argument("--marker", required=True, type=Path)
    parser.add_argument("--runtime", required=True)
    parser.add_argument("--device-type", required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("--development-state", required=True, type=Path)
    parser.add_argument("--ephemeral", action="store_true")
    return parser.parse_args()


def main() -> int:
    arguments = parse_args()
    try:
        if arguments.command == "delete":
            delete_owned(arguments.marker)
            return 0
        if arguments.command == "provision":
            details = provision(arguments)
        else:
            document = inventory()
            runtime = exact_runtime(document, arguments.runtime)
            device_type = exact_device_type(document, arguments.device_type)
            marker = load_marker(arguments.marker)
            if marker is None:
                if arguments.command == "status":
                    print("not provisioned")
                    return 0
                raise DestinationError("test simulator is not provisioned")
            device = validate_marker(document, marker, runtime, device_type, development_udid(arguments))
            details = {
                **marker,
                "state": device.get("state"),
                "udid_sha256": hashlib.sha256(marker["udid"].encode()).hexdigest(),
            }
        if arguments.command == "status":
            public_details = dict(details)
            public_details.pop("udid", None)
            print(json.dumps(public_details, indent=2, sort_keys=True))
        else:
            print(details["udid"])
        return 0
    except DestinationError as error:
        print(f"error: {error}", file=sys.stderr)
        return DESTINATION_EXIT


if __name__ == "__main__":
    raise SystemExit(main())
