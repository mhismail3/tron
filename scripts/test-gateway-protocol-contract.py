#!/usr/bin/env python3
from __future__ import annotations

import json
import plistlib
import tempfile
import unittest
from pathlib import Path

from gateway_protocol_contract import (
    ProtocolContractError,
    load_contract,
    verify_gateway_payload,
    verify_ios_app,
    verify_mac_app,
)


class GatewayProtocolContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.contract = load_contract()
        self.temporary = tempfile.TemporaryDirectory(prefix="tron-protocol-contract-")
        self.root = Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_info(self, path: Path, protocol: str = "4", minimum: str = "4") -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("wb") as handle:
            plistlib.dump({
                "TRONGatewayProtocolVersion": protocol,
                "TRONGatewayMinProtocolVersion": minimum,
            }, handle)

    def make_payload(self, path: Path, protocol: str = "4", minimum: str = "4") -> None:
        version = path / "app" / "dist" / "version.js"
        version.parent.mkdir(parents=True, exist_ok=True)
        version.write_text(
            f"export const PROTOCOL_VERSION = {protocol};\n"
            f"export const MIN_PROTOCOL_VERSION = {minimum};\n",
            encoding="utf-8",
        )
        (path / "manifest.json").write_text(json.dumps({
            "protocolVersion": protocol,
            "minProtocolVersion": minimum,
        }), encoding="utf-8")

    def test_ios_artifact_metadata_matches_canonical_contract(self) -> None:
        app = self.root / "TronMobile.app"
        app.mkdir()
        self.write_info(app / "Info.plist")
        self.assertEqual(verify_ios_app(app, self.contract), self.contract)
        self.write_info(app / "Info.plist", protocol="3", minimum="3")
        with self.assertRaisesRegex(ProtocolContractError, "does not match canonical"):
            verify_ios_app(app, self.contract)

    def test_gateway_payload_requires_source_and_manifest_agreement(self) -> None:
        payload = self.root / "Gateway"
        payload.mkdir()
        self.make_payload(payload)
        self.assertEqual(verify_gateway_payload(payload, self.contract), self.contract)
        manifest = json.loads((payload / "manifest.json").read_text(encoding="utf-8"))
        manifest["protocolVersion"] = "3"
        (payload / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
        with self.assertRaisesRegex(ProtocolContractError, "Gateway manifest"):
            verify_gateway_payload(payload, self.contract)

    def test_mac_artifact_binds_wrapper_metadata_to_bundled_gateway(self) -> None:
        app = self.root / "Tron.app"
        self.write_info(app / "Contents" / "Info.plist")
        self.make_payload(app / "Contents" / "Resources" / "Gateway")
        self.assertEqual(verify_mac_app(app, self.contract), self.contract)
        version = app / "Contents" / "Resources" / "Gateway" / "app" / "dist" / "version.js"
        version.write_text(
            "export const PROTOCOL_VERSION = 3;\nexport const MIN_PROTOCOL_VERSION = 3;\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(ProtocolContractError, "Gateway payload"):
            verify_mac_app(app, self.contract)


if __name__ == "__main__":
    unittest.main()
