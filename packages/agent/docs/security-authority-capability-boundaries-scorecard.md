# Security Authority Capability Boundaries Scorecard

Created: 2026-06-10

Initial score: **0/100**

Current score: **61/100**

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
| SACB-1 | Whole-repo security boundary inventory for Rust, iOS, Mac, scripts, docs | 10 | passed_after_fix | inventory/static gates | Expanded the inventory to 601 marker-derived rows across server, iOS, Mac, scripts, workflows, active docs, historical scorecards, TSV evidence, and tests. Static gates now recompute tracked security-marker files and require every one to have a structured inventory row. | Closed. | SACB-1 boundary inventory checkpoint |
| SACB-2 | Public transport auth, route exposure, bearer handling, loopback worker boundary | 10 | passed_after_fix | transport/http/runtime | Added focused server tests proving `/engine/workers` requires bearer auth, allows bearer-authenticated loopback upgrades, and rejects non-loopback worker peers with `403` through the extracted peer guard. Added static guards proving `/engine` and `/engine/workers` stay wired through `ws_auth_gate`, bearer parsing stays strict, and the worker handler keeps `ConnectInfo<SocketAddr>` plus `is_loopback()`. | Closed. | SACB-2 public transport boundary checkpoint |
| SACB-3 | Transport context trust: remove/deny untrusted authority scope and runtime metadata injection | 14 | passed_after_fix | transport/engine | Deleted public `authorityScopes` and `runtimeMetadata` fields from `WireContext` and `EngineTransportContext`, removed the transport copy loops into `CausalContext`, removed silent top-level `authorityScopes` stripping, inverted the socket DTO tests to reject those fields, and added static guards against field/copy-loop reintroduction. README now documents that public wire context carries only identity and correlation scope. | Closed. | SACB-3 public context trust checkpoint |
| SACB-4 | Authority grant model: derivation, file roots, network policy, budgets, bootstrap grants | 12 | passed_after_fix | engine/authority | Added shared canonical grant file-root helpers, changed child grant derivation from raw string-prefix checks to canonical path containment with unresolved suffix normalization, added prefix-sibling and parent-component escape regression tests, proved network policy and budget narrowing through existing derivation cases, and added explicit bootstrap root-grant proof plus static guards for wildcard bootstrap provenance. Updated ownership/cleanup/modularity/SOL/SACB inventories for the new helper. | Closed. | SACB-4 authority grant boundary checkpoint |
| SACB-5 | Catalog visibility and direct invocation boundaries, including `engine::invoke` delegation | 10 | passed_after_fix | engine/catalog/invocation | Tightened `engine.internal.invoke` so raw scope strings unlock internal visibility only for trusted runtime actor kinds, made hidden agent prompt/apply delegation reset to an engine-owned system causal context, added public `engine::invoke` regressions for internal/admin/worker-only targets and raw internal-scope denial, and added transport/static guards proving public `/engine` never mints the internal scope. | Closed. | SACB-5 catalog visibility/direct invocation checkpoint |
| SACB-6 | `capability::execute` least privilege for file/process/state/trace/log/replay operations | 12 | pending | domains/capability | Not started in this checkpoint. | Open: execute root, process, state, trace, log, replay least-privilege proof. | pending |
| SACB-7 | External worker protocol isolation: scoped token, namespace, trigger, stream, result ownership | 8 | pending | engine/runtime/transport | Not started in this checkpoint. | Open: worker token, namespace, trigger, stream, and result ownership proof. | pending |
| SACB-8 | Secrets, token storage, redaction, auth.json permissions, provider credential custody | 7 | pending | auth/iOS/Mac diagnostics | Not started in this checkpoint. | Open: redaction, auth.json mode, provider custody proof. | pending |
| SACB-9 | iOS/Mac pairing lifecycle: Keychain, QR/deep-link parsing, forget/re-pair/unauthorized flow | 7 | pending | iOS/Mac pairing | Not started in this checkpoint. | Open: pairing lifecycle and unauthorized flow proof. | pending |
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
