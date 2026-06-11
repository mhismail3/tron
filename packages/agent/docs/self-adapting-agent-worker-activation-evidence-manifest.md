# Self-Adapting Agent Worker Activation Evidence Manifest

Branch: `codex/self-adapting-agent-worker-activation`
Baseline commit: `4b530e014 Harden promotion governance`
Status: **complete**

## Baseline Evidence

- Checkout started from SAPG closeout commit `4b530e014 Harden promotion
  governance`.
- SAPG was treated as closed baseline evidence: its branch had already validated
  promotion governance, SAA/SACB invariants, primitive trace, integration, full
  local CI, personal-info guard, whitespace, and clean post-commit status.
- The `@self-inspect` skill referenced by project instructions was not available
  in the active skill/tool set for this delegated thread, matching prior
  recorded closeout conditions. Source inspection used `rg`, direct file reads,
  focused runtime tests, and static invariants instead.
- No `tron deploy` or production deployment command is run by this slice.

## Row Evidence

| Row | Status | Evidence | Verification | Residual Risk | Commit |
|---|---|---|---|---|---|
| SAAWA-0 | passed_after_fix | Added scorecard, evidence manifest, inventory markdown/TSV, README links, and local/GitHub closeout target wiring. | Static invariant checks docs, README, and CI target wiring. | Closed. | this slice |
| SAAWA-1 | passed_after_fix | Inventory covers worker primitives, activation modules, governance validator, resource definitions, scoped token, grant derivation, external-worker lifecycle/registration/proxy, stream lifecycle, tests, and transport boundaries. | TSV parser and required-path static gates validate coverage. | New activation-adjacent files must be added to inventory. | this slice |
| SAAWA-2 | passed_after_fix | `worker_activation` is a built-in resource type with strict payload fields, lifecycle statuses, expected function definition, scope, refs, token fingerprint, loopback network policy, and volatile registration mode. | Focused issuance test inspects resource payload and static invariant checks schema/status markers. | Schema validates shape; semantic linkage is enforced by activation validator. | this slice |
| SAAWA-3 | passed_after_fix | `worker_activation_governance` validates reviewed capability-definition candidates, final accepted decisions, accepted verified evidence, scope compatibility, matching function/visibility, and linked chains. | Invalid activation tests cover empty/duplicate refs, wrong kind, unverified evidence, non-final decision, mismatched function, and system target rejection. | Governance helper mirrors SAPG semantics instead of sharing one generic library to avoid broad refactor risk in this slice. | this slice |
| SAAWA-4 | passed_after_fix | Activation grants derive from `worker-runtime`, bind subject actor/worker, deny delegation, use loopback network policy, expire within 24h, allow only target function plus `stream::publish`, and avoid wildcard worker selectors. | Valid issuance test inspects grant fields; static gates keep agent runtime grants from gaining worker activation/write/register/trigger authority. | Resource selector still names only the stream selector needed by worker publishing. | this slice |
| SAAWA-5 | passed_after_fix | `ScopedWorkerToken` carries activation resource and governance fingerprint metadata; hello and registration paths validate token, grant, resource, namespace, scope, metadata, and expected function contract. | Runtime tests reject wrong activation id, durable/system scope attempts, namespace/session/wildcard tampering, wrong function id/owner/metadata/schemas, extra function registration, and trigger registration. | Wrong owner fails earlier as no connected worker, which is the correct fail-closed boundary. | this slice |
| SAAWA-6 | passed_after_fix | Runtime updates activation resources to connected, registered, disconnected, expired, or revoked while existing `worker.lifecycle` stream events remain the audit stream. | End-to-end runtime test checks connected/registered/disconnected resource states and connected/function_registered/disconnected/unregistered lifecycle events; revoked grant test updates resource to revoked. | Expiry is checked on hello/registration rather than by a background scheduler. | this slice |
| SAAWA-7 | passed_after_fix | Activation functions remain undiscoverable before registration, invoke through `ExternalFunctionProxyHandler` after registration, and volatile disconnect unregisters function entries. | End-to-end runtime test invokes through `EchoExternalInvoker` and verifies disconnect removes the function. | No durable activation registration is supported in v1. | this slice |
| SAAWA-8 | passed_after_fix | Activation code does not include process spawn, deploy, scheduler, autolaunch, repo-managed skills, provider-visible tools, or public `/engine` activation methods. | Static invariant scans activation source and public/provider surfaces. | Future worker-launch slices need a new scorecard and threat model. | this slice |
| SAAWA-9 | passed_after_fix | Cross-campaign invariant and integration targets stay in the closeout set. | Verification log records SAA, SAPG, SACB, primitive trace, external-worker, and integration runs. | Closed for this slice. | this slice |
| SAAWA-10 | passed_after_fix | Code, tests, docs, evidence, inventory, README updates, closeout validation, clean status, and commit are delivered together. | Verification log below records focused and full checks. | Closed. | this slice |

## Verification Log

| Command | Result | Notes |
|---|---|---|
| `cargo test --manifest-path packages/agent/Cargo.toml worker_activation --lib -- --nocapture` | passed | Focused activation issuance and runtime binding tests passed: 5 tests. |
| `cargo test --manifest-path packages/agent/Cargo.toml external_worker --lib -- --nocapture` | passed | External-worker regression target passed: 26 tests. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test self_adapting_agent_worker_activation_invariants -- --nocapture` | passed | SAAWA static target passed: 7 tests. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test self_adapting_agent_promotion_governance_invariants -- --nocapture` | passed | SAPG regression target passed: 6 tests. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test self_adapting_agent_authorship_invariants -- --nocapture` | passed | SAA regression target passed: 15 tests. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test security_authority_capability_boundaries_invariants -- --nocapture` | passed_after_fix | SACB regression target passed: 17 tests after adding staged SAAWA security-marker rows to the SACB inventory. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_trace_execution -- --nocapture` | passed | Primitive trace/replay regression target passed: 8 tests. |
| `cargo test --manifest-path packages/agent/Cargo.toml --test integration -- --nocapture` | passed | Serial integration target passed: 2 tests. |
| `scripts/tron ci fmt check clippy test` | passed | Full local Rust CI passed: fmt, check, clippy, and test. |
| `scripts/personal-info-guard.sh` | passed | Personal-info literal guard passed with no leaks. |
| `cd packages/ios-app && xcodegen generate && cd ../.. && git diff --exit-code -- packages/ios-app/TronMobile.xcodeproj` | passed | XcodeGen regenerated project with no project drift. |
| `git diff --check` | passed | Whitespace check passed. |
| `git ls-files -ci --exclude-standard` | passed | Ignored-files check returned no tracked ignored files. |
| `git status --short` | pending_after_commit | Final clean state is verified after committing the staged slice. |

## Closeout

Activation v1 remains a governed audit bridge from reviewed capability
definitions to the existing external-worker runtime. It does not launch a
process, schedule a trigger, deploy code, add a provider tool, expose a public
activation message on `/engine`, or manage skills from the repo.

## Successor Note

SAAWBH preserves SAAWA activation issuance and hello/register readiness as the
authority for callable worker state, while adding process-memory bundle custody
and durable redaction for idempotency replay.

SAAWTL preserves the same activation boundary for trigger-created launch:
`worker::launch_from_trigger` invokes `worker::issue_activation` with a derived
idempotency key and does not mint tokens through any parallel path. Callable
readiness still requires the SAAWA hello/register flow.
