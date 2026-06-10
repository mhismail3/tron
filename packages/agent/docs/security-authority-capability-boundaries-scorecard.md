# Security Authority Capability Boundaries Scorecard

Created: 2026-06-10

Initial score: **0/100**

Current score: **25/100**

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
| SACB-3 | Transport context trust: remove/deny untrusted authority scope and runtime metadata injection | 14 | pending | transport/engine | Not started in this checkpoint. | Open: public wire DTOs still require hardening against authority/runtime metadata injection. | pending |
| SACB-4 | Authority grant model: derivation, file roots, network policy, budgets, bootstrap grants | 12 | pending | engine/authority | Not started in this checkpoint. | Open: canonical file-root derivation and network-policy proof. | pending |
| SACB-5 | Catalog visibility and direct invocation boundaries, including `engine::invoke` delegation | 10 | pending | engine/catalog/invocation | Not started in this checkpoint. | Open: direct invocation and internal visibility proof. | pending |
| SACB-6 | `capability::execute` least privilege for file/process/state/trace/log/replay operations | 12 | pending | domains/capability | Not started in this checkpoint. | Open: execute root, process, state, trace, log, replay least-privilege proof. | pending |
| SACB-7 | External worker protocol isolation: scoped token, namespace, trigger, stream, result ownership | 8 | pending | engine/runtime/transport | Not started in this checkpoint. | Open: worker token, namespace, trigger, stream, and result ownership proof. | pending |
| SACB-8 | Secrets, token storage, redaction, auth.json permissions, provider credential custody | 7 | pending | auth/iOS/Mac diagnostics | Not started in this checkpoint. | Open: redaction, auth.json mode, provider custody proof. | pending |
| SACB-9 | iOS/Mac pairing lifecycle: Keychain, QR/deep-link parsing, forget/re-pair/unauthorized flow | 7 | pending | iOS/Mac pairing | Not started in this checkpoint. | Open: pairing lifecycle and unauthorized flow proof. | pending |
| SACB-10 | Final closeout, static gates, full verification, clean status | 5 | pending | static gates/verification | Not started in this checkpoint. | Open: final full verification and no stale open-loop wording. | pending |

Total weight: **100**

## Initial Findings

- Public `/engine` `WireContext` currently accepts `authorityScopes` and
  `runtimeMetadata`, and the transport copies both into `CausalContext`.
- `RUNTIME_METADATA_WORKING_DIRECTORY` affects primitive file and process roots.
- Grant derivation currently narrows child file roots with string-prefix
  comparison; invocation authorization uses canonical path containment.
- Bootstrap grants include wildcard capabilities, namespaces, scopes, resources,
  file roots, network policy, and delegation. Each use must be inventoried and
  proved as engine-owned rather than public-callable permission data.

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
