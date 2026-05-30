# Codebase Cleanup Scorecard

Created: 2026-05-30

Initial cleanup score: **0/100**

Current score: **25/100**

Status: **CLC-2 in progress**

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
- CLC-2 resource, queue, approval, engine-type, generated-UI, and control
  boundaries must stay split: parent roots remain below 1,000 LOC while
  artifact/goal curation, materialized-file and patch mutation, payload
  parsing, shared resource-ref helpers, resource/UI schemas, queue draining,
  queue lifecycle stream projection, approval tests, catalog change DTOs, and
  control action catalogs stay in focused submodules.

## Scenario Ledger

| ID | Status | Score delta | Touched folders | Deleted complexity | Tests | Residual risks |
|----|--------|-------------|-----------------|--------------------|-------|----------------|
| CLC-0 | Complete | +10 | `scripts/`, `packages/agent/src/domains/capability/`, `packages/agent/src/shared/foundation/`, `packages/agent/tests/`, `README.md`, `packages/agent/docs/` | Replaced optimistic installed-service restore prints with one health-gated helper; moved the brittle recipe assertion to schema/display invariants instead of exact wording; made the capability schema provider surface a named contract. | `search_visible_content_contains_actionable_recipe`; `default_context_block_manifest_declares_capability_schema_surface`; `threat_model_invariants`; `scripts/tron dev -bd --json --wait 30`; `curl /health` | Installed `/Applications/Tron.app` can still be stale; no fallback compatibility is added, so the diagnostic requires reinstall/update. |
| CLC-1 | Complete | +15 | `packages/agent/src/domains/capability/operations/`, `packages/agent/src/domains/capability/registry/`, `packages/agent/src/domains/capability_support/` | Extracted `operations/{schema_validation,presentation,policy_profile,admin}.rs`, cutting `operations/mod.rs` from 4,917 to 959 LOC; extracted `operations/execute/{input,result,trigger_metadata}.rs`, cutting `operations/execute.rs` from 2,091 to 851 LOC; extracted `registry/{store,search_policy}.rs`, cutting `registry/mod.rs` from 4,960 to 936 LOC; split `registry/store.rs` into memory, projection, schema, SQLite helper, and SQLite runtime modules, cutting the root from 2,441 to 172 LOC; added the recipe-owned `AgentCapabilityRecipeDisplay` model so search, inspect/schema guidance, primer, and execute discovery rendering no longer rebuild recipe display rules locally; split registry, operations root, execute, and capability-support trait tests into concern-owned modules. | `search_visible_content_contains_actionable_recipe`, capability operations tests, capability registry tests, capability support trait tests, full `domains::capability`, and CLC-1 static gates passed after extraction. | None for CLC-1; future changes must keep all capability implementation files under budget or add a new scorecard exception. |
| CLC-2 | In progress | +0 awarded / +15 pending | `packages/agent/src/engine/`, `packages/agent/src/engine/primitives/`, `packages/agent/src/engine/resources/` | Split the resource primitive by ownership boundary: the parent `resource.rs` is now a registration/dispatch spine below 1,000 LOC, with artifact/goal curation, common wrapper/resource-ref helpers, payload parsing, materialized-file/patch mutation, and schemas in focused submodules. Split `engine/queue.rs` so the durable item/store file is below 1,000 LOC and queue draining plus lifecycle stream projection live in `engine/queue/runtime.rs`. Moved approval idempotency tests to `engine/approval/tests.rs`, leaving `approval.rs` below 1,000 LOC. Split catalog-change DTOs from `engine/types.rs` into `engine/types/catalog.rs`, leaving the public type export stable and the root below 1,000 LOC. Split generated-UI request/response schemas from `primitives/ui.rs` into `primitives/ui/schemas.rs`, leaving the generated-UI root below 1,000 LOC. Split control action catalog definitions from `primitives/control.rs` into `primitives/control/actions.rs`, leaving the control root below 1,000 LOC. Remaining target: split host/module/registry/ledger/grants by ownership boundary, separate orchestration from mutation, make transitions atomic. | `engine::tests::resource_kernel`, `engine::tests::state_queue`, `sqlite_queue_blobs_large_payload_but_claim_returns_original_payload`, `engine::approval::tests`, `engine::tests::ids_types`, and `engine::tests::generated_ui` passed for the completed CLC-2 slices; CLC-2 resource, queue, approval, engine-type, generated-UI, and control static gates added. Module and broader engine gates still pending for final CLC-2 award. | Terminal-state behavior is sensitive; CLC-2 remains unawarded until the remaining engine-fabric hotspots are decomposed and verified. |
| CLC-3 | Not started | +12 | `packages/agent/src/domains/session/`, `packages/agent/src/shared/protocol/`, `packages/agent/src/shared/storage.rs` | Target: separate DTOs from reconstruction/mutation, remove stringly event handling when a typed dispatcher exists, keep README schema list accurate. | Session/event-store tests and README contract gates. | DB schema docs can drift quickly if migrations move. |
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

CLC-2 is in progress and has awarded **+0** of its **+15** points.

Accepted partial decomposition:

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

CLC-2 partial verification evidence from 2026-05-30:

- `cargo test --manifest-path packages/agent/Cargo.toml engine::tests::resource_kernel --lib -- --nocapture`: passed, 18 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml engine::tests::state_queue --lib -- --nocapture`: passed, 7 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml sqlite_queue_blobs_large_payload_but_claim_returns_original_payload --lib -- --nocapture`: passed.
- `cargo test --manifest-path packages/agent/Cargo.toml engine::approval::tests --lib -- --nocapture`: passed, 2 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml engine::tests::ids_types --lib -- --nocapture`: passed, 2 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml engine::tests::generated_ui --lib -- --nocapture`: passed, 23 tests.

Open CLC-2 acceptance work:

- Split the next engine-fabric hotspots by ownership boundary:
  `primitives/module.rs`, `host.rs`, `primitives/module/source_trust.rs`,
  `registry.rs`, `ledger.rs`, `grants.rs`, and
  resource-store/generate-UI files where the audit finds a direct simplification
  path.
- Run focused queue/resource/module/generated UI tests and static gates before
  awarding CLC-2 points.

## Large-File Audit

Baseline command:

```bash
find packages scripts \( -path '*/target/*' -o -path '*/.build/*' -o -path '*/DerivedData/*' \) -prune -o -type f \( -name '*.rs' -o -name '*.swift' -o -name '*.sh' -o -path 'scripts/tron' \) -print0 | xargs -0 wc -l | awk '$1 > 1000 && $2 != "total" {print $1 " " $2}' | sort -nr
```

| File | Current LOC | Owner | Reason | Budget | Decomposition checkpoint |
|------|-------------|-------|--------|--------|--------------------------|
| `packages/agent/tests/threat_model_invariants.rs` | 5863 | CLC-9 static gates | Cross-cutting architecture gates and cleanup scorecard enforcement, including CLC-1 and CLC-2 split-boundary gates. | 5900 | CLC-9 |
| `packages/agent/src/engine/primitives/module.rs` | 3832 | CLC-2 engine primitives | Module lifecycle, trust, and policy orchestration need ownership splits. | 3900 | CLC-2 |
| `packages/agent/src/domains/model/providers/openai/types.rs` | 3576 | CLC-4 providers | Provider DTO shapes and conversion concerns are too concentrated. | 3650 | CLC-4 |
| `packages/agent/src/engine/host.rs` | 3387 | CLC-2 engine host | Host orchestration and mutation concerns remain dense. | 3450 | CLC-2 |
| `packages/agent/tests/integration/tests.rs` | 3108 | CLC-9 harnesses | Transport e2e suite with shared WebSocket harness. | 3150 | CLC-9 |
| `packages/agent/src/domains/session/event_store/store/tests.rs` | 3083 | CLC-3 session tests | Single event-store API matrix. | 3150 | CLC-3 |
| `packages/agent/src/shared/protocol/events.rs` | 2899 | CLC-3 protocol | Event DTOs and reconstruction adjacency need splitting. | 2950 | CLC-3 |
| `packages/ios-app/Tests/Core/Events/UnifiedEventTransformerTests.swift` | 2848 | CLC-7 iOS tests | Event transformer matrix should split only when concepts separate. | 2900 | CLC-7 |
| `packages/agent/src/engine/primitives/module/source_trust.rs` | 2738 | CLC-2 module trust | Source trust scenario logic is large. | 2800 | CLC-2 |
| `packages/agent/src/domains/worktree/implementation/scm/git.rs` | 2726 | CLC-6 worktree | Git coordinator carries many command families. | 2750 | CLC-6 |
| `packages/agent/src/domains/worktree/implementation/runtime/coordinator/tests.rs` | 2712 | CLC-6 worktree tests | Worktree coordinator lifecycle matrix. | 2750 | CLC-6 |
| `packages/agent/src/domains/session/event_store/event/reconstruct.rs` | 2377 | CLC-3 event reconstruction | Reconstruction and DTO interpretation are concentrated. | 2400 | CLC-3 |
| `packages/agent/src/shared/foundation/profile.rs` | 2041 | CLC-4 profile surface | Profile parsing, context contracts, and tests are dense. | 2050 | CLC-4 |
| `packages/agent/src/domains/session/event_store/sqlite/repositories/session.rs` | 1996 | CLC-3 session repository | Session repository mixes query and mutation behavior. | 2050 | CLC-3 |
| `scripts/tron` | 1959 | CLC-8 CLI | Single script owns many command families and dev restore paths. | 2050 | CLC-8 |
| `packages/agent/src/domains/cron/implementation/runtime/scheduler.rs` | 1927 | CLC-6 cron | Scheduler orchestration and mutation should split. | 1950 | CLC-6 |
| `packages/agent/src/engine/registry.rs` | 1891 | CLC-2 registry | Engine registry logic remains broad. | 1925 | CLC-2 |
| `packages/agent/src/domains/auth/provider_credentials/storage.rs` | 1887 | CLC-6 auth | Credential storage helpers need canonical boundary review. | 1925 | CLC-6 |
| `packages/agent/src/engine/tests/generated_ui.rs` | 1865 | CLC-9 engine tests | Generated UI primitive matrix. | 1900 | CLC-9 |
| `packages/ios-app/Sources/Views/EngineConsole/EngineConsoleView.swift` | 1857 | CLC-7 iOS views | Console view should split into focused view models/components. | 1900 | CLC-7 |
| `scripts/tron-lib.sh` | 1878 | CLC-8 CLI lib | Shared shell helpers are becoming a broad service layer. | 1950 | CLC-8 |
| `packages/agent/src/transport/engine_ws.rs` | 1741 | CLC-3 transport/protocol | Engine WebSocket framing and routing are dense. | 1775 | CLC-3 |
| `packages/agent/src/shared/storage.rs` | 1703 | CLC-3 storage | Shared storage helpers need contract review. | 1725 | CLC-3 |
| `packages/agent/src/domains/agent/runner/guardrails/tests.rs` | 1695 | CLC-9 runner tests | Guardrail rule-pattern matrix. | 1725 | CLC-9 |
| `packages/agent/src/engine/primitives/ui/authoring/mod.rs` | 1667 | CLC-2 generated UI | Generated UI authoring should split by primitive concern. | 1700 | CLC-2 |
| `packages/agent/src/domains/skills/implementation/runtime/tracker.rs` | 1629 | CLC-6 skills | Runtime tracking has multiple ownership concerns. | 1650 | CLC-6 |
| `packages/agent/src/domains/agent/runner/agent/capability_invocation_executor.rs` | 1596 | CLC-5 runner | Invocation continuation state should split from turn orchestration. | 1625 | CLC-5 |
| `packages/agent/src/domains/session/event_store/sqlite/repositories/event/tests.rs` | 1571 | CLC-9 session tests | SQLite event repository query matrix. | 1600 | CLC-9 |
| `packages/agent/src/domains/agent/runner/orchestrator/subagent_manager_tests.rs` | 1545 | CLC-9 runner tests | Subagent manager orchestration matrix. | 1575 | CLC-9 |
| `packages/agent/src/domains/model/providers/anthropic/types.rs` | 1517 | CLC-4 providers | Anthropic DTO shapes are dense. | 1550 | CLC-4 |
| `packages/agent/src/engine/ledger.rs` | 1502 | CLC-2 ledger | Ledger mutation and projection logic should split. | 1525 | CLC-2 |
| `packages/agent/src/engine/resources/store.rs` | 1483 | CLC-2 resources | Resource store mutation/query concerns should split. | 1500 | CLC-2 |
| `packages/agent/src/domains/session/event_store/sqlite/migrations/mod.rs` | 1466 | CLC-3 migrations | Migration runner and schema docs need separation. | 1500 | CLC-3 |
| `packages/agent/src/domains/agent/runner/hooks/engine.rs` | 1461 | CLC-5 hooks | Hook orchestration is broad. | 1500 | CLC-5 |
| `packages/ios-app/Sources/Models/Messages/CapabilityInvocationTypes.swift` | 1440 | CLC-7 iOS models | Capability invocation presentation model is too broad. | 1475 | CLC-7 |
| `packages/agent/src/engine/tests/module_activation/source_trust.rs` | 1364 | CLC-9 engine tests | Module source-trust scenario matrix. | 1400 | CLC-9 |
| `packages/agent/src/platform/updater/mod.rs` | 1339 | CLC-8 Mac/platform | Updater behavior should split by concern if touched. | 1375 | CLC-8 |
| `packages/agent/src/engine/primitives/runtime.rs` | 1332 | CLC-2 runtime | Runtime primitive orchestration is dense. | 1350 | CLC-2 |
| `packages/agent/src/engine/grants.rs` | 1324 | CLC-2 grants | Grant transitions should be clearer and atomic. | 1350 | CLC-2 |
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
| `packages/agent/src/engine/primitives/module/trust_audit.rs` | 1156 | CLC-2 module trust | Trust audit scheduling/status logic is dense. | 1200 | CLC-2 |
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

Next checkpoint: **CLC-2 Engine Fabric Simplification**.

Begin the engine fabric audit with `packages/agent/src/engine/`,
`packages/agent/src/engine/primitives/`, and
`packages/agent/src/engine/resources/`. Measure the current large files, split
only along ownership boundaries, and preserve the collapsed substrate gates for
queues, streams, resources, grants, approvals, modules, and generated UI.
