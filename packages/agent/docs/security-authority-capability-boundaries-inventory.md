# Security Authority Capability Boundaries Inventory

Status: SACB-1 `passed_after_fix`; 603 security boundary rows inventoried and
classified across tracked Rust, Swift, scripts, workflows, docs, and tests.

Machine-readable inventory:
[`security-authority-capability-boundaries-inventory.tsv`](security-authority-capability-boundaries-inventory.tsv)

## Boundary Classes

- `public_transport`: externally reachable protocol routes, request DTOs,
  bearer checks, and route exposure.
- `authority_grant`: grant creation, derivation, authorization, bootstrap, and
  authority-scope handling.
- `runtime_metadata`: metadata that affects file roots, trace identity,
  provider ownership, trigger cascade bounds, or queue/runtime behavior.
- `execute_primitive`: file, process, state, trace, log, replay, and model
  primitive operation boundary.
- `external_worker`: loopback worker identity, scoped token, trigger, stream,
  and result ownership.
- `secret_storage`: bearer/API/OAuth token custody, auth file mode, Keychain,
  UserDefaults, logs, diagnostics, and redaction.
- `pairing_lifecycle`: iOS/Mac pairing parse, persist, forget, re-pair, rotate,
  and unauthorized flows.
- `static_gate`: docs, test, CI, and inventory gates that preserve the campaign.

## Coverage Policy

SACB-1 uses marker-driven coverage. The invariant target scans tracked files
under `packages/agent/`, `packages/ios-app/`, `packages/mac-app/`, `scripts/`,
`.github/`, and root project docs for security markers such as bearer auth,
provider credentials, `auth.json`, Keychain/UserDefaults custody, `/engine`,
worker routes, authority grants, runtime metadata, primitive file/process
operations, network policy, diagnostics redaction, OAuth, pairing URLs, QR
payloads, and loopback boundaries.

The only marker exclusions are non-security token-accounting and model-catalog
surfaces where the word "token" describes model usage or pricing rather than
auth/custody. Any future tracked security-marker file must be added to the TSV
or the SACB invariant target fails.

## Open Loops

- SACB-8: prove secrets, redaction, auth.json permissions, and provider custody.
- SACB-9: prove pairing lifecycle and unauthorized flow.
- SACB-10: run final closeout and remove stale active-state wording.
