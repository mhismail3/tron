#!/usr/bin/env python3
"""Fail-closed source and artifact verifier for Tron's Gateway protocol."""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

from gateway_protocol_contract import (
    ProtocolContractError,
    verify_gateway_payload,
    verify_ios_app,
    verify_mac_app,
    verify_source_contract,
)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ios-app", type=Path)
    parser.add_argument("--mac-app", type=Path)
    parser.add_argument("--gateway-payload", type=Path)
    args = parser.parse_args()
    try:
        contract = verify_source_contract()
        if args.ios_app:
            verify_ios_app(args.ios_app, contract)
        if args.mac_app:
            verify_mac_app(args.mac_app, contract)
        if args.gateway_payload:
            verify_gateway_payload(args.gateway_payload, contract)
    except ProtocolContractError as exc:
        print(f"Gateway protocol verification failed: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
    targets = [
        name for name, value in (
            ("source", True),
            ("iOS artifact", args.ios_app),
            ("Mac artifact", args.mac_app),
            ("Gateway payload", args.gateway_payload),
        ) if value
    ]
    print(
        f"verified Gateway protocol v{contract.protocol_version} "
        f"(minimum v{contract.min_protocol_version}) across {', '.join(targets)}"
    )


if __name__ == "__main__":
    main()
