# Security Authority Capability Boundaries Scorecard

Created: 2026-06-10

Initial score: **0/100**

Current score: **95/100**

Status: **active**

Branch: `codex/primitive-engine-teardown`

Evidence manifest:
[`security-authority-capability-boundaries-evidence-manifest.md`](security-authority-capability-boundaries-evidence-manifest.md)

Inventory:
[`security-authority-capability-boundaries-inventory.md`](security-authority-capability-boundaries-inventory.md)
and
[`security-authority-capability-boundaries-inventory.tsv`](security-authority-capability-boundaries-inventory.tsv)

Invariant target:
[`../tests/security_authority_capability_boundaries_invariants.rs`](../tests/security_authority_capability_boundaries_invariants.rs)
with focused modules under
[`../tests/security_authority_capability_boundaries/`](../tests/security_authority_capability_boundaries/)

## Scope

This campaign proves that Tron security, authority, and capability boundaries
fail closed across public `/engine` transport, external workers, engine grants,
primitive `capability::execute`, secrets, redaction, and iOS/Mac pairing.

The campaign is intentionally compatibility-breaking where the old protocol
trusted authority-bearing caller context. Public callers must authenticate, but
authentication alone never lets them mint authority scopes, runtime metadata,
file roots, worker identity, or credential custody.

## Non-Negotiable Direction

- Delete unsafe public wire fields instead of retaining fallback aliases.
- Treat caller-supplied authority labels as audit context only when the caller is
  a trusted engine-owned path; public transports must not accept them.
- Runtime metadata that affects file/process roots must be produced by trusted
  server/agent context, not by public `/engine` clients.
- Grants must narrow by canonical path containment, network policy, budgets,
  actor/worker subjects, and resource selectors.
- Direct invocation through `engine::invoke` must not bypass catalog visibility
  or internal/admin/worker-only function constraints.
- Secrets and bearer/API/OAuth tokens must stay out of UserDefaults, logs,
  diagnostics, protocol JSON, and paired-server metadata.

## Scenario Ledger

| Row | Requirement | Points | Status | Owner | Evidence | Closure | Checkpoint |
|---|---|---:|---|---|---|---|---|
| SACB-0 | Campaign harness, red gates, README/CI links, evidence/inventory scaffolding | 5 | passed_after_fix | docs/static gates | Added SACB scorecard, evidence manifest, inventory docs/TSV, invariant target, README links, CI/static-gate wiring, and prior-campaign inventory rows for the new artifacts. | Closed. | SACB-0 campaign harness checkpoint |
| SACB-1 | Whole-repo security boundary inventory for Rust, iOS, Mac, scripts, docs | 10 | passed_after_fix | inventory/static gates | Expanded the inventory to marker-derived coverage across server, iOS, Mac, scripts, workflows, active docs, historical scorecards, TSV evidence, and tests; current coverage is 603 structured rows. Static gates now recompute tracked security-marker files and require every one to have a structured inventory row. | Closed. | SACB-1 boundary inventory checkpoint |
| SACB-2 | Public transport auth, route exposure, bearer handling, loopback worker boundary | 10 | passed_after_fix | transport/http/runtime | Added focused server tests proving `/engine/workers` requires bearer auth, allows bearer-authenticated loopback upgrades, and rejects non-loopback worker peers with `403` through the extracted peer guard. Added static guards proving `/engine` and `/engine/workers` stay wired through `ws_auth_gate`, bearer parsing stays strict, and the worker handler keeps `ConnectInfo<SocketAddr>` plus `is_loopback()`. | Closed. | SACB-2 public transport boundary checkpoint |
| SACB-3 | Transport context trust: remove/deny untrusted authority scope and runtime metadata injection | 14 | passed_after_fix | transport/engine | Deleted public `authorityScopes` and `runtimeMetadata` fields from `WireContext` and `EngineTransportContext`, removed the transport copy loops into `CausalContext`, removed silent top-level `authorityScopes` stripping, inverted the socket DTO tests to reject those fields, and added static guards against field/copy-loop reintroduction. README now documents that public wire context carries only identity and correlation scope. | Closed. | SACB-3 public context trust checkpoint |
| SACB-4 | Authority grant model: derivation, file roots, network policy, budgets, bootstrap grants | 12 | passed_after_fix | engine/authority | Added shared canonical grant file-root helpers, changed child grant derivation from raw string-prefix checks to canonical path containment with unresolved suffix normalization, added prefix-sibling and parent-component escape regression tests, proved network policy and budget narrowing through existing derivation cases, and added explicit bootstrap root-grant proof plus static guards for wildcard bootstrap provenance. Updated ownership/cleanup/modularity/SOL/SACB inventories for the new helper. | Closed. | SACB-4 authority grant boundary checkpoint |
| SACB-5 | Catalog visibility and direct invocation boundaries, including `engine::invoke` delegation | 10 | passed_after_fix | engine/catalog/invocation | Tightened `engine.internal.invoke` so raw scope strings unlock internal visibility only for trusted runtime actor kinds, made hidden agent prompt/apply delegation reset to an engine-owned system causal context, added public `engine::invoke` regressions for internal/admin/worker-only targets and raw internal-scope denial, and added transport/static guards proving public `/engine` never mints the internal scope. | Closed. | SACB-5 catalog visibility/direct invocation checkpoint |
| SACB-6 | `capability::execute` least privilege for file/process/state/trace/log/replay operations | 12 | passed_after_fix | domains/capability | Agent-launched primitive calls derive a per-call child grant from `agent-capability-runtime` with the exact target function, canonical working-directory file root, no namespace authority, state read/write support, and `networkPolicy: none`; the execute worker rejects bootstrap grants and non-agent/non-system callers, resolves file roots from trusted runtime metadata only, denies system state scope, requires current-session context for trace/log/replay reads, and runs `process_run` only under a grant inspected as `networkPolicy none` with a fail-closed network-denial sandbox. | Closed. | SACB-6 capability execute least-privilege checkpoint |
| SACB-7 | External worker protocol isolation: scoped token, namespace, trigger, stream, result ownership | 8 | passed_after_fix | engine/runtime/transport | External worker hellos now require loopback bearer auth, `WorkerKind::External`, active grant/revision validation, matching grant subjects, session/workspace token bindings for visible workers, non-wildcard stream selectors, and strict namespace segment matching instead of substring matching. Function metadata, trigger ids/targets, trigger authority grants, stream visibility, stream session/workspace scope, and stream topics are all checked against the accepted connection and token. Socket invocation results remain owned by the per-connection pending map and disconnect/backpressure paths fail pending calls with worker transport failures. | Closed. | SACB-7 external worker protocol isolation checkpoint |
| SACB-8 | Secrets, token storage, redaction, auth.json permissions, provider credential custody | 7 | passed_after_fix | auth/iOS/Mac diagnostics | `auth.json` writes remain atomic `0o600` through the auth credential store, bearer-token creation/rotation materializes only the pristine `{}` sentinel and refuses malformed non-empty files, model providers consume ephemeral credential copies, server event/log redaction now covers JSON and debug-description OAuth/API-key fields, `logs::ingest` redacts before durable storage, iOS paired-server metadata stays token-free in UserDefaults while bearer tokens stay in Keychain, and Mac diagnostics redaction is aligned with iOS for camelCase and Swift-description auth fields. | Closed. | SACB-8 secret custody and redaction checkpoint |
| SACB-9 | iOS/Mac pairing lifecycle: Keychain, QR/deep-link parsing, forget/re-pair/unauthorized flow | 7 | passed_after_fix | iOS/Mac pairing | iOS QR/deep-link parsing and manual validation now share a strict bare-host validator that accepts DNS, IPv4, and unbracketed IPv6 while rejecting full URLs, paths, query strings, userinfo, bracketed hosts, malformed IPs, and malformed DNS labels; Mac QR building/parsing uses the same host and `1...65535` port contract. Pairing persistence canonicalizes direct payloads and treats invalid internal hosts as programmer errors instead of carrying a fallback, rollback is an explicit pure plan that restores the previous token or removes the candidate token, and forgetting a server removes the Keychain token before metadata and throws instead of swallowing failures. Unauthorized transport state remains parked until the re-pair flow writes a fresh token. | Closed. | SACB-9 pairing lifecycle checkpoint |
| SACB-10 | Final closeout, static gates, full verification, clean status | 5 | pending | static gates/verification | Not started in this checkpoint. | Open: final full verification and no stale open-loop wording. | pending |

Total weight: **100**

## Initial Findings

- SACB-3 baseline found public `/engine` `WireContext` accepting
  `authorityScopes` and `runtimeMetadata`; the closed checkpoint deletes those
  fields and rejects them through `deny_unknown_fields`.
- `RUNTIME_METADATA_WORKING_DIRECTORY` affects primitive file and process roots.
- SACB-4 baseline found grant derivation narrowing child file roots with raw
  string-prefix comparison; the closed checkpoint uses shared canonical path
  containment plus unresolved suffix normalization for derivation and invocation
  authorization.
- SACB-4 explicitly proves bootstrap grants are engine-owned wildcard roots
  with `engine.bootstrap` provenance, not public-callable permission data.
- SACB-5 closed the direct invocation gap by denying raw public
  `engine.internal.invoke` scope strings and proving public `engine::invoke`
  cannot reach internal, admin, or worker-only targets.
- SACB-6 closed the primitive execution gap by deriving scoped runtime grants
  for model-launched calls, rejecting bootstrap grants at `capability::execute`,
  removing process-cwd fallback, enforcing canonical root authorization from
  trusted runtime metadata, denying system-scoped state, requiring current
  session context for trace/log/replay reads, and fail-closing `process_run`
  unless its inspected grant has `networkPolicy none`.
- SACB-7 closed external-worker isolation gaps by requiring accepted worker
  tokens to bind visible workers to session/workspace scope, validating active
  grant revision and subject bindings, replacing substring namespace matching
  with segment/prefix matching, and denying trigger/stream registrations that
  target another worker or publish outside the scoped token selectors.
- SACB-8 closed secret-custody gaps by keeping `auth.json` atomic and `0o600`,
  routing bearer-token lifecycle through the credential store, redacting
  OAuth/API-key fields before event/log storage, proving iOS bearer tokens stay
  in Keychain rather than paired-server metadata/UserDefaults, and aligning Mac
  diagnostics redaction with iOS.
- SACB-9 closed pairing lifecycle gaps by rejecting URL-shaped host input on
  iOS and Mac, making pairing rollback/forget token side effects explicit and
  non-silent, and proving re-pair/unauthorized behavior through focused iOS/Mac
  tests and static guards.

## Static Gates

`packages/agent/tests/security_authority_capability_boundaries_invariants.rs`
and its focused modules enforce the SACB harness and SACB-1 inventory coverage
now, and will own row-specific guards as later rows close:

- Scorecard row weights sum to 100.
- Current score equals the sum of `passed_after_fix` row weights.
- README links all SACB artifacts and the invariant target.
- Local and GitHub closeout target lists include the SACB invariant target.
- Inventory TSV rows are structured, use the SACB header, point at existing
  tracked files, and reference SACB rows.
- Every tracked Rust, Swift, script, workflow, and docs file with security
  markers is covered by the SACB inventory unless it is an explicitly excluded
  non-security token-accounting/model-catalog surface.
- Inventory rows cover public transport, authority grants, runtime metadata,
  primitive execution, external workers, secret storage, pairing lifecycle, and
  static gates.
- `capability::execute` static guards require per-call grant derivation,
  trusted working-directory metadata, bootstrap-grant rejection, process
  network denial, and state/trace/log/replay scope checks.
- External-worker static guards require active scoped-token grant checks,
  strict namespace matching, trigger target ownership, scoped stream publishing,
  and per-socket pending result ownership.
- Secret-storage static guards require atomic `0o600` `auth.json` writes,
  bearer-token lifecycle through the auth store, server-side log/event
  redaction, iOS Keychain-only bearer custody, token-free paired-server
  metadata, and Mac/iOS diagnostics redaction parity.
- Pairing lifecycle static guards require strict iOS/Mac host validation,
  QR/deep-link/manual parser parity, explicit rollback token actions,
  fail-closed Keychain deletion before paired-server metadata removal, and
  focused iOS/Mac regression tests.
- Final closeout rejects stale active/open-loop wording once the scorecard is
  complete.

## Verification Commands

Focused SACB target:

```bash
cargo test --manifest-path packages/agent/Cargo.toml --test security_authority_capability_boundaries_invariants -- --nocapture
```

Required final closeout:

```bash
scripts/tron ci fmt check clippy test
scripts/personal-info-guard.sh
cd packages/ios-app && xcodegen generate && cd ../..
git diff --exit-code -- packages/ios-app/TronMobile.xcodeproj
git diff --check
git ls-files -ci --exclude-standard
git status --short
```
