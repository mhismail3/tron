#!/usr/bin/env python3
"""Canonical Gateway protocol contract and artifact verification helpers."""
from __future__ import annotations

import json
import plistlib
import re
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CONTRACT_PATH = ROOT / "config" / "GatewayProtocol.json"


class ProtocolContractError(ValueError):
    pass


@dataclass(frozen=True)
class GatewayProtocolContract:
    protocol_version: int
    min_protocol_version: int


def _regular_file(path: Path) -> bool:
    return path.is_file() and not path.is_symlink()


def load_contract(path: Path = CONTRACT_PATH) -> GatewayProtocolContract:
    if not _regular_file(path):
        raise ProtocolContractError(f"missing regular protocol contract: {path}")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ProtocolContractError(f"cannot decode protocol contract: {exc}") from exc
    if not isinstance(value, dict) or set(value) != {"schema", "protocolVersion", "minProtocolVersion"}:
        raise ProtocolContractError("protocol contract has an invalid shape")
    protocol = value.get("protocolVersion")
    minimum = value.get("minProtocolVersion")
    if value.get("schema") != 1 or type(protocol) is not int or type(minimum) is not int:
        raise ProtocolContractError("protocol contract values are invalid")
    if not (1 <= minimum <= protocol <= 65_535):
        raise ProtocolContractError("protocol contract range is invalid")
    if minimum != protocol:
        raise ProtocolContractError("Tron currently requires one exact lockstep protocol version")
    return GatewayProtocolContract(protocol, minimum)


def _read(path: Path) -> str:
    if not _regular_file(path):
        raise ProtocolContractError(f"missing regular source file: {path}")
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        raise ProtocolContractError(f"cannot read {path}: {exc}") from exc


def _exact_integer(source: str, pattern: str, label: str) -> int:
    matches = re.findall(pattern, source, flags=re.MULTILINE)
    if len(matches) != 1:
        raise ProtocolContractError(f"{label} must have one exact integer declaration")
    return int(matches[0])


def protocol_from_gateway_version(path: Path) -> GatewayProtocolContract:
    source = _read(path)
    protocol = _exact_integer(source, r"^export const PROTOCOL_VERSION\s*=\s*(\d+);$", f"{path} PROTOCOL_VERSION")
    minimum = _exact_integer(source, r"^export const MIN_PROTOCOL_VERSION\s*=\s*(\d+);$", f"{path} MIN_PROTOCOL_VERSION")
    return GatewayProtocolContract(protocol, minimum)


def _expect_equal(actual: GatewayProtocolContract, expected: GatewayProtocolContract, label: str) -> None:
    if actual != expected:
        raise ProtocolContractError(
            f"{label} protocol {actual.protocol_version}/{actual.min_protocol_version} "
            f"does not match canonical {expected.protocol_version}/{expected.min_protocol_version}"
        )


def _expect_project_settings(path: Path, expected: GatewayProtocolContract) -> None:
    source = _read(path)
    for key, value in (
        ("TRON_GATEWAY_PROTOCOL_VERSION", expected.protocol_version),
        ("TRON_GATEWAY_MIN_PROTOCOL_VERSION", expected.min_protocol_version),
    ):
        pattern = rf"^\s*{re.escape(key)}:\s*[\"']?{value}[\"']?\s*$"
        if len(re.findall(pattern, source, flags=re.MULTILINE)) != 1:
            raise ProtocolContractError(f"{path} must declare {key}={value} exactly once")


def _expect_plist_placeholders(path: Path) -> None:
    source = _read(path)
    required = {
        "TRONGatewayProtocolVersion": "$(TRON_GATEWAY_PROTOCOL_VERSION)",
        "TRONGatewayMinProtocolVersion": "$(TRON_GATEWAY_MIN_PROTOCOL_VERSION)",
    }
    for key, value in required.items():
        pattern = rf"<key>{re.escape(key)}</key>\s*<string>{re.escape(value)}</string>"
        if len(re.findall(pattern, source)) != 1:
            raise ProtocolContractError(f"{path} must contain exact {key} build metadata")


def verify_source_contract(root: Path = ROOT) -> GatewayProtocolContract:
    expected = load_contract(root / "config" / "GatewayProtocol.json")
    _expect_equal(protocol_from_gateway_version(root / "packages/gateway/src/version.ts"), expected, "Gateway source")

    deploy = _read(root / "scripts/gateway-payload-deploy.mjs")
    deploy_contract = GatewayProtocolContract(
        _exact_integer(deploy, r"^const PROTOCOL_VERSION\s*=\s*(\d+);$", "deployment helper protocol"),
        _exact_integer(deploy, r"^const MIN_PROTOCOL_VERSION\s*=\s*(\d+);$", "deployment helper minimum protocol"),
    )
    _expect_equal(deploy_contract, expected, "deployment helper")

    launcher = _read(root / "packages/mac-app/scripts/tron-gateway-launcher.c")
    launcher_contract = GatewayProtocolContract(
        _exact_integer(launcher, r'^#define TRON_GATEWAY_PROTOCOL_VERSION\s+"(\d+)"$', "launcher protocol"),
        _exact_integer(launcher, r'^#define TRON_GATEWAY_MIN_PROTOCOL_VERSION\s+"(\d+)"$', "launcher minimum protocol"),
    )
    _expect_equal(launcher_contract, expected, "Mac launcher")

    for path, label in (
        (root / "packages/ios-app/Sources/Gateway/GatewayProtocolContract.swift", "iOS"),
        (root / "packages/mac-app/Sources/Server/Health/GatewayProtocolContract.swift", "Mac"),
    ):
        source = _read(path)
        actual = GatewayProtocolContract(
            _exact_integer(source, r"^\s*static let protocolVersion\s*=\s*(\d+)\s*$", f"{label} protocol"),
            _exact_integer(source, r"^\s*static let minimumProtocolVersion\s*=\s*(\d+)\s*$", f"{label} minimum protocol"),
        )
        _expect_equal(actual, expected, f"{label} source")

    _expect_project_settings(root / "packages/ios-app/project.yml", expected)
    _expect_project_settings(root / "packages/mac-app/project.yml", expected)
    _expect_plist_placeholders(root / "packages/ios-app/Sources/Info.plist")
    _expect_plist_placeholders(root / "packages/mac-app/Sources/Info.plist")
    return expected


def _load_plist(path: Path) -> dict:
    if not _regular_file(path):
        raise ProtocolContractError(f"missing regular artifact plist: {path}")
    try:
        with path.open("rb") as handle:
            value = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as exc:
        raise ProtocolContractError(f"cannot decode artifact plist {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise ProtocolContractError(f"artifact plist is not a dictionary: {path}")
    return value


def _metadata_integer(info: dict, key: str) -> int:
    value = info.get(key)
    if type(value) is int:
        return value
    if isinstance(value, str) and re.fullmatch(r"[1-9][0-9]{0,4}", value):
        return int(value)
    raise ProtocolContractError(f"artifact {key} is missing or invalid")


def verify_app_info(info_path: Path, expected: GatewayProtocolContract, label: str) -> None:
    info = _load_plist(info_path)
    actual = GatewayProtocolContract(
        _metadata_integer(info, "TRONGatewayProtocolVersion"),
        _metadata_integer(info, "TRONGatewayMinProtocolVersion"),
    )
    _expect_equal(actual, expected, label)


def verify_ios_app(app: Path, expected: GatewayProtocolContract | None = None) -> GatewayProtocolContract:
    expected = expected or verify_source_contract()
    if not app.is_dir() or app.is_symlink() or app.suffix != ".app":
        raise ProtocolContractError(f"invalid iOS app bundle: {app}")
    verify_app_info(app / "Info.plist", expected, "iOS artifact")
    return expected


def verify_gateway_payload(payload: Path, expected: GatewayProtocolContract | None = None) -> GatewayProtocolContract:
    expected = expected or verify_source_contract()
    if not payload.is_dir() or payload.is_symlink():
        raise ProtocolContractError(f"invalid Gateway payload: {payload}")
    actual = protocol_from_gateway_version(payload / "app" / "dist" / "version.js")
    _expect_equal(actual, expected, "Gateway payload")
    manifest_path = payload / "manifest.json"
    if not _regular_file(manifest_path):
        raise ProtocolContractError(f"missing regular Gateway manifest: {manifest_path}")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ProtocolContractError(f"cannot decode Gateway manifest: {exc}") from exc
    if not isinstance(manifest, dict):
        raise ProtocolContractError("Gateway manifest is not an object")
    if manifest.get("protocolVersion") != str(expected.protocol_version) \
            or manifest.get("minProtocolVersion") != str(expected.min_protocol_version):
        raise ProtocolContractError("Gateway manifest protocol does not match canonical contract")
    return expected


def verify_mac_app(app: Path, expected: GatewayProtocolContract | None = None) -> GatewayProtocolContract:
    expected = expected or verify_source_contract()
    if not app.is_dir() or app.is_symlink() or app.suffix != ".app":
        raise ProtocolContractError(f"invalid Mac app bundle: {app}")
    verify_app_info(app / "Contents" / "Info.plist", expected, "Mac artifact")
    verify_gateway_payload(app / "Contents" / "Resources" / "Gateway", expected)
    return expected
