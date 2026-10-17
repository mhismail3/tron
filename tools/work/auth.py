"""One-time setup and status of the agents' GitHub token (#1168); `gh.py` owns its use."""
from __future__ import annotations

import getpass
import json
import subprocess
import sys

from gh import (GhError, KeychainLocked, REQUIRED_SCOPES, SECURITY, check_token, keychain_paths, keychain_token,
                resolve_gh, store_keychain_token)

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
    account = checked["login"] or "agents"
    try:
        store_keychain_token(token, account)
    except KeychainLocked:
        # A shell outside the login GUI session (SSH, a detached tmux) sees the login keychain
        # locked. `security` asks for the macOS login password itself; nothing here reads it.
        print("Your login keychain is locked in this shell; enter your macOS login password at the next prompt.")
        if subprocess.run([SECURITY, "unlock-keychain", *keychain_paths()]).returncode:
            raise GhError("the login keychain stayed locked; nothing changed")
        store_keychain_token(token, account)
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
