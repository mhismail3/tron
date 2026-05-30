# Codebase Cleanup Scorecard

Created: 2026-05-30

Initial cleanup score: **0/100**

Current score: **52/100**

Status: **CLC-3 complete; CLC-4 next**

This scorecard is the repo-local maintainability plan. It is separate from
`collapsed-engine-hardening-scorecard.md`, which remains at **100/100** for
collapsed-engine robustness. Cleanup points measure completed audit,
simplification, tests, documentation, and useful static gates. They do not
claim product functionality is missing.

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

## Scenario Ledger

| ID | Status | Score delta | Touched folders | Deleted complexity | Tests | Residual risks |
|----|--------|-------------|-----------------|--------------------|-------|----------------|
| CLC-0 | Complete | +10 | `scripts/`, `packages/agent/src/domains/capability/`, `packages/agent/src/shared/foundation/`, `packages/agent/tests/`, `README.md`, `packages/agent/docs/` | Replaced optimistic installed-service restore prints with one health-gated helper; moved the brittle recipe assertion to schema/display invariants instead of exact wording; made the capability schema provider surface a named contract. | `search_visible_content_contains_actionable_recipe`; `default_context_block_manifest_declares_capability_schema_surface`; `threat_model_invariants`; `scripts/tron dev -bd --json --wait 30`; `curl /health` | Installed `/Applications/Tron.app` can still be stale; no fallback compatibility is added, so the diagnostic requires reinstall/update. |
| CLC-1 | Complete | +15 | `packages/agent/src/domains/capability/operations/`, `packages/agent/src/domains/capability/registry/`, `packages/agent/src/domains/capability_support/` | Extracted `operations/{schema_validation,presentation,policy_profile,admin}.rs`, cutting `operations/mod.rs` from 4,917 to 959 LOC; extracted `operations/execute/{input,result,trigger_metadata}.rs`, cutting `operations/execute.rs` from 2,091 to 851 LOC; extracted `registry/{store,search_policy}.rs`, cutting `registry/mod.rs` from 4,960 to 936 LOC; split `registry/store.rs` into memory, projection, schema, SQLite helper, and SQLite runtime modules, cutting the root from 2,441 to 172 LOC; added the recipe-owned `AgentCapabilityRecipeDisplay` model so search, inspect/schema guidance, primer, and execute discovery rendering no longer rebuild recipe display rules locally; split registry, operations root, execute, and capability-support trait tests into concern-owned modules. | `search_visible_content_contains_actionable_recipe`, capability operations tests, capability registry tests, capability support trait tests, full `domains::capability`, and CLC-1 static gates passed after extraction. | None for CLC-1; future changes must keep all capability implementation files under budget or add a new scorecard exception. |
| CLC-2 | Complete | +15 | `packages/agent/src/engine/`, `packages/agent/src/engine/primitives/`, `packages/agent/src/engine/resources/` | Split the resource primitive by ownership boundary: the parent `resource.rs` is now a registration/dispatch spine below 1,000 LOC, with artifact/goal curation, common wrapper/resource-ref helpers, payload parsing, materialized-file/patch mutation, and schemas in focused submodules. Split `engine/resources/store.rs` so the root is below 1,000 LOC; event/id helpers, SQLite schema/row/JSON codecs, and store tests now live in focused `resources/store/*` submodules. Split `engine/queue.rs` so the durable item/store file is below 1,000 LOC and queue draining plus lifecycle stream projection live in `engine/queue/runtime.rs`. Moved approval idempotency tests to `engine/approval/tests.rs`, leaving `approval.rs` below 1,000 LOC. Split catalog-change DTOs from `engine/types.rs` into `engine/types/catalog.rs`, leaving the public type export stable and the root below 1,000 LOC. Split generated-UI request/response schemas from `primitives/ui.rs` into `primitives/ui/schemas.rs`, leaving the generated-UI root below 1,000 LOC. Split generated-UI action authoring from `primitives/ui/authoring/mod.rs` into `primitives/ui/authoring/actions.rs`, leaving both below 1,000 LOC. Split control action catalog definitions from `primitives/control.rs` into `primitives/control/actions.rs`, leaving the control root below 1,000 LOC. Split persisted invocation outcome projection and SQLite schema/row/JSON codecs from `engine/ledger.rs` into `engine/ledger/outcome.rs` and `engine/ledger/sqlite_codec.rs`, leaving the ledger root below 1,000 LOC. Split grant record/request/bootstrap/event builders and SQLite row/risk/JSON codecs from `engine/grants.rs` into `engine/grants/model.rs` and `engine/grants/sqlite_codec.rs`, leaving the grants root below 1,000 LOC. Split `primitives/runtime.rs` so the root host-dispatched query dispatcher is below 1,000 LOC, worker protocol guide projection lives in `primitives/runtime/worker_protocol.rs`, and the executable Python template is readable source in `primitives/runtime/worker_protocol_template.py`. Split `engine/registry.rs` so the live-catalog root is below 1,000 LOC while catalog-change recording, sync invocation/idempotency lifecycle, and output-contract enforcement live in focused `engine/registry/*` submodules. Split `module/trust_audit.rs` so the action/status/retention root is below 1,000 LOC while schedule parsing and due-bucket calculation live in `module/trust_audit/schedule.rs`. Split `module/source_trust.rs` into registration, verification, approval, lifecycle, policy, inspection, support, and schema submodules, leaving every source-trust implementation file below 1,000 LOC. Split the module registration catalogue into `module/registrations.rs`, package manifest validation/runtime parsing into `module/manifest.rs`, module grant policy into `module/grants.rs`, module resource helpers into `module/resources.rs`, base request/response schemas into `module/schemas.rs`, payload parsing/secret enforcement helpers into `module/payload.rs`, server-authored action catalogs into `module/actions.rs`, store access into `module/store_access.rs`, package registration/configuration/inspection into `module/package_lifecycle.rs`, activation/upgrade/rollback/disable/quarantine orchestration into `module/activation_lifecycle.rs`, and decision/evidence resource creation into `module/evidence.rs`, cutting `module.rs` to 207 LOC. Split engine host meta-function constants, watch DTOs, schemas, visibility projection, delegated invocation shaping, and payload parsers into `engine/host/meta.rs`; split the host-dispatched primitive runtime implementation into `engine/host/runtime_host.rs`; split host-handle constructors, catalog operations, module-maintenance queue producers, invocation orchestration, invocation support helpers, and substrate-store methods into focused `engine/host/*` submodules, cutting `host.rs` to 815 LOC. CLC-2 is closed; final verification covered queue/resource/module/generated UI/host/static gates without regressions. | `engine::tests::resource_kernel`, `engine::resources::store`, `engine::tests::state_queue`, `sqlite_queue_blobs_large_payload_but_claim_returns_original_payload`, `engine::approval::tests`, `engine::tests::ids_types`, `engine::tests::generated_ui`, `engine::tests::ledger_idempotency`, `engine::tests::grant_authority`, `engine::tests::meta_primitives`, `engine::tests::catalog_discovery`, `engine::tests::host_invocation`, `engine::tests::module_activation`, and `threat_model_invariants` passed for the completed CLC-2 slices; CLC-2 resource, resource-store, queue, approval, engine-type, generated-UI, generated-UI authoring, control, ledger, grant, runtime, registry, host meta, host runtime host, host handle/substrate/invocation, module store-access, package-lifecycle, activation-lifecycle, evidence, resource, grant, manifest, registration, schema, payload, action, trust-audit, and source-trust large-file gates added. Final CLC-2 broad engine and static gates passed. | None for CLC-2; terminal-state behavior remains guarded by later runner/chat parity checkpoints. |
| CLC-3 | Complete | +12 | `packages/agent/src/domains/session/`, `packages/agent/src/shared/protocol/`, `packages/agent/src/shared/storage.rs`, `packages/agent/src/transport/` | Split session dashboard projections and session tests out of the session repository root; split event reconstruction, migration, and event-store API tests into scenario-owned children; split protocol events into capability, factory, stream, Tron support, generated Tron catalog, and focused tests; split shared storage into archive, schema, payload, maintenance, stats, and tests; split `/engine` WebSocket wire DTOs, stream projection, outbound serialization, and tests from the transport flow root. | `domains::session::event_store`, `shared::storage`, `shared::events`, `transport::engine_ws`, CLC-3 static gate, formatting, and diff checks passed after extraction. | `events/tron/catalog.rs` remains an explicit 1,153 LOC exception because the exhaustive serde-tagged `TronEvent` catalog and accessor macro are clearer in one audited file than in a synthetic compatibility layer. |
| CLC-4 | Not started | +10 | `packages/agent/src/domains/model/providers/`, `packages/agent/src/domains/model/provider_protocol/`, `packages/agent/src/domains/model/providers/shared/`, `packages/agent/src/shared/foundation/profile.rs`, `packages/agent/src/shared/foundation/constitution.rs` | Target: split provider wire concerns, isolate provider spellings at boundaries, make context-block provider surfaces explicit and typed. | Provider parsing tests and RWO-N14 provider parity harness availability. | Local `gemma4:e4b` is substrate smoke only; hosted high-capability models stay primary scored path. |
| CLC-5 | Not started | +12 | `packages/agent/src/domains/agent/runner/`, `packages/agent/src/domains/agent/runtime/`, `packages/agent/src/domains/context/` | Target: reduce turn-runner, compaction, hook, and capability invocation executor sprawl; separate turn orchestration from provider result handling and continuation state. | Context, compaction, stream processor, subagent, and simulator terminal-state harnesses. | Chat/engine parity issues remain tracked for later UI polish but cannot introduce product-state side channels. |
| CLC-6 | Not started | +10 | `packages/agent/src/domains/worktree/`, `packages/agent/src/domains/cron/`, `packages/agent/src/domains/process/`, `packages/agent/src/domains/auth/`, `packages/agent/src/domains/settings/`, `packages/agent/src/domains/skills/` | Target: split coordinators/schedulers, keep process policy and sandbox materialization process-owned, remove bespoke storage/auth helpers where canonical helpers exist. | Targeted domain tests and settings parity checks. | Settings changes must update iOS parity in the same checkpoint. |
| CLC-7 | Not started | +10 | `packages/ios-app/Sources/Views/`, `packages/ios-app/Sources/ViewModels/`, `packages/ios-app/Sources/Services/Network/`, `packages/ios-app/Sources/Models/` | Target: decompose `EngineConsoleView.swift`, `CapabilityInvocationTypes.swift`, `EngineConnection.swift`, `NewSessionFlow.swift`, and `CapabilityInvocationViews.swift`; keep iOS thin. | Focused iOS tests, `xcodegen generate`, simulator deep-link smoke for navigation changes. | Server-owned policy/routing/generated UI semantics must not move into Swift. |
| CLC-8 | Not started | +8 | `packages/mac-app/Sources/`, `packages/mac-app/docs/`, `scripts/tron`, `scripts/tron-lib.sh` | Target: decompose CLI scripts by command family, centralize health checks across foreground/background/dev/restore, keep Mac wrapper observer/manager only. | Mac service tests where available and manual `scripts/tron dev` recovery smoke. | Service restore paths touch user LaunchAgents; avoid optimistic messages. |
| CLC-9 | Not started | +5 | `packages/agent/tests/`, `packages/agent/src/**/tests*`, `packages/agent/tests/fixtures/` | Target: split large tests only when it reduces concepts, keep harnesses scenario-owned and DB-classifying, preserve RWO-N17 as canonical multi-session simulator regression. | `threat_model_invariants`, fixture self-tests, harness smoke. | Static gates should not become a dumping ground for local unit assertions. |
| CLC-10 | Not started | +3 | Whole repo | Target: final file-size report, close or defer rows explicitly, run broad verification appropriate to touched areas, update README only for changed canonical modules/CLI/contracts/events/settings/schema. | Broad verification by touched area. | Final score requires every open exception to be closed or explicitly deferred. |

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
- Next cleanup phase is CLC-4 model providers and context surfaces.

## Large-File Audit

Baseline command:

```bash
find packages scripts \( -path '*/target/*' -o -path '*/.build/*' -o -path '*/DerivedData/*' \) -prune -o -type f \( -name '*.rs' -o -name '*.swift' -o -name '*.sh' -o -path 'scripts/tron' \) -print0 | xargs -0 wc -l | awk '$1 > 1000 && $2 != "total" {print $1 " " $2}' | sort -nr
```

| File | Current LOC | Owner | Reason | Budget | Decomposition checkpoint |
|------|-------------|-------|--------|--------|--------------------------|
| `packages/agent/tests/threat_model_invariants.rs` | 6365 | CLC-9 static gates | Cross-cutting architecture gates and cleanup scorecard enforcement, including CLC-1, CLC-2, and CLC-3 split-boundary gates plus full host-meta, host-runtime-host, host-handle-surface, module lifecycle/store/evidence, source-trust, manifest, grant, resource, schema, payload, action-catalog, and session/storage/protocol subtree checks. | 6500 | CLC-9 |
| `packages/agent/src/domains/model/providers/openai/types.rs` | 3576 | CLC-4 providers | Provider DTO shapes and conversion concerns are too concentrated. | 3650 | CLC-4 |
| `packages/agent/tests/integration/tests.rs` | 3108 | CLC-9 harnesses | Transport e2e suite with shared WebSocket harness. | 3150 | CLC-9 |
| `packages/ios-app/Tests/Core/Events/UnifiedEventTransformerTests.swift` | 2848 | CLC-7 iOS tests | Event transformer matrix should split only when concepts separate. | 2900 | CLC-7 |
| `packages/agent/src/domains/worktree/implementation/scm/git.rs` | 2726 | CLC-6 worktree | Git coordinator carries many command families. | 2750 | CLC-6 |
| `packages/agent/src/domains/worktree/implementation/runtime/coordinator/tests.rs` | 2712 | CLC-6 worktree tests | Worktree coordinator lifecycle matrix. | 2750 | CLC-6 |
| `packages/agent/src/shared/foundation/profile.rs` | 2041 | CLC-4 profile surface | Profile parsing, context contracts, and tests are dense. | 2050 | CLC-4 |
| `scripts/tron` | 1959 | CLC-8 CLI | Single script owns many command families and dev restore paths. | 2050 | CLC-8 |
| `packages/agent/src/domains/cron/implementation/runtime/scheduler.rs` | 1927 | CLC-6 cron | Scheduler orchestration and mutation should split. | 1950 | CLC-6 |
| `packages/agent/src/domains/auth/provider_credentials/storage.rs` | 1887 | CLC-6 auth | Credential storage helpers need canonical boundary review. | 1925 | CLC-6 |
| `packages/agent/src/engine/tests/generated_ui.rs` | 1865 | CLC-9 engine tests | Generated UI primitive matrix. | 1900 | CLC-9 |
| `packages/ios-app/Sources/Views/EngineConsole/EngineConsoleView.swift` | 1857 | CLC-7 iOS views | Console view should split into focused view models/components. | 1900 | CLC-7 |
| `scripts/tron-lib.sh` | 1878 | CLC-8 CLI lib | Shared shell helpers are becoming a broad service layer. | 1950 | CLC-8 |
| `packages/agent/src/domains/agent/runner/guardrails/tests.rs` | 1695 | CLC-9 runner tests | Guardrail rule-pattern matrix. | 1725 | CLC-9 |
| `packages/agent/src/domains/skills/implementation/runtime/tracker.rs` | 1629 | CLC-6 skills | Runtime tracking has multiple ownership concerns. | 1650 | CLC-6 |
| `packages/agent/src/domains/agent/runner/agent/capability_invocation_executor.rs` | 1596 | CLC-5 runner | Invocation continuation state should split from turn orchestration. | 1625 | CLC-5 |
| `packages/agent/src/domains/session/event_store/sqlite/repositories/event/tests.rs` | 1571 | CLC-9 session tests | SQLite event repository query matrix. | 1600 | CLC-9 |
| `packages/agent/src/domains/agent/runner/orchestrator/subagent_manager_tests.rs` | 1545 | CLC-9 runner tests | Subagent manager orchestration matrix. | 1575 | CLC-9 |
| `packages/agent/src/domains/model/providers/anthropic/types.rs` | 1517 | CLC-4 providers | Anthropic DTO shapes are dense. | 1550 | CLC-4 |
| `packages/agent/src/domains/agent/runner/hooks/engine.rs` | 1461 | CLC-5 hooks | Hook orchestration is broad. | 1500 | CLC-5 |
| `packages/ios-app/Sources/Models/Messages/CapabilityInvocationTypes.swift` | 1440 | CLC-7 iOS models | Capability invocation presentation model is too broad. | 1475 | CLC-7 |
| `packages/agent/src/engine/tests/module_activation/source_trust.rs` | 1364 | CLC-9 engine tests | Module source-trust scenario matrix. | 1400 | CLC-9 |
| `packages/agent/src/platform/updater/mod.rs` | 1339 | CLC-8 Mac/platform | Updater behavior should split by concern if touched. | 1375 | CLC-8 |
| `packages/ios-app/Sources/Services/Network/EngineConnection.swift` | 1319 | CLC-7 iOS network | Engine connection should stay transport-only. | 1350 | CLC-7 |
| `packages/agent/src/domains/model/providers/openai/stream_handler.rs` | 1319 | CLC-4 providers | OpenAI stream handling should split by wire concern. | 1350 | CLC-4 |
| `packages/agent/src/domains/process/mod.rs` | 1298 | CLC-6 process | Process policy and execution materialization should stay process-owned and split when touched. | 1325 | CLC-6 |
| `packages/agent/src/domains/agent/runner/hooks/prompt_handler.rs` | 1291 | CLC-5 hooks | Prompt hook handling is broad. | 1325 | CLC-5 |
| `packages/agent/src/domains/model/providers/google/types.rs` | 1260 | CLC-4 providers | Google DTO shapes are dense. | 1300 | CLC-4 |
| `packages/agent/src/domains/agent/runner/agent/compaction_handler.rs` | 1254 | CLC-5 context | Compaction handling should stay isolated from turn orchestration. | 1300 | CLC-5 |
| `packages/agent/src/domains/worktree/implementation/runtime/coordinator/rebase_on_main_tests.rs` | 1239 | CLC-9 worktree tests | Rebase-on-main conflict/recovery matrix. | 1275 | CLC-9 |
| `packages/agent/src/engine/tests/resource_kernel.rs` | 1207 | CLC-9 engine tests | Resource-kernel matrix. | 1250 | CLC-9 |
| `packages/agent/src/domains/agent/runner/agent/turn_runner/capability_invocations.rs` | 1203 | CLC-5 runner | Capability invocation turn continuation logic is dense. | 1250 | CLC-5 |
| `packages/agent/skills/vault/scripts/vault.sh` | 1200 | CLC-6 skills | Managed vault script exceeds source budget. | 1225 | CLC-6 |
| `packages/agent/src/domains/agent/runner/agent/turn_runner.rs` | 1190 | CLC-5 runner | Turn runner should remain orchestration only. | 1225 | CLC-5 |
| `packages/agent/src/domains/model/providers/google/provider.rs` | 1177 | CLC-4 providers | Google provider orchestration is dense. | 1200 | CLC-4 |
| `packages/agent/src/domains/agent/runner/agent/stream_processor_tests.rs` | 1177 | CLC-9 runner tests | Stream processor event-shape matrix. | 1200 | CLC-9 |
| `packages/agent/src/domains/agent/runner/context/context_manager_tests.rs` | 1164 | CLC-9 context tests | Context manager policy/rules matrix. | 1200 | CLC-9 |
| `packages/agent/src/shared/protocol/events/tron/catalog.rs` | 1153 | CLC-3 protocol | Exhaustive generated `TronEvent` enum catalog and accessors stay together for serde tagging, grep-ability, and match exhaustiveness without introducing a compatibility macro layer. | 1200 | CLC-3 |
| `packages/agent/src/domains/cron/implementation/execution/executor.rs` | 1140 | CLC-6 cron | Cron executor orchestration is dense. | 1175 | CLC-6 |
| `packages/agent/src/domains/agent/runner/context/compaction_engine_tests.rs` | 1127 | CLC-9 context tests | Compaction engine scenario matrix. | 1175 | CLC-9 |
| `packages/agent/src/domains/model/providers/anthropic/message_converter.rs` | 1118 | CLC-4 providers | Anthropic conversion logic is broad. | 1150 | CLC-4 |
| `packages/agent/src/main.rs` | 1112 | CLC-8 startup | Main startup should stay bootstrap-only. | 1150 | CLC-8 |
| `packages/ios-app/Sources/Views/Session/NewSessionFlow.swift` | 1111 | CLC-7 iOS views | New-session flow needs focused view model boundaries. | 1150 | CLC-7 |
| `packages/agent/src/domains/model/providers/anthropic/stream_handler.rs` | 1087 | CLC-4 providers | Anthropic stream handling should split by wire concern. | 1125 | CLC-4 |
| `packages/agent/src/domains/model/providers/ollama/message_converter.rs` | 1070 | CLC-4 providers | Ollama conversion logic is dense. | 1100 | CLC-4 |
| `packages/ios-app/Sources/Views/Capabilities/CapabilityInvocationViews.swift` | 1065 | CLC-7 iOS views | Capability invocation UI should stay presentation-only. | 1100 | CLC-7 |
| `packages/agent/src/domains/agent/runner/orchestrator/orchestrator.rs` | 1053 | CLC-5 runner | Orchestration logic should split from state mutation. | 1075 | CLC-5 |
| `packages/agent/src/platform/apns/push_helpers.rs` | 1045 | CLC-8 platform | Push helper concerns should split if touched. | 1075 | CLC-8 |
| `packages/ios-app/Tests/Infrastructure/EventDatabaseTests.swift` | 1038 | CLC-7 iOS tests | Event database test matrix. | 1075 | CLC-7 |
| `packages/agent/src/domains/agent/runner/orchestrator/session_manager.rs` | 1035 | CLC-5 runner | Session manager state updates should stay focused. | 1075 | CLC-5 |
| `packages/agent/src/domains/model/providers/anthropic/provider.rs` | 1019 | CLC-4 providers | Anthropic provider orchestration is dense. | 1050 | CLC-4 |
| `packages/agent/src/domains/agent/runner/orchestrator/turn_accumulator.rs` | 1012 | CLC-5 runner | Turn accumulation should stay isolated. | 1050 | CLC-5 |
| `packages/agent/src/domains/mcp/product_protocol/client.rs` | 1010 | CLC-6 MCP | Product protocol client is near budget and should split if touched. | 1050 | CLC-6 |
| `packages/agent/src/shared/foundation/paths.rs` | 1007 | CLC-6 foundation | Path constants/helpers are near budget and guarded for personal info. | 1050 | CLC-6 |
| `packages/agent/src/domains/auth/provider_credentials/openai.rs` | 1005 | CLC-6 auth | OpenAI auth helper is near budget. | 1050 | CLC-6 |

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

Next checkpoint: **CLC-4 Model Providers And Context Surfaces**.

Begin the provider/context audit with
`packages/agent/src/domains/model/providers/`,
`packages/agent/src/domains/model/provider_protocol/`,
`packages/agent/src/domains/model/providers/shared/`,
`packages/agent/src/shared/foundation/profile.rs`, and
`packages/agent/src/shared/foundation/constitution.rs`. Measure the current
large files, split only along provider wire/context ownership boundaries, keep
provider-specific spellings isolated at provider edges, and preserve provider
parity harnesses plus canonical capability-layer terminology.
