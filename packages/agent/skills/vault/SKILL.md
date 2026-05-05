---
name: "Vault"
description: "Store and retrieve credentials, API keys, SSH keys, and secrets — encrypted at rest with automatic key management. Use when user shares sensitive credentials, setting up integrations, or managing secrets."
version: "1.0.0"
tags: [credentials, secrets, vault, security, passwords, api-keys]
---

Encrypted credential store for Tron. Manages API keys, login passwords, SSH keys, and arbitrary secrets. All values are AES-256-CBC encrypted at rest with an auto-generated master key. No interactive authentication required.

## Script

```bash
~/.tron/skills/vault/scripts/vault.sh
```

## Preflight

On first use, validate the environment:

```bash
~/.tron/skills/vault/scripts/vault.sh preflight
```

This checks: `openssl` (AES-256-CBC + PBKDF2 support), `python3` (3.6+), `mktemp`, `uuidgen`, directory permissions, index integrity. Auto-repairs permissions if fixable. If it fails, follow the structured JSON error output.

To run the full validation suite:

```bash
~/.tron/skills/vault/scripts/vault.sh selftest
```

## Storage

```
~/.tron/workspace/vault/
  .master-key      # Auto-generated 256-bit key (0600)
  index.json       # Metadata only — names, types, tags (0600). NO secret values.
  entries/         # One encrypted file per credential (0700)
    <id>.enc       # AES-256-CBC encrypted JSON (0600)
```

## Commands

### Store a credential

```bash
# API key
~/.tron/skills/vault/scripts/vault.sh set github-pat \
  --type api_key \
  --desc "GitHub personal access token for CI" \
  --tags "github,ci" \
  --field token=ghp_xxxxxxxxxxxx

# Login credentials
~/.tron/skills/vault/scripts/vault.sh set prod-db \
  --type password \
  --desc "Production database" \
  --tags "database,prod" \
  --field username=admin \
  --field password='s3cr3t!'

# SSH key from file
~/.tron/skills/vault/scripts/vault.sh set deploy-key \
  --type ssh_key \
  --desc "Deploy SSH key" \
  --field-file private_key=/path/to/id_rsa

# Arbitrary secret
~/.tron/skills/vault/scripts/vault.sh set webhook-secret \
  --type secret \
  --field value=whsec_xxxxx
```

Output: `{"ok":true,"id":"v_abc123","name":"github-pat"}`

### Retrieve a credential

```bash
# Full entry (metadata + decrypted fields)
~/.tron/skills/vault/scripts/vault.sh get github-pat

# Single field — raw value, no JSON wrapping
~/.tron/skills/vault/scripts/vault.sh get github-pat --field token
# Output: ghp_xxxxxxxxxxxx
```

### Use a credential in a command

Pipe the raw field value directly — never echo secrets into chat:

```bash
curl -H "Authorization: Bearer $(~/.tron/skills/vault/scripts/vault.sh get github-pat --field token)" \
  https://api.github.com/user

# SSH with stored key
~/.tron/skills/vault/scripts/vault.sh get deploy-key --field private_key > /tmp/deploy_key && \
  chmod 600 /tmp/deploy_key && \
  ssh -i /tmp/deploy_key user@host && \
  rm -f /tmp/deploy_key
```

### List credentials

```bash
# All entries (metadata only, no secrets)
~/.tron/skills/vault/scripts/vault.sh list

# Filter by type
~/.tron/skills/vault/scripts/vault.sh list --type api_key

# Filter by tag
~/.tron/skills/vault/scripts/vault.sh list --tag prod
```

### Search

```bash
# Case-insensitive search across names, descriptions, tags
~/.tron/skills/vault/scripts/vault.sh search github
```

### Update a credential

```bash
# Change secret value
~/.tron/skills/vault/scripts/vault.sh update github-pat --field token=ghp_newtoken

# Change metadata
~/.tron/skills/vault/scripts/vault.sh update github-pat --desc "Rotated 2026-04" --tags "github,ci,rotated"

# Both at once
~/.tron/skills/vault/scripts/vault.sh update prod-db --field password=new_password --desc "Rotated Q2"
```

### Delete a credential

```bash
~/.tron/skills/vault/scripts/vault.sh delete old-api-key
```

### Rotate master key

Re-encrypts all entries with a fresh master key:

```bash
~/.tron/skills/vault/scripts/vault.sh rotate-key
```

## Credential Types

| Type | Required Fields | Optional Fields |
|------|----------------|-----------------|
| `api_key` | `token` | — |
| `password` | `username`, `password` | `url` |
| `ssh_key` | `private_key` | `public_key`, `passphrase` |
| `secret` | `value` | — |

## When to Use Vault

Proactively offer to store credentials when:

- User shares an API key, token, or password in conversation
- Setting up a new integration that needs authentication
- Discovering hardcoded secrets in source code
- User asks to "remember", "save", or "store" a credential
- Configuring CI/CD, deployment, webhooks, or external services
- User asks about managing secrets or passwords

## When NOT to Use Vault

- **Tron's own LLM provider tokens** — those belong in `~/.tron/profiles/auth.json`
- **Temporary session values** that expire within the conversation
- **Public configuration** — non-secret environment variables
- **User-managed .env files** — don't duplicate what the user already manages

## Security Rules

1. **Never print secret values in chat** unless the user explicitly asks to see them ("show me the password", "what's the token")
2. **Use `--field` extraction** for piping secrets into commands — this avoids exposing values in conversation output
3. **Never pass secrets as bare command arguments** visible in `ps` — prefer command substitution: `$(vault.sh get X --field token)`
4. **Confirm before displaying** if user asks to export or share a credential
5. **Warn about expiring credentials** — if a user mentions a token expires, note it in the description

## Error Recovery

| Situation | Action |
|-----------|--------|
| Preflight fails | Follow the structured JSON error — each check has a fix instruction |
| Decrypt fails | Entry may be corrupted. Offer to delete and re-create. Other entries are unaffected. |
| Index corrupted | Run `selftest` to diagnose. Worst case: rebuild by decrypting each `.enc` file |
| Master key missing | Existing entries are unrecoverable. Warn user, back up `entries/`, then re-init |
| Duplicate name | Use `update` to modify existing entries, not `set` |

## Cryptography

The vault is encrypted at rest with the following scheme. Run `vault.sh selftest` to verify the actual script matches this spec — the suite includes `key_derivation_matches_spec` which probes the implementation directly.

### Master key

```
openssl rand -hex 32  →  64 hex chars (256 bits of entropy from /dev/urandom)
```

Stored at `~/.tron/workspace/vault/.master-key` with mode `0600`. A single master key protects every entry in the vault. Losing or deleting this file makes every `.enc` file unrecoverable — back it up if the secrets inside are not reproducible.

The master key is the passphrase input to the per-entry key derivation below. It is NOT the AES key directly; it is a high-entropy password that gets stretched through PBKDF2 for each encryption.

### Per-entry key derivation (PBKDF2)

Every `set`/`update`/`rotate-key` call runs:

```
openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -pass file:.master-key
```

Which means:

- **KDF:** PBKDF2-HMAC-SHA256 (openssl's default for `-pbkdf2`)
- **Iterations:** 100 000 (OWASP floor for SHA-256 as of 2023)
- **Salt:** 8 random bytes, generated fresh per encryption and prepended to the ciphertext (openssl `Salted__` framing)
- **Derived material:** 48 bytes — 32-byte AES-256 key + 16-byte CBC IV
- **Cipher:** AES-256-CBC with PKCS#7 padding

Because the salt is fresh per call, encrypting the same plaintext twice produces two different ciphertexts — the regression test `key_derivation_matches_spec` asserts this.

### Trust boundary

The vault's security rests on two assumptions:

1. **Filesystem-level access control** on `~/.tron/workspace/vault/`. An attacker who can read `.master-key` can decrypt everything. Mode `0600` + `0700` on the containing directories is the only barrier; the preflight auto-repairs permissions if they drift.
2. **Local-only threat model** (see root README). The vault is not designed to resist an attacker with root on the machine; it is designed to resist casual inspection (e.g., the file sitting in a backup, another process reading `/tmp`, a shoulder-surfer glancing at the terminal).

If those assumptions fail, the vault fails. Use a hardware-backed keystore for harder threats.

### Key rotation

`vault.sh rotate-key` generates a new master key and re-encrypts every `.enc` file in place. The old key is NOT retained — if the re-encryption loop fails midway, the script aborts with the old key still in place and no files modified. See `rotate_key: re-encrypt all entries, still readable` in `selftest`.

## Gotchas
