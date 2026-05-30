# Codebase Cleanup Scorecard

Created: 2026-05-30

Initial cleanup score: **0/100**

Current score: **99/100**

Status: **CLC-9 complete; CLC-10 next**

This scorecard is the repo-local maintainability plan. It is separate from
`collapsed-engine-hardening-scorecard.md`, which remains at **100/100** for
collapsed-engine robustness. Cleanup points measure completed audit,
simplification, tests, documentation, and useful static gates. They do not
claim product functionality is missing.

Score normalization note: the original phase effort labels after CLC-7 sum
past 100. The remaining completion score is capped and normalized so CLC-8
awards +3, CLC-9 awards +2, and CLC-10 awards +1; the original larger effort
labels remain useful planning context but do not let the score exceed 100.

## Operating Rules

- Behavior-preserving cleanup comes first. Behavior changes are allowed only
  when a row identifies a real bug and the owning module receives a root-cause
  fix.
- Prefer deleting concepts, branches, helpers, modes, and layers over moving
  the same complexity around.
- Keep logic in the canonical owner. Do not add fallback readers,
  compatibility layers, client-owned policy, alternate worker-spawn paths,
  package/source/policy/trust/audit tables, or product-state side channels.
- Keep the architecture collapsed: workers, functions, triggers, resources,
  grants, approvals, queues, streams, state, memory, providers, and clients
  compose through the engine substrate.
- No file may newly cross 1,000 LOC without an explicit row in this scorecard.
  Existing large files must stay within the audited budget below until their
  decomposition checkpoint closes the exception.
- Each checkpoint ships code, tests, docs, a scorecard update, and a ledger
  entry.
- If a scenario fails, stop broad cleanup, isolate the exact layer, add or
  identify the smallest focused test, fix the owning module, delete nearby
  dead/fallback/legacy/compat code, rerun the exact scenario, and update this
  scorecard.

## Review Rubric

Each touched area is reviewed for:

- Structural simplification: fewer concepts or branches after the change.
- Module ownership clarity: behavior lives in the domain or substrate that owns
  the invariant.
- Branching and spaghetti reduction: no scattered one-off conditionals.
- Type and boundary explicitness: fewer casts, unknown shapes, nullable modes,
  and silent fallbacks.
- File-size and decomposition: large files shrink or receive a narrow,
  temporary exception with a target checkpoint.
- Canonical-helper reuse: no bespoke near-duplicates of established helpers.
- Test locality: focused coverage lives near the owning module or scenario
  harness, with static gates only for cross-cutting invariants.

## Static Gates

`packages/agent/tests/threat_model_invariants.rs` owns the cross-cutting
cleanup gates:

- This scorecard must exist and remain linked from the README living-doc map.
- The scenario ledger must include `CLC-0` through `CLC-10`.
- CLC-0 must keep the `process::run` recipe rendering invariant, `tron dev`
  default `RUST_LOG=info,ort=error`, a default background health wait of 30s,
  and installed-service restore success gated on `/health`.
- Large Rust, Swift, and shell/script files over 1,000 LOC must have a row in
  the large-file audit table and stay below that row's budget.
- New cleanup exceptions require scorecard rows before they can pass the static
  gate.
- CLC-1 capability boundaries must stay split, including the recipe-owned
  display model used by search, inspect/schema guidance, primer, and execute
  discovery rendering.
- CLC-2 resource, resource-store, queue, approval, engine-type, generated-UI,
  control, ledger, grant, primitive-runtime, engine-registry, and module
  manifest/grant/registration/schema/payload/action/trust-audit boundaries must stay split: parent roots remain below 1,000 LOC while
  artifact/goal curation, materialized-file and patch mutation, payload
  parsing, shared resource-ref helpers, resource/UI schemas, generated-UI
  action authoring, resource-store events/ids, SQLite schemas/codecs, store
  tests, queue draining, queue lifecycle stream projection, approval tests,
  catalog change DTOs, control action catalogs, stored outcome projection,
  grant records/bootstrap/event builders, and worker protocol guide/template
  projection stay in focused submodules; registry invocation lifecycle,
  output-contract enforcement, and catalog-change recording stay out of the
  live-catalog root; module manifest validation and runtime parsing, grant
  derivation/narrowing checks, resource mutation/projection helpers, base
  request/response schemas, payload parsing/secret enforcement helpers, action
  catalogs, store access, package lifecycle, activation lifecycle, evidence
  resource creation, and function registrations stay out of the lifecycle root; engine
  host meta-function constants, schemas, DTOs, visibility projection, delegated
  invocation shaping, and payload parsers stay in `host/meta.rs`; the
  host-dispatched primitive runtime implementation stays in `host/runtime_host.rs`;
  handle constructors, catalog operations, module-maintenance queue producers,
  invocation orchestration, invocation support helpers, and substrate-store
  methods stay in focused `host/*` submodules;
  trust-audit schedule
  parsing and due-bucket calculation stay out of the module audit action root;
  source-trust registration,
  verification, approval, lifecycle, policy, inspection, support, and schema
  concerns stay in focused source-trust submodules.
- `session_storage_protocol_boundaries_stay_split` gates the CLC-3 split:
  session repository dashboard projections, event reconstruction tests,
  migration tests, event-store API tests, protocol event DTOs, shared storage
  helpers, and `/engine` WebSocket wire/projection/outbound concerns must stay
  in focused child modules while the parent roots remain below 1,000 LOC.
- `model_provider_profile_boundaries_stay_split` gates the CLC-4 split:
  OpenAI auth/config, model registry/catalog, and Responses DTOs stay in
  focused modules; provider/profile parent files stay below 1,000 LOC; provider
  tests stay in child modules; profile validation owns the typed context-block
  provider surface contract.
- `agent_runner_context_boundaries_stay_split` gates the CLC-5 split: turn,
  compaction, capability invocation, hook, session, and turn-accumulator parent
  files stay below 1,000 LOC; moved test matrices stay in child modules; turn
  context construction and live provider surface resolution stay out of the
  `turn_runner.rs` orchestration root.
- `smaller_domain_boundaries_stay_split` gates the CLC-6 split: the worktree
  Git executor root stays below 1,000 LOC while command execution, remote,
  state/ref mutation, conflict helpers, parser helpers, error classification,
  and Git tests stay in focused `git/*` submodules; cron scheduler/executor,
  auth provider storage/OpenAI auth, process, MCP product-protocol client,
  skills tracker, and shared path parents keep moved tests in child modules.
- `ios_thin_client_boundaries_stay_split` gates the CLC-7 split: iOS
  production-source roots for Engine Console, capability invocation rendering,
  new-session flow, capability invocation types, and engine connection all stay
  below 1,000 LOC while extracted section/component, display/presentation,
  protocol-frame/type, and session-flow modules remain in focused Swift files.
- `mac_script_boundaries_stay_split` gates the CLC-8 script/startup split: the
  workspace CLI dispatcher, runtime library loader, workspace command modules,
  installed-runtime service/log/auth/bundle modules, binary startup root,
  binary CLI module, binary runtime module, updater production root, and APNS
  push-helper production root all stay below 1,000 LOC; install/deploy/setup
  paths copy `tron-lib.d/` beside `tron-lib.sh`; dev takeover restore stays
  health-gated through the shared service module; and updater/APNS test
  matrices stay out of production roots.
- `test_harness_boundaries_stay_split` gates the CLC-9 test/harness split:
  guardrails tests stay concern-owned under `guardrails/tests/`, fixture
  self-tests stay runnable without live server/session arguments, and RWO-N17
  keeps the current-model simulator/deep-link multi-session evidence markers.

## Scenario Ledger

| ID | Status | Score delta | Touched folders | Deleted complexity | Tests | Residual risks |
|----|--------|-------------|-----------------|--------------------|-------|----------------|
| CLC-0 | Complete | +10 | `scripts/`, `packages/agent/src/domains/capability/`, `packages/agent/src/shared/foundation/`, `packages/agent/tests/`, `README.md`, `packages/agent/docs/` | Replaced optimistic installed-service restore prints with one health-gated helper; moved the brittle recipe assertion to schema/display invariants instead of exact wording; made the capability schema provider surface a named contract. | `search_visible_content_contains_actionable_recipe`; `default_context_block_manifest_declares_capability_schema_surface`; `threat_model_invariants`; `scripts/tron dev -bd --json --wait 30`; `curl /health` | Installed `/Applications/Tron.app` can still be stale; no fallback compatibility is added, so the diagnostic requires reinstall/update. |
| CLC-1 | Complete | +15 | `packages/agent/src/domains/capability/operations/`, `packages/agent/src/domains/capability/registry/`, `packages/agent/src/domains/capability_support/` | Extracted `operations/{schema_validation,presentation,policy_profile,admin}.rs`, cutting `operations/mod.rs` from 4,917 to 959 LOC; extracted `operations/execute/{input,result,trigger_metadata}.rs`, cutting `operations/execute.rs` from 2,091 to 851 LOC; extracted `registry/{store,search_policy}.rs`, cutting `registry/mod.rs` from 4,960 to 936 LOC; split `registry/store.rs` into memory, projection, schema, SQLite helper, and SQLite runtime modules, cutting the root from 2,441 to 172 LOC; added the recipe-owned `AgentCapabilityRecipeDisplay` model so search, inspect/schema guidance, primer, and execute discovery rendering no longer rebuild recipe display rules locally; split registry, operations root, execute, and capability-support trait tests into concern-owned modules. | `search_visible_content_contains_actionable_recipe`, capability operations tests, capability registry tests, capability support trait tests, full `domains::capability`, and CLC-1 static gates passed after extraction. | None for CLC-1; future changes must keep all capability implementation files under budget or add a new scorecard exception. |
| CLC-2 | Complete | +15 | `packages/agent/src/engine/`, `packages/agent/src/engine/primitives/`, `packages/agent/src/engine/resources/` | Split the resource primitive by ownership boundary: the parent `resource.rs` is now a registration/dispatch spine below 1,000 LOC, with artifact/goal curation, common wrapper/resource-ref helpers, payload parsing, materialized-file/patch mutation, and schemas in focused submodules. Split `engine/resources/store.rs` so the root is below 1,000 LOC; event/id helpers, SQLite schema/row/JSON codecs, and store tests now live in focused `resources/store/*` submodules. Split `engine/queue.rs` so the durable item/store file is below 1,000 LOC and queue draining plus lifecycle stream projection live in `engine/queue/runtime.rs`. Moved approval idempotency tests to `engine/approval/tests.rs`, leaving `approval.rs` below 1,000 LOC. Split catalog-change DTOs from `engine/types.rs` into `engine/types/catalog.rs`, leaving the public type export stable and the root below 1,000 LOC. Split generated-UI request/response schemas from `primitives/ui.rs` into `primitives/ui/schemas.rs`, leaving the generated-UI root below 1,000 LOC. Split generated-UI action authoring from `primitives/ui/authoring/mod.rs` into `primitives/ui/authoring/actions.rs`, leaving both below 1,000 LOC. Split control action catalog definitions from `primitives/control.rs` into `primitives/control/actions.rs`, leaving the control root below 1,000 LOC. Split persisted invocation outcome projection and SQLite schema/row/JSON codecs from `engine/ledger.rs` into `engine/ledger/outcome.rs` and `engine/ledger/sqlite_codec.rs`, leaving the ledger root below 1,000 LOC. Split grant record/request/bootstrap/event builders and SQLite row/risk/JSON codecs from `engine/grants.rs` into `engine/grants/model.rs` and `engine/grants/sqlite_codec.rs`, leaving the grants root below 1,000 LOC. Split `primitives/runtime.rs` so the root host-dispatched query dispatcher is below 1,000 LOC, worker protocol guide projection lives in `primitives/runtime/worker_protocol.rs`, and the executable Python template is readable source in `primitives/runtime/worker_protocol_template.py`. Split `engine/registry.rs` so the live-catalog root is below 1,000 LOC while catalog-change recording, sync invocation/idempotency lifecycle, and output-contract enforcement live in focused `engine/registry/*` submodules. Split `module/trust_audit.rs` so the action/status/retention root is below 1,000 LOC while schedule parsing and due-bucket calculation live in `module/trust_audit/schedule.rs`. Split `module/source_trust.rs` into registration, verification, approval, lifecycle, policy, inspection, support, and schema submodules, leaving every source-trust implementation file below 1,000 LOC. Split the module registration catalogue into `module/registrations.rs`, package manifest validation/runtime parsing into `module/manifest.rs`, module grant policy into `module/grants.rs`, module resource helpers into `module/resources.rs`, base request/response schemas into `module/schemas.rs`, payload parsing/secret enforcement helpers into `module/payload.rs`, server-authored action catalogs into `module/actions.rs`, store access into `module/store_access.rs`, package registration/configuration/inspection into `module/package_lifecycle.rs`, activation/upgrade/rollback/disable/quarantine orchestration into `module/activation_lifecycle.rs`, and decision/evidence resource creation into `module/evidence.rs`, cutting `module.rs` to 207 LOC. Split engine host meta-function constants, watch DTOs, schemas, visibility projection, delegated invocation shaping, and payload parsers into `engine/host/meta.rs`; split the host-dispatched primitive runtime implementation into `engine/host/runtime_host.rs`; split host-handle constructors, catalog operations, module-maintenance queue producers, invocation orchestration, invocation support helpers, and substrate-store methods into focused `engine/host/*` submodules, cutting `host.rs` to 815 LOC. CLC-2 is closed; final verification covered queue/resource/module/generated UI/host/static gates without regressions. | `engine::tests::resource_kernel`, `engine::resources::store`, `engine::tests::state_queue`, `sqlite_queue_blobs_large_payload_but_claim_returns_original_payload`, `engine::approval::tests`, `engine::tests::ids_types`, `engine::tests::generated_ui`, `engine::tests::ledger_idempotency`, `engine::tests::grant_authority`, `engine::tests::meta_primitives`, `engine::tests::catalog_discovery`, `engine::tests::host_invocation`, `engine::tests::module_activation`, and `threat_model_invariants` passed for the completed CLC-2 slices; CLC-2 resource, resource-store, queue, approval, engine-type, generated-UI, generated-UI authoring, control, ledger, grant, runtime, registry, host meta, host runtime host, host handle/substrate/invocation, module store-access, package-lifecycle, activation-lifecycle, evidence, resource, grant, manifest, registration, schema, payload, action, trust-audit, and source-trust large-file gates added. Final CLC-2 broad engine and static gates passed. | None for CLC-2; terminal-state behavior remains guarded by later runner/chat parity checkpoints. |
| CLC-3 | Complete | +12 | `packages/agent/src/domains/session/`, `packages/agent/src/shared/protocol/`, `packages/agent/src/shared/storage.rs`, `packages/agent/src/transport/` | Split session dashboard projections and session tests out of the session repository root; split event reconstruction, migration, and event-store API tests into scenario-owned children; split protocol events into capability, factory, stream, Tron support, generated Tron catalog, and focused tests; split shared storage into archive, schema, payload, maintenance, stats, and tests; split `/engine` WebSocket wire DTOs, stream projection, outbound serialization, and tests from the transport flow root. | `domains::session::event_store`, `shared::storage`, `shared::events`, `transport::engine_ws`, CLC-3 static gate, formatting, and diff checks passed after extraction. | `events/tron/catalog.rs` remains an explicit 1,153 LOC exception because the exhaustive serde-tagged `TronEvent` catalog and accessor macro are clearer in one audited file than in a synthetic compatibility layer. |
| CLC-4 | Complete | +10 | `packages/agent/src/domains/model/providers/`, `packages/agent/src/shared/foundation/profile.rs` | Split OpenAI provider-native types into auth/config, model registry, Responses DTO, catalog shard, and test modules; split large provider inline tests into child modules for OpenAI, Anthropic, Google, and Ollama; split profile validation and tests from profile loading; replaced stringly context-block `providerSurface` validation with the typed `ContextBlockProviderSurface` enum while preserving the canonical `providerSurface = "capability"` contract. | `domains::model::providers`, `shared::profile`, CLC-4 static gate, formatting, and diff checks. | `packages/agent/src/domains/model/providers/openai/message_converter.rs`, `kimi/stream_handler.rs`, `factory.rs`, and provider token/context helpers remain below 1,000 LOC but are future cleanup candidates if they grow or CLC-4 is reopened. Local `gemma4:e4b` remains substrate smoke only. |
| CLC-5 | Complete | +12 | `packages/agent/src/domains/agent/runner/` | Split inline runner/hook/orchestrator test matrices out of runtime roots for capability invocation execution, compaction, turn-runner capability invocation continuation, hook engine, prompt hooks, orchestrator, session manager, and turn accumulator; split hook-engine context-result tests into a child module to avoid creating a new CLC-9 exception; moved turn context construction, capability primer rendering, live provider primitive-surface resolution, and resolved policy-id projection into `turn_runner/turn_context.rs`, leaving `turn_runner.rs` as the orchestration spine. | `domains::agent::runner` passed, 1,366 tests; CLC-5 static gate, formatting, and diff checks. | Pre-existing CLC-9 test matrices remain intentionally large: guardrails, stream processor, context manager, compaction engine, and subagent manager. Chat/engine parity UI drift remains tracked for later UI polish and cannot introduce product-state side channels. |
| CLC-6 | Complete | +10 | `packages/agent/src/domains/worktree/`, `packages/agent/src/domains/cron/`, `packages/agent/src/domains/process/`, `packages/agent/src/domains/auth/`, `packages/agent/src/domains/skills/`, `packages/agent/src/domains/mcp/product_protocol/`, `packages/agent/src/shared/foundation/` | Split `GitExecutor` by command-family owner (`command`, `remote`, `state`, `conflicts`, `parsing`, `error_classification`) and moved Git tests out of the command catalog root; moved inline tests out of cron scheduler/executor, auth provider storage/OpenAI auth, skills tracker, process, MCP product-protocol client, and shared path parents; added the CLC-6 static boundary gate. | Targeted worktree/cron/process/auth/skills/MCP/foundation tests, formatting, `threat_model_invariants`, and diff checks. | Settings contracts were not changed, so no iOS settings parity update was required. Large test matrices and the managed vault shell script remain audited rows for CLC-9/CLC-10 rather than production-source CLC-6 blockers. |
| CLC-7 | Complete | +10 | `packages/ios-app/Sources/Views/`, `packages/ios-app/Sources/Services/Network/`, `packages/ios-app/Sources/Models/`, `packages/ios-app/docs/`, `packages/agent/tests/` | Split Engine Console section/component bodies, capability invocation display/presentation models, capability detail/result renderers, new-session flow types/components, and engine connection types/protocol frames out of broad Swift roots; trimmed redundant transport comments instead of widening private state-machine internals. | `xcodegen generate`; targeted `xcodebuild test` for capability invocation display, new-session flow, engine connection reconnect, and Engine Console state; `ios_thin_client_boundaries_stay_split`. | No chat/session navigation behavior changed, so simulator deep-link smoke was not required for this checkpoint. Large iOS test matrices remain audited rows for the test/harness cleanup lane rather than CLC-7 production-source blockers. |
| CLC-8 | Complete | +3 normalized (+8 planning effort) | `scripts/`, `packages/mac-app/docs/`, `README.md`, `packages/agent/src/main*.rs`, `packages/agent/src/platform/`, `packages/agent/tests/` | Split `scripts/tron` into `scripts/tron.d/{workspace,quality,dev,deploy,automation}.sh` and `scripts/tron-lib.sh` into `scripts/tron-lib.d/{service,bundle,logs,auth}.sh`; kept service health/restore logic centralized in `service.sh`; updated install/deploy/setup to copy runtime library modules; split the binary startup root into `main.rs`, `main_cli.rs`, and `main_runtime.rs`; moved updater and APNS push-helper test matrices out of production roots. | `bash -n` for CLI scripts; `scripts/tron status --json`; `scripts/tron dev -bd --json --wait 30`; `curl /health`; focused `cli_default_host`, `parse_triple`, and `to_apns_notification_maps_all_fields`; `mac_script_boundaries_stay_split`. | None for CLC-8; `main_runtime.rs` remains below 1,000 LOC and should be split again if future startup work makes it grow. |
| CLC-9 | Complete | +2 normalized (+5 planning effort) | `packages/agent/tests/`, `packages/agent/src/**/tests*`, `packages/agent/tests/fixtures/` | Split `guardrails/tests.rs` into concern-owned test modules for serialization, pattern/path/resource rules, context/composite rules, and engine/audit/integration checks; kept shared guardrail fixtures in `tests/mod.rs`; fixed `rwo_n15_live_worker_fixture.py --self-test` so live session validation does not block fixture self-tests; added the CLC-9 harness/static split gate. | `guardrails --lib`; fixture self-tests for RWO-N7, RWO-N15, and terminal guard; `threat_model_invariants`; formatting and diff checks. | Remaining large test matrices stay audited with budgets; CLC-10 must close or explicitly defer every final large-file row. |
| CLC-10 | Not started | +1 normalized (+3 planning effort) | Whole repo | Target: final file-size report, close or defer rows explicitly, run broad verification appropriate to touched areas, update README only for changed canonical modules/CLI/contracts/events/settings/schema. | Broad verification by touched area. | Final score requires every open exception to be closed or explicitly deferred. |

## CLC-0 Dev Workflow Reliability

Accepted CLC-0 root-cause fixes:

- `process::run` recipe search rendering now asserts the invariant: required
  `command` and `executionMode` fields render into search results with
  actionable schema/description guidance. The test no longer depends on the old
  exact phrase casing owned by the recipe schema.
- `tron dev` foreground and LaunchAgent defaults now use
  `RUST_LOG=info,ort=error` while preserving explicit user `RUST_LOG` and
  `--log-level`.
- Background `tron dev` health wait defaults to `30s`.
- `tron dev` restore paths now call one health-gated installed-service restart
  helper. They do not print "Installed service restarted" unless `/health`
  passes and a listener is observed.
- Restore failure now prints a direct stale-installed-app diagnostic for
  `/Applications/Tron.app` profile-default incompatibility. No fallback
  compatibility reader is introduced; stale installed helpers must be updated.
- The canonical capability schema manifest provider surface is explicit:
  `capabilities.schemas` must use `providerSurface = "capability"`.

Verification required for this checkpoint:

```bash
cargo test --manifest-path packages/agent/Cargo.toml search_visible_content_contains_actionable_recipe --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml default_context_block_manifest_declares_capability_schema_surface --lib -- --nocapture
cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants -- --nocapture
cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check
scripts/tron dev -bd --json --wait 30
curl -fsS http://localhost:9847/health
git diff --check
```

CLC-0 verification evidence from 2026-05-30:

- `cargo test --manifest-path packages/agent/Cargo.toml search_visible_content_contains_actionable_recipe --lib -- --nocapture`: passed.
- `cargo test --manifest-path packages/agent/Cargo.toml default_context_block_manifest_declares_capability_schema_surface --lib -- --nocapture`: passed.
- `cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants -- --nocapture`: passed, 56 tests.
- `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`: passed.
- `bash -n scripts/tron && bash -n scripts/tron-lib.sh`: passed.
- `git diff --check`: passed.
- `RUST_LOG=info,ort=error scripts/tron dev -bd --json --wait 30`: passed; returned `mode=dev_takeover`, `healthy=true`, `listenerPid=92622`, `devLaunchdLoaded=true`.
- `curl -fsS http://localhost:9847/health`: passed with `{"status":"ok"}`.
- LaunchAgent plist evidence: `EnvironmentVariables.RUST_LOG=info,ort=error`.

## CLC-1 Capability Domain Simplification

CLC-1 is complete and has awarded its **+15** points.

Accepted decomposition:

- `operations/schema_validation.rs` now owns target payload schema validation,
  schema violation shaping, and execute-argument repair guidance.
- `operations/presentation.rs` now owns model-visible search summaries,
  inspection summaries, and missing freshness-material error text.
- `operations/policy_profile.rs` now owns capability execution policy payload
  validation, active-profile TOML writes, rollback, and profile reload.
- `operations/admin.rs` now owns capability admin primitives, registry admin
  audit writes, plugin/conformance validation helpers, and profile-policy
  get/validate/update wrappers.
- `operations/mod.rs` is under 1,000 LOC and now acts as the operation export
  map plus shared execution helpers rather than an admin/test catch-all.
- `registry/store.rs` now owns the capability registry store trait,
  opener, and persistence implementation boundary map instead of concrete
  storage bodies.
- `registry/store/memory.rs` now owns the in-memory registry implementation.
- `registry/store/projection.rs` now owns registry query projection,
  JSON-row decoding, audit redaction, and program-run redaction helpers.
- `registry/store/schema.rs` now owns the SQLite schema text.
- `registry/store/sqlite.rs` now owns SQLite opening, schema migration,
  document upserts, local vector table maintenance, and vector search.
- `registry/store/sqlite_runtime.rs` now owns the SQLite implementation of the
  store trait: sync, search, binding, inspection, audit, plugin/admin, program
  run, pause, and run mutations/queries.
- `registry/recipes.rs` now owns `AgentCapabilityRecipeDisplay`, the typed
  recipe display projection used by search result text, schema-validation
  guidance, execute discovery text, and capability primer rendering.
- `registry/search_policy.rs` now owns profile-controlled search policy flags,
  engine discovery filtering, and document-filter relaxation.
- `registry/mod.rs` remains the catalog projection and selection root instead
  of mixing projection semantics with durable store implementation or
  search-policy filtering.
- `operations/tests/*` now owns the previous operations-root test matrix by
  display/search, normalization, policy, resolution, result, admin, and audit
  concerns.
- `operations/execute/tests/*` now owns the execute-specific discovery,
  normalization, observe-phase, terminal-result, and trigger-metadata test
  matrix instead of keeping those fixtures inside `execute.rs`.
- `operations/execute/input.rs` now owns orchestrated execute input parsing,
  wrapper correction, flattened argument normalization, self-target removal,
  and read-only resource-inventory operation normalization.
- `operations/execute/result.rs` now owns orchestration diagnostics, terminal
  result shaping, child invocation/resource/approval promotion, and
  execute-invocation metadata attachment.
- `operations/execute/trigger_metadata.rs` now owns trigger-id metadata
  recovery guidance and keeps trigger ids out of executable target semantics.
- `operations/execute.rs` is under 1,000 LOC and remains the orchestration
  spine rather than the owner of input parsing, result shaping, or
  trigger-metadata recovery helpers.
- `registry/tests/*` now owns the previous registry-root test matrix by
  projection, recipe, index, primer, store, and support concerns.
- `capability_support/implementations/traits/tests.rs` now owns the shared
  capability-support trait serialization/construction tests, keeping the trait
  surface file below the 1,000 LOC review-smell threshold.
- `critical_execution_and_ui_boundaries_stay_split` now gates the new CLC-1
  boundaries and rejects those helper/test bodies returning to
  `operations/mod.rs`, `operations/execute.rs`, `registry/mod.rs`, or
  `capability_support/implementations/traits.rs`.

CLC-1 verification evidence from 2026-05-30:

- `cargo test --manifest-path packages/agent/Cargo.toml domains::capability::registry --lib -- --nocapture`: passed, 31 tests after registry test and search-policy split.
- `cargo test --manifest-path packages/agent/Cargo.toml domains::capability::registry --lib -- --nocapture`: passed, 31 tests after registry store implementation split.
- `cargo test --manifest-path packages/agent/Cargo.toml domains::capability::operations --lib -- --nocapture`: passed, 103 tests after operations, admin, and execute-test splits.
- `cargo test --manifest-path packages/agent/Cargo.toml domains::capability::operations --lib -- --nocapture`: passed, 103 tests after the execute input/result/trigger-metadata implementation split.
- `cargo test --manifest-path packages/agent/Cargo.toml domains::capability_support::implementations::traits --lib -- --nocapture`: passed, 21 tests after trait-test split.
- `cargo test --manifest-path packages/agent/Cargo.toml domains::capability --lib -- --nocapture`: passed, 248 tests after recipe display-model consolidation.
- `cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants -- --nocapture`: passed, 56 tests after CLC-1 static gates covered execute, registry store, and recipe display-model boundaries.
- `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`: passed.
- `git diff --check`: passed.

Closed CLC-1 acceptance audit:

- No capability implementation file in `domains/capability` or
  `domains/capability_support` remains above 1,000 LOC.
- `execute.rs` and `registry/store.rs` are now orchestration/contract spines,
  not broad helper buckets.
- Recipe/search/rendering conditionals are owned by
  `AgentCapabilityRecipeDisplay`; callers consume the typed projection.

## CLC-2 Engine Fabric Simplification

CLC-2 is complete and has awarded its **+15** points.

Accepted decomposition:

- `primitives/resource.rs` now owns only resource primitive registration,
  function metadata, and dispatch. It is below the 1,000 LOC review-smell
  threshold.
- `primitives/resource/artifact.rs` owns artifact split/compose/merge/search
  behavior and goal working-set projection.
- `primitives/resource/common.rs` owns shared wrapper mutation, lifecycle,
  inspection-kind checks, current-payload lookup, and resource-ref shaping.
- `primitives/resource/input.rs` owns scope, versioning, location, worker-id,
  and string-array payload parsing.
- `primitives/resource/materialized_file.rs` owns materialized-file create,
  update, read, hash-verify, artifact materialization, patch proposal/apply,
  canonical path resolution, and hash helpers.
- `primitives/resource/schemas.rs` owns resource, wrapper, artifact, goal,
  attach, materialized-file, patch, and resource-ref schemas.
- `resource_kernel_and_generated_ui_ownership_boundaries_stay_split` now gates
  the resource primitive split and rejects those helpers returning to the
  parent dispatcher.
- `resources/store.rs` now owns in-memory and SQLite store orchestration below
  the 1,000 LOC threshold.
- `resources/store/events.rs` owns resource event construction and generated
  IDs.
- `resources/store/sqlite_codec.rs` owns the resource-store SQLite schema, row
  reconstruction, scope projection, and JSON serialization helpers.
- `resources/store/tests.rs` owns the store contract tests instead of keeping
  test fixtures in the production store root.
- `queue.rs` now owns durable queue item types and in-memory/SQLite queue store
  behavior, while `queue/runtime.rs` owns queue drain orchestration, retry
  execution, drainer service facade, and queue lifecycle stream projection.
- `primitive_workers_are_owned_outside_host_bucket` now gates the queue runtime
  split and rejects runtime draining or lifecycle stream projection returning to
  `queue.rs`.
- `approval.rs` now owns approval records, requests, stores, transitions, and
  parsing helpers below the 1,000 LOC threshold, while approval idempotency
  tests live in `approval/tests.rs`.
- `rust_test_ownership_stays_code_adjacent` now gates the approval test split
  and rejects broad inline tests returning to `approval.rs`.
- `types.rs` now owns shared engine definition contracts below the 1,000 LOC
  threshold, while catalog change DTOs live in `types/catalog.rs` behind the
  same public `crate::engine` re-export surface.
- `server_package_uses_domain_owned_engine_layout` now gates the engine type
  split and rejects catalog DTOs returning to `types.rs`.
- `primitives/ui.rs` now owns generated-UI registration and handler flow below
  the 1,000 LOC threshold, while request/response schemas live in
  `primitives/ui/schemas.rs`.
- `resource_kernel_and_generated_ui_ownership_boundaries_stay_split` now gates
  the generated-UI schema split and rejects schema builders returning to
  `primitives/ui.rs`.
- `primitives/control.rs` now owns control snapshot/inspect projection below
  the 1,000 LOC threshold, while the operator action catalog lives in
  `primitives/control/actions.rs`.
- Existing generated-UI and module package static gates now read the control
  action boundary and reject the action catalog returning to `control.rs`.
- `ledger.rs` now owns the ledger store contract, in-memory store, and SQLite
  store orchestration below the 1,000 LOC threshold.
- `ledger/outcome.rs` owns persisted invocation error/result projection and
  replay conversion.
- `ledger/sqlite_codec.rs` owns ledger SQLite schema, row reconstruction, and
  stored JSON payload helpers.
- `engine_ledger_ownership_boundaries_stay_split` now gates the ledger split
  and rejects stored outcome or SQLite codec helpers returning to `ledger.rs`.
- `grants.rs` now owns grant store orchestration and grant authorization /
  derivation policy below the 1,000 LOC threshold.
- `grants/model.rs` owns grant records, derive/list requests, lifecycle,
  bootstrap grants, and event builders.
- `grants/sqlite_codec.rs` owns grant SQLite row/risk/JSON conversion helpers.
- `grant_manifest_resource_and_ui_hardening_tests_stay_in_owning_boundaries`
  now gates the grants split and rejects model or SQLite codec helpers returning
  to `grants.rs`.
- `primitives/runtime.rs` now owns the host-dispatched primitive query
  dispatcher below the 1,000 LOC threshold, while
  `primitives/runtime/worker_protocol.rs` owns the worker protocol guide
  response projection and `primitives/runtime/worker_protocol_template.py`
  owns the readable executable Python template source.
- `registry.rs` now owns live-catalog registration, discovery, grant checks,
  and cleanup below the 1,000 LOC threshold.
- `registry/catalog_changes.rs` owns catalog-change subject projection and
  append-only revision recording.
- `registry/invocation.rs` owns sync invocation preparation, completion,
  idempotency reservation/replay, result ledger recording, and canonical
  payload fingerprinting.
- `registry/output_contract.rs` owns durable output-contract and resource-ref
  validation.
- `primitives/module/trust_audit.rs` now owns trust-audit actions, status,
  retention review, evidence lookup, and schemas below the 1,000 LOC threshold.
- `primitives/module/trust_audit/schedule.rs` owns schedule parsing, retention
  policy parsing, schedule resource ids, wall-clock/day validation, current
  due bucket calculation, and missed-bucket projection.
- `primitives/ui/authoring/mod.rs` now owns request parsing, target projection,
  shared resource collection projection, layouts, and actor context below the
  1,000 LOC threshold.
- `primitives/ui/authoring/actions.rs` owns generated action construction and
  shared stored-action helpers below the 1,000 LOC threshold.
- `primitives/module/source_trust.rs` is now a 26-line module boundary for
  source-trust ownership.
- `primitives/module/source_trust/{registration,verification,approval,lifecycle,policy,inspection,support,schemas}.rs`
  split source-trust operations by lifecycle concern, all below the 1,000 LOC
  threshold.
- `primitives/module/registrations.rs` now owns the module function
  registration catalogue plus read/write function-definition builders, cutting
  `primitives/module.rs` from 3,832 to 3,438 LOC and keeping registration
  metadata out of the lifecycle root.
- `primitives/module/manifest.rs` now owns package manifest validation,
  normalization, digest calculation, declared-capability comparison,
  local-process runtime entrypoint parsing, and resource-version ref parsing,
  cutting `primitives/module.rs` from 3,438 to 2,785 LOC.
- `primitives/module/grants.rs` now owns module child-grant derivation,
  caller-narrowing checks, source-approval ceiling checks, grant-risk/network
  comparison, and local-process file-root enforcement, cutting
  `primitives/module.rs` from 2,785 to 2,239 LOC.
- `primitives/module/resources.rs` now owns module resource ids, upserts,
  version guards, payload lookup, resource refs, trust summaries, and
  relation links, cutting `primitives/module.rs` from 2,239 to 1,868 LOC.
- `primitives/module/schemas.rs` now owns base package/config/activation
  request schemas and resource-backed response schemas.
- `primitives/module/payload.rs` now owns shared payload scalar parsing,
  date/risk/hash helpers, bounded JSON previews, UTF-8-safe truncation, secret
  rejection, and secret-ref collection.
- `primitives/module/actions.rs` now owns server-authored action catalogs for
  package and trust-target operator surfaces.
- These module schema/payload/action splits cut `primitives/module.rs` from
  1,868 to 1,346 LOC and keep the lifecycle root focused on package/config/
  activation orchestration.
- `primitives/module/{store_access,package_lifecycle,activation_lifecycle,evidence}.rs`
  now own substrate store access, package registration/configuration/inspection
  and diagnostics, activation/upgrade/rollback/disable/quarantine flow, and
  decision/evidence resource creation, cutting `primitives/module.rs` from
  1,346 to 207 LOC.
- `engine/host/meta.rs` now owns engine meta-function constants, watch DTOs,
  request schemas, visibility projection, delegated invocation shaping, error
  projection, and payload parsers, cutting `engine/host.rs` from 3,387 to
  2,730 LOC.
- `engine/host/runtime_host.rs` now owns the
  `PrimitiveRuntimeHost` implementation for host-dispatched primitives, including
  catalog snapshots, trace-scoped approvals/streams/leases/compensation,
  resource/grant store access, queue snapshots, storage maintenance, and
  observability log projection, cutting `engine/host.rs` from 2,730 to
  2,446 LOC.
- `engine/host/{handle,catalog_handle,module_jobs,invocation_handle,invocation_support,substrate_handle}.rs`
  now split handle constructors, catalog registration/discovery/watch/promotion,
  module maintenance queue producers, invocation orchestration, lease/retry/
  panic/approval helpers, and primitive substrate store methods by owner,
  cutting `engine/host.rs` from 2,446 to 815 LOC.

CLC-2 verification evidence from 2026-05-30:

- `cargo test --manifest-path packages/agent/Cargo.toml engine::tests::resource_kernel --lib -- --nocapture`: passed, 18 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml engine::resources::store --lib -- --nocapture`: passed, 7 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml engine::tests::state_queue --lib -- --nocapture`: passed, 7 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml sqlite_queue_blobs_large_payload_but_claim_returns_original_payload --lib -- --nocapture`: passed.
- `cargo test --manifest-path packages/agent/Cargo.toml engine::approval::tests --lib -- --nocapture`: passed, 2 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml engine::tests::ids_types --lib -- --nocapture`: passed, 2 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml engine::tests::generated_ui --lib -- --nocapture`: passed, 23 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml engine::tests::ledger_idempotency --lib -- --nocapture`: passed, 11 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml engine::tests::grant_authority --lib -- --nocapture`: passed, 8 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml engine::tests::meta_primitives --lib -- --nocapture`: passed, 10 tests after the primitive-runtime worker protocol split.
- `cargo test --manifest-path packages/agent/Cargo.toml engine::tests::catalog_discovery --lib -- --nocapture`: passed, 16 tests after the registry split.
- `cargo test --manifest-path packages/agent/Cargo.toml engine::tests::host_invocation --lib -- --nocapture`: passed, 14 tests after the registry invocation split.
- `cargo test --manifest-path packages/agent/Cargo.toml engine::tests::ledger_idempotency --lib -- --nocapture`: passed, 11 tests after the registry invocation split.
- `cargo test --manifest-path packages/agent/Cargo.toml engine::tests::grant_authority --lib -- --nocapture`: passed, 8 tests after the registry output-contract split.
- `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`: passed after the registry split.
- `cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants -- --nocapture`: passed, 57 tests after the registry split.
- `git diff --check`: passed after the registry split.
- `cargo test --manifest-path packages/agent/Cargo.toml engine::tests::module_activation --lib -- --nocapture`: passed, 31 tests after the module trust-audit schedule split.
- `cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants -- --nocapture`: passed, 57 tests after the module trust-audit static gate was updated for `trust_audit/schedule.rs`.
- `cargo test --manifest-path packages/agent/Cargo.toml engine::tests::generated_ui --lib -- --nocapture`: passed, 23 tests after the generated-UI action authoring split.
- `cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants -- --nocapture`: passed, 57 tests after the generated-UI authoring static gate was updated for `authoring/actions.rs`.
- `cargo test --manifest-path packages/agent/Cargo.toml engine::tests::module_activation --lib -- --nocapture`: passed, 31 tests after the source-trust split.
- `cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants -- --nocapture`: passed, 57 tests after the source-trust subtree static gate and audited static-gate budget were updated.
- `cargo test --manifest-path packages/agent/Cargo.toml engine::tests::module_activation --lib -- --nocapture`: passed, 31 tests after the module registration catalogue split.
- `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`: passed after the module registration catalogue split.
- `cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants -- --nocapture`: passed, 57 tests after the module registration static gate was added.
- `git diff --check`: passed after the module registration catalogue split.
- `cargo test --manifest-path packages/agent/Cargo.toml engine::tests::module_activation --lib -- --nocapture`: passed, 31 tests after the module manifest split.
- `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`: passed after the module manifest split.
- `cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants -- --nocapture`: passed, 57 tests after the module manifest static gate and audited static-gate budget were updated.
- `git diff --check`: passed after the module manifest split.
- `cargo test --manifest-path packages/agent/Cargo.toml engine::tests::module_activation --lib -- --nocapture`: passed, 31 tests after the module grant-policy split.
- `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`: passed after the module grant-policy split.
- `cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants -- --nocapture`: passed, 57 tests after the module grant static gate was added.
- `git diff --check`: passed after the module grant-policy split.
- `cargo test --manifest-path packages/agent/Cargo.toml engine::tests::module_activation --lib -- --nocapture`: passed, 31 tests after the module resource-helper split.
- `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`: passed after the module resource-helper split.
- `cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants -- --nocapture`: passed, 57 tests after the module resource static gate was added.
- `git diff --check`: passed after the module resource-helper split.
- `cargo test --manifest-path packages/agent/Cargo.toml engine::tests::module_activation --lib -- --nocapture`: passed, 31 tests after the module schema, payload, and action-catalog split.
- `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`: passed after the module schema, payload, and action-catalog split.
- `cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants -- --nocapture`: passed, 57 tests after the module schema, payload, action-catalog, and canonical action-summary static gates were updated.
- `git diff --check`: passed after the module schema, payload, and action-catalog split.
- `cargo test --manifest-path packages/agent/Cargo.toml engine::tests::meta_primitives --lib -- --nocapture`: passed, 10 tests after the host meta split.
- `cargo test --manifest-path packages/agent/Cargo.toml engine::tests::host_invocation --lib -- --nocapture`: passed, 14 tests after the host meta split.
- `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`: passed after the host meta split.
- `cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants -- --nocapture`: passed, 57 tests after the host meta static gate was added.
- `git diff --check`: passed after the host meta split.
- `cargo test --manifest-path packages/agent/Cargo.toml engine::tests::meta_primitives --lib -- --nocapture`: passed, 10 tests after the host runtime-host split.
- `cargo test --manifest-path packages/agent/Cargo.toml engine::tests::host_invocation --lib -- --nocapture`: passed, 14 tests after the host runtime-host split.
- `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`: passed after the host runtime-host split.
- `cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants -- --nocapture`: passed, 57 tests after the host runtime-host static gate was added.
- `git diff --check`: passed after the host runtime-host split.
- `cargo test --manifest-path packages/agent/Cargo.toml engine::tests::host_invocation --lib -- --nocapture`: passed, 14 tests after the host handle-surface split.
- `cargo test --manifest-path packages/agent/Cargo.toml engine::tests::meta_primitives --lib -- --nocapture`: passed, 10 tests after the host handle-surface split.
- `cargo test --manifest-path packages/agent/Cargo.toml engine::tests::module_activation --lib -- --nocapture`: passed, 31 tests after the host module-maintenance queue split.
- `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`: passed after the host handle-surface split.
- `cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants -- --nocapture`: passed, 57 tests after the host handle-surface static gate was added.
- `git diff --check`: passed after the host handle-surface split.
- `cargo test --manifest-path packages/agent/Cargo.toml engine::tests::module_activation --lib -- --nocapture`: passed, 31 tests after the module lifecycle/store/evidence split.
- `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`: passed after the module lifecycle/store/evidence split.
- `cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants -- --nocapture`: passed, 57 tests after the module lifecycle/store/evidence static gate and score update.
- `cargo test --manifest-path packages/agent/Cargo.toml engine:: --lib -- --nocapture`: passed, 331 tests for the final CLC-2 broad engine sweep.
- `git diff --check`: passed after the final CLC-2 scorecard update.

Closed CLC-2 acceptance:

- `host.rs` and `primitives/module.rs` are both below 1,000 LOC after ownership splits.
- Queue/resource/module/generated UI/host/static gates passed for the final CLC-2 award.
- Next cleanup phase is CLC-3 session, storage, protocol, and event reconstruction.

## CLC-3 Session, Storage, Protocol, And Event Reconstruction

CLC-3 is complete and has awarded its **+12** points.

Accepted decomposition:

- `sqlite/repositories/session.rs` now stays on session lifecycle, listing,
  counters, and head/root mutation below the 1,000 LOC threshold.
- `sqlite/repositories/session/projections.rs` owns dashboard projection DTOs,
  message previews, activity summaries, and payload text extraction.
- `sqlite/repositories/session/tests.rs` is the local session-repository test
  map; core lifecycle, filtering, and projection tests live in focused child
  files.
- `event/reconstruct.rs` now owns reconstruction behavior below the 1,000 LOC
  threshold while `event/reconstruct/tests/*` owns basic capability,
  lifecycle/metadata, multimodal/performance, and synthetic-interrupt
  scenarios.
- `sqlite/migrations/mod.rs` now owns migration execution below the 1,000 LOC
  threshold while `sqlite/migrations/tests/*` owns device-retirement,
  migration mechanics, schema/event, and session/log scenarios.
- `store/tests.rs` is now a fixture/module map below the 1,000 LOC threshold;
  activity-summary, append-counter, auto-sequence, concurrency/worktree,
  query/state, session-creation, and tree-session cases live in child modules.
- `shared/protocol/events.rs` is now a small event facade. Capability event
  summaries, event factories, provider stream events, Tron support types, and
  tests live in focused `events/*` modules.
- `events/tron/catalog.rs` owns the exhaustive serde-tagged `TronEvent`
  catalog and accessor macro. This remains above 1,000 LOC as an explicit
  budgeted exception because splitting enum variants across files would add a
  worse macro/compatibility layer and reduce match/serde locality.
- `shared/storage.rs` now stays on typed runtime/data contracts and re-exports
  while archive, schema, payload storage, maintenance, stats, and tests live in
  `shared/storage/*`.
- `transport/engine_ws.rs` now stays on `/engine` WebSocket session flow while
  wire DTOs/validation, stream-event projection, outbound serialization, and
  transport tests live in `transport/engine_ws/*`.
- `session_storage_protocol_boundaries_stay_split` gates these boundaries and
  rejects the extracted bodies returning to the broad parent roots.

CLC-3 verification evidence from 2026-05-30:

- `cargo test --manifest-path packages/agent/Cargo.toml shared::events --lib -- --nocapture`: passed, 47 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml shared::storage --lib -- --nocapture`: passed, 7 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml domains::session::event_store --lib -- --nocapture`: passed, 552 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml transport::engine_ws --lib -- --nocapture`: passed, 9 tests.
- `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`: passed.
- `cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants -- --nocapture`: passed, 58 tests after the CLC-3 split gate and storage/static-gate owner updates.
- `git diff --check`: passed.

Closed CLC-3 acceptance:

- Session repository, reconstruction, migration, event-store API test,
  protocol event, shared storage, and engine WebSocket roots are all below
  1,000 LOC.
- DTO shape definitions are separated from reconstruction and storage mutation
  behavior.
- No compatibility event aliases, fallback readers, or product-state side
  channels were introduced.
- README event/schema contracts did not require updates because public module,
  CLI, event, settings, and database schema contracts did not change.
- Next cleanup phase after CLC-3 was CLC-4 model providers and context
  surfaces.

## CLC-4 Model Providers And Context Surfaces

Accepted CLC-4 cleanup:

- `providers/openai/types.rs` is now a facade over `types/config.rs`,
  `types/models.rs`, `types/responses.rs`, and focused tests. Endpoint/auth
  config, auth-path-aware model metadata, and Responses request/SSE DTOs no
  longer live in one 3,576 LOC file.
- The OpenAI model catalog is split into shard modules under
  `types/models/catalog/` while the canonical `OPENAI_MODELS` registry remains
  a single explicit runtime map. This deletes file-size concentration without
  adding fallback model lookup paths.
- Large provider inline tests moved to child modules for OpenAI stream/types,
  Anthropic types/stream/message conversion/provider, Google types/provider,
  and Ollama message conversion. Parent files stay on implementation logic.
- `shared/foundation/profile.rs` now stays on profile loading and spec hashing;
  profile validation, context-block manifest parsing, and auth/profile-ref
  validation live in `profile/validation.rs`.
- Context-block `providerSurface` is now typed by
  `ContextBlockProviderSurface`, with the canonical capability-schema surface
  still exposed as `providerSurface = "capability"`.
- `model_provider_profile_boundaries_stay_split` gates the split and rejects
  provider/profile parent files growing back over 1,000 LOC or regaining inline
  tests and extracted bodies.

CLC-4 verification evidence from 2026-05-30:

- `cargo test --manifest-path packages/agent/Cargo.toml domains::model::providers --lib -- --nocapture`: passed, 976 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml shared::profile --lib -- --nocapture`: passed, 12 tests.
- `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`: passed.
- `cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants -- --nocapture`: passed, 59 tests after the CLC-4 provider/profile split gate.
- `git diff --check`: passed.

Closed CLC-4 acceptance:

- No CLC-4 implementation parent remains above 1,000 LOC.
- Provider-native wire spellings stay at provider boundaries; canonical
  capability-layer terminology remains guarded by
  `provider_tool_terms_stay_inside_protocol_boundaries`.
- No provider fallback readers, compatibility model aliases beyond the existing
  explicit registry aliases, or client-owned policy paths were introduced.
- README contracts did not require updates because no public CLI, database,
  event, settings, auth precedence, or top-level Rust module contract changed.
- Next cleanup phase after CLC-4 was CLC-5 agent runner, context, hooks, and
  subagents.

## CLC-5 Agent Runner, Context, Hooks, And Subagents

Accepted CLC-5 cleanup:

- Runtime roots no longer carry broad inline test matrices. Tests moved to
  child modules for capability invocation execution, compaction, turn-runner
  capability invocation continuation, hook engine, prompt hooks, orchestrator,
  session manager, and turn accumulator.
- `hooks/engine/tests.rs` was split again into `tests/context_results.rs`
  instead of creating a new >1,000 LOC test exception.
- `turn_runner.rs` now stays on turn orchestration. Turn context assembly,
  capability-primer rendering, live provider primitive-surface resolution, and
  resolved profile policy-id projection live in `turn_runner/turn_context.rs`.
- All CLC-5 runtime implementation parents that were over 1,000 LOC are now
  below the limit. Remaining large files in the area are pre-existing CLC-9
  scenario/test matrices.
- `agent_runner_context_boundaries_stay_split` gates the split and rejects
  runtime parents regaining inline tests, crossing 1,000 LOC, or pulling turn
  context/surface resolution back into `turn_runner.rs`.

CLC-5 verification evidence from 2026-05-30:

- `cargo test --manifest-path packages/agent/Cargo.toml domains::agent::runner --lib -- --nocapture`: passed, 1,366 tests.
- `python3 packages/agent/tests/fixtures/session_terminal_guard.py --self-test`: passed.
- `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`: passed.
- `cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants -- --nocapture`: passed, 60 tests after the CLC-5 runner/context split gate.
- `git diff --check`: passed.

Closed CLC-5 acceptance:

- Turn orchestration is separated from context/surface construction in
  `turn_runner/turn_context.rs`.
- Capability invocation continuation logic remains in
  `turn_runner/capability_invocations.rs`, with its test matrix moved out of
  the runtime file.
- Compaction, hook, session, orchestrator, and turn-accumulator runtime roots
  are below 1,000 LOC and keep tests in child modules.
- No terminal-state logic, compaction notice behavior, simulator harness, or
  chat/product-state channel changed in this checkpoint.
- Next cleanup phase is CLC-7 iOS thin-client cleanup.

## CLC-6 Smaller-Domain Cleanup

CLC-6 is complete and has awarded its **+10** points.

Accepted decomposition:

- `scm/git.rs` is now the public `GitExecutor` command catalog and no longer
  owns every command-family body. Command execution helpers live in
  `scm/git/command.rs`; remote/fetch/push behavior lives in
  `scm/git/remote.rs`; reset/stash/config/ref mutation lives in
  `scm/git/state.rs`; conflict-index helpers live in `scm/git/conflicts.rs`;
  parser helpers and remote-error classifiers live in
  `scm/git/{parsing,error_classification}.rs`.
- Git executor test matrices moved to `scm/git/tests.rs` and
  `scm/git/phase1_tests.rs`, leaving the production root below 1,000 LOC.
- Cron scheduler and executor, auth provider credential storage and OpenAI
  auth, skills runtime tracking, process materialization/policy, MCP
  product-protocol client, and shared foundation paths now keep their test
  suites in child modules instead of inline implementation roots.
- `smaller_domain_boundaries_stay_split` gates the split and rejects CLC-6
  parents regaining inline tests, crossing 1,000 LOC, or pulling Git command
  execution / remote / state / conflict / parsing / error-classification bodies
  back into `git.rs`.

CLC-6 verification evidence from 2026-05-30:

- `cargo test --manifest-path packages/agent/Cargo.toml domains::worktree --lib -- --nocapture`: passed, 296 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml domains::cron --lib -- --nocapture`: passed, 185 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml domains::process --lib -- --nocapture`: passed, 37 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml domains::auth --lib -- --nocapture`: passed, 201 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml domains::skills --lib -- --nocapture`: passed, 213 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml domains::mcp::product_protocol --lib -- --nocapture`: passed, 114 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml shared::paths --lib -- --nocapture`: passed, 38 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml domains::settings --lib -- --nocapture`: passed, 191 tests; settings contracts were unchanged.
- `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`: passed.
- `cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants -- --nocapture`: passed, 61 tests after the CLC-6 split gate and SCB-S6 large-test audit were updated.
- `git diff --check`: passed.

Closed CLC-6 acceptance:

- Production CLC-6 parent files touched in this checkpoint are now below 1,000
  LOC.
- Process policy and sandbox materialization remain process-owned; this
  checkpoint moved tests only and did not create process policy fallbacks.
- Settings contracts did not change, so no iOS settings parity work was needed.
- Existing large test matrices remain explicit audit rows for CLC-9. The
  managed vault shell script remains an explicit large-file row for the final
  sweep because splitting a managed skill entrypoint requires skill packaging
  verification and was not needed to close source-domain CLC-6.

## CLC-7 iOS Thin Client Cleanup

CLC-7 is complete and has awarded its **+10** points.

Accepted decomposition:

- `Views/EngineConsole/EngineConsoleView.swift` is now the console orchestration
  root below 1,000 LOC. Section identity lives in
  `EngineConsoleSection.swift`; reusable console chips, cards, rows, and
  inspection sheet components live in `EngineConsoleComponents.swift`.
- `Models/Messages/CapabilityInvocationTypes.swift` now keeps lifecycle DTOs,
  errors, results, and artifacts. Capability display projection lives in
  `CapabilityInvocationDisplayModel.swift`; status color, icon, and label
  presentation helpers live in `CapabilityPresentation.swift`.
- `Views/Capabilities/CapabilityInvocationViews.swift` is now the chip/detail
  shell. Detail header/row/raw-disclosure components live in
  `CapabilityInvocationDetailComponents.swift`; result renderers and code
  block rendering live in `CapabilityResultRenderers.swift`.
- `Views/Session/NewSessionFlow.swift` remains the sheet workflow root.
  Flow modes, intents, target descriptors, and model-selection helpers live in
  `NewSessionFlowTypes.swift`; sheet card/button components live in
  `NewSessionFlowComponents.swift`.
- `Services/Network/EngineConnection.swift` remains the transport state
  machine below 1,000 LOC. Connection state/error/token/continuation types live
  in `EngineConnectionTypes.swift`; `/engine` wire frames and the WebSocket
  delegate live in `EngineConnectionProtocolFrames.swift`.
- `ios_thin_client_boundaries_stay_split` gates the split and rejects moved
  component, display, protocol-frame, or flow-type bodies returning to the broad
  parent files.

CLC-7 verification evidence from 2026-05-30:

- `cd packages/ios-app && xcodegen generate`: passed.
- `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/CapabilityInvocationDisplayModelTests -only-testing:TronMobileTests/NewSessionFlowTests -only-testing:TronMobileTests/EngineConnectionReconnectTests -only-testing:TronMobileTests/EngineConsoleStateTests`: passed, 54 selected tests after an initial split-access failure was fixed.

Closed CLC-7 acceptance:

- All touched iOS production-source roots are below 1,000 LOC.
- iOS remains a thin client: the checkpoint moved Swift presentation,
  component, protocol-frame, and state-type boundaries only. It did not add
  client-owned policy, routing, approval, generated-UI semantics, or product
  truth.
- No chat/session navigation behavior changed, so RWO-N17/deep-link simulator
  smoke was not required for this checkpoint.
- Large iOS test matrices remain audited rows for the test/harness cleanup
  lane; they are not production-source CLC-7 blockers.

## CLC-8 Mac App And Scripts Cleanup

CLC-8 is complete and has awarded **+3 normalized** points. The original
planning row called this **+8** effort; the normalized score keeps the total
cleanup score bounded at 100 while preserving the requirement that CLC-9 and
CLC-10 still close before the campaign is complete.

Accepted decomposition:

- `scripts/tron` is now the workspace CLI dispatcher and command-module loader,
  below 1,000 LOC. Workspace utilities and contributor binary restore helpers
  live in `scripts/tron.d/workspace.sh`; CI/bench helpers live in
  `scripts/tron.d/quality.sh`; dev takeover lives in `scripts/tron.d/dev.sh`;
  deploy/install/setup/preflight live in `scripts/tron.d/deploy.sh`; and
  auto-deploy/self-update wrappers live in `scripts/tron.d/automation.sh`.
- `scripts/tron-lib.sh` is now shared configuration, print helpers, profile
  seeding, and runtime-module loading, below 1,000 LOC. Installed-runtime
  service/status/dev-restore helpers live in `scripts/tron-lib.d/service.sh`;
  bundle/sign/notarize helpers live in `scripts/tron-lib.d/bundle.sh`; log
  query/result helpers live in `scripts/tron-lib.d/logs.sh`; auth/login/token
  helpers live in `scripts/tron-lib.d/auth.sh`.
- `tron install`, `tron setup`, and contributor deploy refreshes now copy
  `tron-lib.d/` beside `tron-lib.sh` so the installed `tron-cli` has the same
  runtime module set as the workspace script.
- The L3 trusted-local LaunchAgent plist invariant moved with
  `create_launchd_plist` into `scripts/tron.d/deploy.sh`.
- `mac_script_boundaries_stay_split` gates the split and rejects command bodies
  returning to the dispatcher/loader roots.
- `packages/agent/src/main.rs` is now a 59 LOC binary entry point that only
  installs the allocator, loads the CLI/runtime modules, dispatches auth
  subcommands, and calls `run_server`.
- `packages/agent/src/main_cli.rs` owns Clap parsing and auth CLI dispatch.
- `packages/agent/src/main_runtime.rs` owns server startup orchestration and
  remains below 1,000 LOC.
- `packages/agent/src/platform/updater/tests.rs` and
  `packages/agent/src/platform/apns/push_helpers_tests.rs` own the updater and
  APNS push-helper test matrices so production platform roots stay below 1,000
  LOC.

CLC-8 verification evidence from 2026-05-30:

- `bash -n scripts/tron scripts/tron.d/*.sh scripts/tron-lib.sh scripts/tron-lib.d/*.sh scripts/tron-cli scripts/auto-deploy scripts/reset-db`: passed.
- `scripts/tron status --json`: passed and reported a healthy `dev_takeover`
  listener on port 9847.
- `scripts/tron dev -bd --json --wait 30`: passed through the split scripts,
  rebuilt the dev server, launched PID `33706`, returned `mode=dev_takeover`
  and `healthy=true`, and
  wrote logs to `~/.tron/internal/run/tron-dev-background.log`.
- `curl -fsS http://localhost:9847/health`: passed with
  `{"status":"ok","uptime_secs":5,"connections":1,"active_sessions":1}`.
- `cargo test --manifest-path packages/agent/Cargo.toml cli_default_host -- --nocapture`: passed.
- `cargo test --manifest-path packages/agent/Cargo.toml parse_triple -- --nocapture`: passed.
- `cargo test --manifest-path packages/agent/Cargo.toml to_apns_notification_maps_all_fields -- --nocapture`: passed.
- `cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants -- --nocapture`: passed, 63 tests.
- `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`: passed.
- `git diff --check`: passed.

## CLC-9 Tests, Harnesses, And Static Gates

CLC-9 is complete and has awarded **+2 normalized** points. The original
planning row called this **+5** effort; the normalized score keeps CLC-10 as
the final required closeout before the cleanup campaign reaches 100/100.

Accepted decomposition and harness hardening:

- `packages/agent/src/domains/agent/runner/guardrails/tests.rs` is deleted.
  Shared fixtures live in `guardrails/tests/mod.rs`, and concern-owned test
  modules live in `serialization.rs`, `pattern_path_resource.rs`,
  `context_composite.rs`, and `engine_audit.rs`. Every guardrails test file is
  below 1,000 LOC.
- `rwo_n15_live_worker_fixture.py --self-test` now runs before live
  session/workspace visibility validation, matching the fixture self-test
  contract used by the other DB-classifying harness helpers.
- `test_harness_boundaries_stay_split` gates the guardrails split, fixture
  self-test surfaces, and RWO-N17 current-model simulator/deep-link
  multi-session evidence markers.

CLC-9 verification evidence from 2026-05-30:

- `cargo test --manifest-path packages/agent/Cargo.toml guardrails --lib -- --nocapture`: passed, 139 selected tests.
- `python3 packages/agent/tests/fixtures/rwo_n7_live_worker_fixture.py --self-test`: passed.
- `python3 packages/agent/tests/fixtures/rwo_n15_live_worker_fixture.py --self-test`: passed.
- `python3 packages/agent/tests/fixtures/session_terminal_guard.py --self-test`: passed.

## Large-File Audit

Baseline command:

```bash
find packages scripts \( -path '*/target/*' -o -path '*/.build/*' -o -path '*/DerivedData/*' \) -prune -o -type f \( -name '*.rs' -o -name '*.swift' -o -name '*.sh' -o -path 'scripts/tron' \) -print0 | xargs -0 wc -l | awk '$1 > 1000 && $2 != "total" {print $1 " " $2}' | sort -nr
```

| File | Current LOC | Owner | Reason | Budget | Decomposition checkpoint |
|------|-------------|-------|--------|--------|--------------------------|
| `packages/agent/tests/threat_model_invariants.rs` | 6917 | CLC-9 static gates | Cross-cutting architecture gates and cleanup scorecard enforcement, including CLC-1, CLC-2, CLC-3, CLC-4, CLC-5, CLC-6, CLC-7, CLC-8, and CLC-9 split-boundary gates plus full host-meta, host-runtime-host, host-handle-surface, module lifecycle/store/evidence, source-trust, manifest, grant, resource, schema, payload, action-catalog, session/storage/protocol, model-provider/profile, runner/context, smaller-domain, iOS thin-client, Mac script/startup/platform, and test harness subtree checks. | 7050 | CLC-9 |
| `packages/agent/tests/integration/tests.rs` | 3108 | CLC-9 harnesses | Transport e2e suite with shared WebSocket harness. | 3150 | CLC-9 |
| `packages/ios-app/Tests/Core/Events/UnifiedEventTransformerTests.swift` | 2848 | CLC-9 iOS tests | Event transformer matrix should split only when concepts separate. | 2900 | CLC-9 |
| `packages/agent/src/domains/worktree/implementation/runtime/coordinator/tests.rs` | 2712 | CLC-9 worktree tests | Worktree coordinator lifecycle matrix. | 2750 | CLC-9 |
| `packages/agent/src/engine/tests/generated_ui.rs` | 1865 | CLC-9 engine tests | Generated UI primitive matrix. | 1900 | CLC-9 |
| `packages/agent/src/domains/session/event_store/sqlite/repositories/event/tests.rs` | 1571 | CLC-9 session tests | SQLite event repository query matrix. | 1600 | CLC-9 |
| `packages/agent/src/domains/agent/runner/orchestrator/subagent_manager_tests.rs` | 1545 | CLC-9 runner tests | Subagent manager orchestration matrix. | 1575 | CLC-9 |
| `packages/agent/src/domains/auth/provider_credentials/storage/tests.rs` | 1383 | CLC-9 auth tests | Credential storage scenario matrix moved out of the implementation root during CLC-6. | 1425 | CLC-9 |
| `packages/agent/src/engine/tests/module_activation/source_trust.rs` | 1364 | CLC-9 engine tests | Module source-trust scenario matrix. | 1400 | CLC-9 |
| `packages/agent/src/domains/skills/implementation/runtime/tracker/tests.rs` | 1301 | CLC-9 skills tests | Skill runtime tracking scenario matrix moved out of the implementation root during CLC-6. | 1350 | CLC-9 |
| `packages/agent/src/domains/worktree/implementation/runtime/coordinator/rebase_on_main_tests.rs` | 1239 | CLC-9 worktree tests | Rebase-on-main conflict/recovery matrix. | 1275 | CLC-9 |
| `packages/agent/src/engine/tests/resource_kernel.rs` | 1207 | CLC-9 engine tests | Resource-kernel matrix. | 1250 | CLC-9 |
| `packages/agent/skills/vault/scripts/vault.sh` | 1200 | CLC-10 managed skills | Single managed skill entrypoint; split only with packaging/selftest verification. | 1225 | CLC-10 |
| `packages/agent/src/domains/agent/runner/agent/stream_processor_tests.rs` | 1177 | CLC-9 runner tests | Stream processor event-shape matrix. | 1200 | CLC-9 |
| `packages/agent/src/domains/agent/runner/context/context_manager_tests.rs` | 1164 | CLC-9 context tests | Context manager policy/rules matrix. | 1200 | CLC-9 |
| `packages/agent/src/shared/protocol/events/tron/catalog.rs` | 1153 | CLC-3 protocol | Exhaustive generated `TronEvent` enum catalog and accessors stay together for serde tagging, grep-ability, and match exhaustiveness without introducing a compatibility macro layer. | 1200 | CLC-3 |
| `packages/agent/src/domains/agent/runner/context/compaction_engine_tests.rs` | 1127 | CLC-9 context tests | Compaction engine scenario matrix. | 1175 | CLC-9 |
| `packages/ios-app/Tests/Infrastructure/EventDatabaseTests.swift` | 1038 | CLC-9 iOS tests | Event database test matrix. | 1075 | CLC-9 |

## Test Plan

Minimum per checkpoint:

- `git status --short`
- Targeted Rust/iOS/script tests for touched area.
- `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`
- `cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants -- --nocapture`
- `git diff --check`

Escalate to:

- `scripts/tron ci fmt check clippy test` for broad Rust/server changes.
- Focused `xcodebuild test` for iOS changes.
- `scripts/tron dev -bd --json --wait 30` for service/startup changes.
- RWO-N17 harness for multi-session, deep-link, or chat/engine parity changes.

## Assumptions And Defaults

- Scope is repo-local cleanup only; no PR publishing.
- The collapsed-engine scorecard remains separate and complete at **100/100**.
- Cleanup score starts as progress **0/100**, not as a functionality score.
- Behavior preservation is required unless the scenario ledger identifies a bug
  and root-cause fix.
- Current high-capability hosted models remain the primary scored model path.
  `gemma4:e4b` remains local substrate smoke only; larger local models are a
  later robustness lane.
- Installed `/Applications/Tron.app` may be stale during implementation; dev
  work should use the verified dev takeover path until the installed helper is
  updated.

## Next Scenario

Next checkpoint: **CLC-7 iOS Thin Client Cleanup**.

Begin the thin-client audit with `packages/ios-app/Sources/Views/`,
`packages/ios-app/Sources/ViewModels/`,
`packages/ios-app/Sources/Services/Network/`, and
`packages/ios-app/Sources/Models/`. Decompose large Swift presentation,
view-model, and transport files without moving policy, routing, approval,
generated UI semantics, or product truth into Swift. Preserve RWO-N17
deep-link/chat parity behavior for any navigation or session-view changes.
