"""One-time setup and status of the agents' GitHub token (#1168); `gh.py` owns its use."""
from __future__ import annotations

import getpass
import json
import sys

from gh import GhError, REQUIRED_SCOPES, check_token, keychain_token, resolve_gh, store_keychain_token

TOKEN_URL = ("https://github.com/settings/tokens/new?scopes=" + ",".join(REQUIRED_SCOPES)
             + "&description=Tron%20agents")


def setup() -> int:
    """The maintainer's single interactive step: paste a classic token once; agents use it from then on."""
    if not sys.stdin.isatty():
        raise GhError("auth setup needs an interactive terminal")
    binary = resolve_gh()
    print("Create a classic GitHub token for Tron's agents (scopes " + ", ".join(REQUIRED_SCOPES) + ") at:")
    print(f"  {TOKEN_URL}")
    print("Pick any expiry; work warns 14 days before it ends. Paste it below; it is stored only in your login Keychain.")
    token = getpass.getpass("Token (hidden): ").strip()
    if not token:
        raise GhError("no token entered; nothing changed")
    checked = check_token(binary, token)
    store_keychain_token(token, checked["login"] or "agents")
    # The stored item, read back the way every agent reads it, is the proof.
    stored = keychain_token()
    if stored != token:
        raise GhError("Keychain did not return the token it stored")
    print(f"Agents now reach GitHub as {checked['login']} with {', '.join(checked['scopes'])}"
          + (f"; the token expires {checked['expiresAt']}" if checked.get("expiresAt") else "") + ".")
    return 0


def status() -> int:
    """Non-secret state of the agent token: who, which scopes and when it expires."""
    token = keychain_token()
    if not token:
        raise GhError("GitHub access for agents is not set up; run once in Terminal: scripts/tron work auth setup")
    print(json.dumps({"source": "keychain", **check_token(resolve_gh(), token)}, sort_keys=True))
    return 0
