# Primitive Engine Teardown Evidence Manifest

Created: 2026-06-06

Scorecard: [`primitive-engine-teardown-scorecard.md`](primitive-engine-teardown-scorecard.md)

Current score: **92/100**

Status: **active execution artifact**

This manifest records command, simulator, database, source-audit, and commit
evidence for the primitive engine teardown campaign. Rows are intentionally
empty until each scorecard row runs. Do not award points in the scorecard
without adding concrete evidence here.

## Baseline Branch Point

- Source branch before teardown: `next/modular-capability-engine`.
- Existing worker-first checkpoint: completed at 100/100 before this branch.
- New teardown branch: `codex/primitive-engine-teardown`.
- Compatibility assumption: none. This branch may delete old capability names,
  old DTOs, old product tables, old UI modes, and old docs without migration
  support.
- PET-0 checkpoint status: plan, manifest, README link, and static gate were
  added on the teardown branch.

## Row Evidence

| Row | Status | Evidence summary | Commands / artifacts | Residual risk |
|-----|--------|------------------|----------------------|---------------|
| PET-0 | passed_after_fix | Formalized the clean-break primitive-engine teardown plan, companion evidence manifest, README living-doc link, and static invariant test. Existing iOS action/docs checkpoint was committed before branching so the branch point was clean. | `xcodebuild test -project TronMobile.xcodeproj -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/tron-xcode-codex-actions-check -only-testing:TronMobileTests/SourceGuardTests` -> exit 0, 17 Swift Testing tests passed, result bundle `/tmp/tron-xcode-codex-actions-check/Logs/Test/Test-Tron-2026.06.06_18-46-49--0700.xcresult`; `git switch -c codex/primitive-engine-teardown` -> exit 0; red/green plan gate fixed Markdown wrapping and Rust formatting; `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` -> exit 0; `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants -- --nocapture` -> exit 0, 1 passed; `git diff --check` -> exit 0. | None for planning. PET-1 owns source inventory before deletion. |
| PET-1 | passed_after_fix | Added the source-audited PET-1 deletion inventory and README living-doc link. The inventory classifies all current Rust domain roots, engine primitive workers, runner context planes, first-party managed skills, agent docs, iOS source/view roots, and settings surfaces as retain/delete/successor before behavior deletion. Red/green proof: the covering invariant was added first and failed because the inventory file was absent, then passed after the inventory/scorecard/manifest updates. Checkpoint commit: `6b80e8590`. Open loops are recorded in the inventory and remain owned by PET-2 through PET-11. | `find packages/agent/src/domains -mindepth 1 -maxdepth 1 -type d -exec basename {} \; \| sort` -> exit 0; `sed -n '1,180p' packages/agent/src/domains/registration.rs` -> exit 0; `rg -n "pub\\(crate\\) const .*_WORKER_ID\|pub\\(crate\\) mod" packages/agent/src/engine/primitives/mod.rs` -> exit 0; `sed -n '1,140p' packages/agent/src/domains/agent/runner/context/mod.rs` -> exit 0; `find packages/agent/skills -mindepth 1 -maxdepth 1 -type d -exec basename {} \; \| sort` -> exit 0; `find packages/agent/docs -maxdepth 1 -type f \| sort` -> exit 0; `find packages/ios-app/Sources/Views -mindepth 1 -maxdepth 1 -type d -exec basename {} \; \| sort` -> exit 0; `find packages/agent/src/domains/settings/implementation/types -type f -name '*.rs' -maxdepth 1 -print \| sort` -> exit 0; red gate `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants -- --nocapture` -> exit 101, `primitive_engine_teardown_inventory_stays_exhaustive` failed on missing `primitive-engine-teardown-inventory.md`; green rerun `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants -- --nocapture` -> exit 0, 2 passed; `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` -> exit 0; `git diff --check` -> exit 0. | Classification mistakes can preserve product code; PET-2 through PET-10 must execute against the map and PET-11 must adversarially revisit every retained/successor classification. |
| PET-2 | passed_after_fix | Removed product/tool domain registration from startup and narrowed `agent::*` registration to prompt-loop infrastructure. Deleted public agent product operations for goal runs, work snapshots, user-question pauses, subagent status/result/cancel, and public queue management. The startup catalog now keeps `capability::execute` plus boot/provider/session infrastructure and rejects retired product namespaces. README capability docs now describe the branch primitive surface instead of the retired worker-first catalog/router. Checkpoint commit: `6d208beec`. | Red `cargo test --manifest-path packages/agent/Cargo.toml --lib primitive_teardown_startup_catalog_excludes_deleted_product_domains -- --nocapture` -> exit 101, old startup catalog still contained retired namespaces. Green rerun -> exit 0, 1 passed, 5731 filtered out, 455 dead-code warnings from unregistered product modules. Broad verification `cargo test --manifest-path packages/agent/Cargo.toml --lib primitive -- --nocapture` -> exit 0, 43 passed, 5690 filtered out, 455 dead-code warnings. `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` -> exit 0; `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants -- --nocapture` -> exit 0, 2 passed; `git diff --check` -> exit 0. Additional cleanup: removed dead capability admin schema helpers, dead `agent.queue` stream publisher, and stale agent module docs. | Product modules are absent from registration but still declared/compiled; the 455 warnings are PET-10/PET-5 deletion evidence, not acceptable final state. Session/event/UI tests still contain old product names until their rows run. |
| PET-3 | passed_after_fix | Collapsed provider export and `capability::execute` behavior to the primitive loop. OpenAI tool conversion now exports only function `execute` with no hosted `tool_search`/`defer_loading`. `capability::execute` directly implements `observe`, `state_get`, `state_set`, `state_list`, `file_read`, `file_write`, and `process_run`, with no capability registry recipe, vector search, binding, plugin, conformance, or policy routing dependency. Added run-loop proof that a mock provider calls `execute`, receives the `observe` result in the next turn context, and continues to final assistant text. Checkpoint commit: `6d208beec`. | Red `cargo test --manifest-path packages/agent/Cargo.toml --lib primitive_execute_observes_without_registry_routing -- --nocapture` -> exit 101, old execute rejected `observe`; green rerun -> exit 0, 1 passed. Red `cargo test --manifest-path packages/agent/Cargo.toml --lib convert_tools_v2_never_exports_hosted_tool_search_for_primitive_branch -- --nocapture` -> exit 101, converter emitted hosted tool search; green rerun -> exit 0, 1 passed. New integration proof `cargo test --manifest-path packages/agent/Cargo.toml --lib primitive_loop_calls_execute_observes_result_and_continues -- --nocapture` -> exit 0, 1 passed, provider called `execute` and continued after the result. Broad verification `cargo test --manifest-path packages/agent/Cargo.toml --lib primitive -- --nocapture` -> exit 0, 43 passed, including `model_capability_invocation_invokes_execute_primitive_through_engine`. | Context assembly still carries policy/rules/skills/hooks/subagent/job abstractions. OpenAI hosted-tool-search DTO/model support remains compiled but behavior-disabled; PET-10 must delete it with the provider absence gates. PET-4/PET-6 must delete context planes before context is primitive. |
| PET-4 | passed_after_fix | Collapsed provider context and runtime context assembly to the primitive soul/state model. Provider `Context` now carries `system_prompt`, messages, `execute` capability summaries, environment, and `agent_state_context`; the old rules/memory/skill/job/hook/capability-primer fields were removed. `AGENT_SOUL` is a short audited seed, runtime prompt building loads agent-owned state through the primitive state namespace, and context snapshots now expose only system/capability/environment/message/provider-adjustment token accounting. The red static gate failed on hidden prompt-loop planes before the prompt loop was rewritten; the green rerun proves those planes are absent from the factory, agent, turn runner, capability phase/executor, compaction handler, context manager/types, and primitive surface resolver. | Red `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants prompt_loop_internals_have_no_hidden_policy_or_worker_planes -- --nocapture` -> exit 101, static gate found `GuardrailEngine`/old policy-worker planes in prompt-loop internals. Green rerun after rewrite -> exit 0, 1 passed. `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants -- --nocapture` -> exit 0, 4 passed. `cargo test --manifest-path packages/agent/Cargo.toml --lib agent_state_context_reads_session_state_namespace -- --nocapture` -> exit 0, 1 passed. `cargo test --manifest-path packages/agent/Cargo.toml --lib primitive_loop_calls_execute_observes_result_and_continues -- --nocapture` -> exit 0, 1 passed. `cargo test --manifest-path packages/agent/Cargo.toml --lib model_capability_invocation_invokes_execute_primitive_through_engine -- --nocapture` -> exit 0, 1 passed. `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` -> exit 0. `git diff --check` -> exit 0. | Self-adapting behavior beyond state persistence is successor work. Startup/server context still exposes retired registries/managers and remains PET-6/PET-10 cleanup, not PET-4 prompt context. |
| PET-5 | passed_after_fix | Collapsed fresh session storage and typed event truth to primitive loop-owned surfaces. The session migration runner now registers only `v001_schema.sql`; old product follow-up migrations `v002_constitution_audit.sql`, `v004_session_profile.sql`, and `v005_drop_profile_migrations.sql` were deleted. Fresh session schema has no branches, device tokens, cron tables, constitution audit tables, profiles, origins/sources, worktree overrides, or subagent spawn fields. Session/blob/log repositories and row types were adjusted to the new schema, including a primitive uncompressed-size blob column. Typed event payload registration now exposes only session/message/capability/stream/compact/context/metadata/error/turn modules, and generated event types now contain 23 loop-owned variants. Prompt queue, config mutation, rules preload/activation, and interruption notification event writes were removed or mapped to primitive turn failure. README database and event-system docs were rewritten for the retained surface. | Red PET-5 static suite before implementation: `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants -- --nocapture` -> exit 101, old schema still exposed product tables and generated event surface still exposed deleted product payload modules. Intermediate red after schema collapse -> exit 101, schema still contained the deleted session-origin column and the blob size column still matched the origin absence gate. Green compile proof `cargo check --manifest-path packages/agent/Cargo.toml --bin tron` -> exit 0, with PET-10 warning backlog. Green static proof `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants -- --nocapture` -> exit 0, 9 passed. | Dead unregistered source and cfg-test fixtures still mention removed product events/tables; PET-10 owns physical deletion and warning cleanup. iOS reconstruction/UI cleanup remains PET-8. |
| PET-6 | passed_after_fix | Deleted startup/server policy and product manager wiring from the retained runtime context: skill registry, memory registry, subagent manager, hook abort tracker, guardrail engine, device broker, MCP, cron, worktree, transcription, process/job/output managers, profile-derived execute policy metadata, and old capability support config are no longer part of startup or retained domain deps. Retained contracts no longer encode approval-required/high-risk policy metadata. Engine registration no longer requires approval metadata or keeps sandbox/conditional approval exceptions. Removed root settings for hooks, skills, prompt library, MCP, and guardrails; obsolete guardrail and prompt-library root settings now fail deserialization. Deleted `tron-program-worker` bin target, prompt runtime worktree acquisition, the program-worker process test, and dev/CI/release/Mac bundle/backup/restore/rollback packaging paths for the removed secondary helper. | Wrong first command `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants startup_context_has_no_product_policy_or_worker_managers retained_registered_contracts_do_not_encode_approval_or_policy_planes -- --nocapture` -> exit 1, Cargo rejected multiple filters. Red static suite `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants -- --nocapture` -> exit 101, 4 passed/2 failed: startup still contained `SkillRegistry`; retained agent contract still contained `.approval_required(`. Green static suite after startup/contract teardown -> exit 0, 6 passed. Focused compile proof `cargo test --manifest-path packages/agent/Cargo.toml --lib agent_state_context_reads_session_state_namespace -- --nocapture` first failed on stale session/settings tests for deleted worktree/guardrail/prompt-library settings, then green rerun -> exit 0, 1 passed. Primitive-loop regressions first failed because engine registration still raised `PolicyViolation("irreversible agent-visible function system::shutdown requires approval metadata")`; after deleting approval metadata policy/exceptions, `cargo test --manifest-path packages/agent/Cargo.toml --lib primitive_loop_calls_execute_observes_result_and_continues -- --nocapture` -> exit 0, 1 passed, and `cargo test --manifest-path packages/agent/Cargo.toml --lib model_capability_invocation_invokes_execute_primitive_through_engine -- --nocapture` -> exit 0, 1 passed. Packaging invariant `cargo test --manifest-path packages/agent/Cargo.toml --test threat_model_invariants tron_helper_is_built_and_packaged_as_single_binary -- --nocapture` -> exit 0, 1 passed. `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` -> exit 0. `cargo check --manifest-path packages/agent/Cargo.toml --bin tron` -> exit 0, with the recorded PET-10 warning backlog. Final PET-6 static suite `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants -- --nocapture` -> exit 0, 7 passed. `git diff --check` -> exit 0. | `cargo test`/`cargo check` still report many dead-code/missing-doc warnings from retained compiled source; PET-10 owns warning cleanup and physical deletion of unregistered product modules. PET-7 owns remaining self-authored substrate/worker-pack teardown. |
| PET-7 | passed_after_fix | Removed the first-party self-authored worker/capability substrate rather than leaving it dormant: deleted module primitive registration/source, worker protocol guide/template source, module activation/runtime jobs, module health monitor, worker package/module config/activation resource kinds, module lifecycle control actions, generated UI package/config/activation projections, capability registry source, old execute router helpers/tests, and README descriptions for the deleted helper-launch path. The retained `capability::execute` implementation remains a direct primitive operation endpoint, and retained `/engine/workers` documentation now treats external workers as host infrastructure rather than a provider-visible launch flow. | Red `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants self_authored_worker_pack_primitives_are_not_registered_or_left_on_disk -- --nocapture` -> exit 101, old primitive registration still contained `MODULE_WORKER_ID`. Red `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants capability_registry_recipe_and_conformance_scaffolding_is_deleted -- --nocapture` -> exit 101, old `packages/agent/src/domains/capability/registry` still existed. Green targeted reruns -> exit 0, 1 passed each. First `cargo fmt --manifest-path packages/agent/Cargo.toml --all` -> exit 1 because `engine/tests/mod.rs` still declared deleted `module_activation`; after removing the declaration, rerun -> exit 0. `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` -> exit 0. `cargo check --manifest-path packages/agent/Cargo.toml --bin tron` -> exit 0, with 293 lib warnings plus 1 bin warning. `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants -- --nocapture` -> exit 0, 11 passed. PET-7 absence scans for module/worker-guide strings and retired capability registry phrases -> exit 1/no matches. `git diff --check` -> exit 0. | Broader compiled source still emits dead-code/missing-doc warnings and still contains product-era test files/invariant references outside the PET-7 retained surface; PET-10 owns full warning cleanup and physical dead-source teardown. iOS fixed surfaces remain PET-8. |
| PET-8 | passed_after_fix | Removed the fixed iOS product shell: Work, Audit Details, Source Control, Prompt Library, Voice Notes, Skills, Agent Control, Subagents, Worktree UI/state/client/plugin/test roots, stale prompt-library/voice-note/worktree/subagent DTOs, orphan analytics/event-card tests, and the retired `capability-ui.md` doc. Retained the chat/session/input/onboarding/settings shell, local event reconstruction, generic capability evidence rendering, and `GeneratedRuntimeSurfaceView`. Visual proof found a real primitive-shell issue: a clean launch requested push notification permission before an active server was paired. `TronMobileApp.registerPushIfAuthorized()` now returns unless `pairedServerStore.activeServer` exists, and SourceGuard records that invariant. Checkpoint commit: `d7b2e3735`. | Red guard proof `xcodebuild test -project TronMobile.xcodeproj -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/tron-xcode-pet8-red-suite -only-testing:TronMobileTests/SourceGuardTests` -> exit 65, fixed-product guard failed before deletion; result bundle `/tmp/tron-xcode-pet8-red-suite/Logs/Test/Test-Tron-2026.06.06_23-06-55--0700.xcresult`. Project regeneration `cd packages/ios-app && xcodegen generate` -> exit 0. Green proof `xcodebuild test -project TronMobile.xcodeproj -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/tron-xcode-pet8-green-7 -only-testing:TronMobileTests/SourceGuardTests` -> exit 0, 18 Swift Testing tests passed; result bundle `/tmp/tron-xcode-pet8-green-7/Logs/Test/Test-Tron-2026.06.07_00-41-27--0700.xcresult`. Absence scan `rg -n "worktree|Worktree|subagent|Subagent|VoiceNotes|voiceNotes|VoiceNote|voice note|voice_notes|PromptLibrary|promptHistory|SourceControl|AuditDetails|AgentControl|useWorktree|agent::spawn_subagent|agent::subagent|canCommitWorktree|canManageSkills|ConsolidatedAnalytics|ProcessedEventItem|processEventsForTurn|CapabilityClient|SkillClient|SkillStore|PromptLibraryClient|VoiceNotesRecorder|GitClient" packages/ios-app/Sources packages/ios-app/Tests packages/ios-app/TronMobile.xcodeproj/project.pbxproj -g '!SourceGuardTests.swift'` -> exit 1/no matches. Simulator bundle id: `com.tron.mobile.beta`; app product `/tmp/tron-xcode-pet8-green-7/Build/Products/Beta-iphonesimulator/TronMobile.app`. iPhone proof on iPhone 17 Pro iOS 26.5 UDID `7BDA4AF9-1C40-47E3-A925-0F88C191F263`: boot rc 0, bootstatus rc 0, uninstall rc 0, install rc 0, `defaults write com.tron.mobile.beta onboardingComplete -bool YES` rc 0, launch rc 0, screenshot rc 0 at `/tmp/tron-pet8-ui/pet8-iphone17pro-ios265-shell-final.png`. iPad proof on iPad Pro 13-inch (M5) iOS 26.5 UDID `099FE1B6-28C6-4028-A60F-28BDE4849BE5`: boot rc 0, bootstatus rc 0, uninstall rc 0, install rc 0, onboarding defaults rc 0, launch rc 0, screenshot rc 0 at `/tmp/tron-pet8-ui/pet8-ipadpro13-ios265-shell-final.png`. | Some retained iOS domain clients/views outside the explicit PET-8 fixed product surfaces still need PET-10/PET-11 adversarial audit against the final one-capability model. Dynamic surface sophistication is successor work. |
| PET-9 | passed_after_fix | Active documentation and managed assets now match the primitive branch surface. `packages/agent/docs/` contains only the active scorecard, evidence manifest, and inventory; `packages/agent/skills/` is physically absent; relay/APNs docs, product scorecards, product guides, and stale first-party skill assets were deleted instead of marked legacy. README, iOS docs, Mac docs, project guidance, and reset-db docs now describe retained primitive behavior or deletion evidence only. | `find packages/agent/docs -maxdepth 1 -type f | sort` -> exit 0, only active teardown docs; `test ! -d packages/agent/skills` -> exit 0; `test ! -d packages/relay` -> exit 0 after tracked relay sources and ignored generated relay output were removed; `test ! -f packages/ios-app/docs/apns.md` -> exit 0. README/iOS/Mac/project docs were updated in this checkpoint. | PET-11 still audits retained code-level surfaces and any doc language that might imply runnable deleted behavior. Deleted feature names may remain in active absence gates, inventories, and evidence. |
| PET-10 | passed_after_fix | Traceability checkpoint plus dead-source cleanup now pass. Fresh storage includes `trace_records`; `capability::execute` writes running/success/failure trace records with request/result hashes, authority envelope, provider/model metadata, VCS revision when available, and file attribution/content hashes; `trace_list` and `trace_get` expose those records through the sole model-facing `execute` primitive. Follow-up teardown physically deleted the public `context::*` capability plane, capability-policy settings, push relay/APNs/device-token path, stale typed iOS clients, notification inbox/delivery surfaces, server file-browser/workspace validation, and Rust warning wrappers. | Earlier PET-10 red/green evidence is preserved below. Current cleanup proof: `cargo fmt --manifest-path packages/agent/Cargo.toml --all` -> exit 0; `cargo check --manifest-path packages/agent/Cargo.toml --bin tron` -> exit 0 with no warnings; `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants -- --nocapture` -> exit 0, 15 tests; `cargo test --manifest-path packages/agent/Cargo.toml --test db_path_guard -- --nocapture` -> exit 0, 13 tests; `cargo test --manifest-path packages/agent/Cargo.toml capability_policy_settings_are_rejected -- --nocapture` -> exit 0; `cargo test --manifest-path packages/agent/Cargo.toml settings_tables_deep_merge_and_arrays_replace -- --nocapture` -> exit 0; `cargo test --manifest-path packages/agent/Cargo.toml default_settings_are_valid -- --nocapture` -> exit 0; `cargo test --manifest-path packages/agent/Cargo.toml --lib -- --nocapture` -> exit 0, 2975 tests; `cd packages/ios-app && xcodegen generate` -> exit 0; `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/SourceGuardTests` -> exit 0, 19 Swift Testing tests passed, result bundle `~/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.07_06-53-25--0700.xcresult`; `git diff --check` -> exit 0; stale-symbol scans for context/settings/relay/APNs/typed-client leftovers returned no actionable matches outside absence tests/evidence. | PET-11 owns final adversarial retained-surface audit and end-to-end proof. No known PET-10 warning or full-lib-test blocker remains. |
| PET-11 | running | Interim adversarial retained-surface passes removed non-primitive hosted-tool/computer-control residue, stale capability catalog/status/search/inspect/recipe/program/audit/policy DTOs, product-specific result summaries, resolved-catalog identity fields, Mac Screen Recording/Accessibility onboarding gates, iOS draft skill/spell residue, the iOS/Rust user-interaction pause/submit-answer plane, unreferenced iOS repo/task DTOs, fixed iOS process and SessionTree projections, the top-level Rust `capability_support` abstraction, the product update-check surface, the legacy image-only prompt request path, fixed `system::get_diagnostics`, generic `LogStore` query DTOs, inert observability payload-capture settings, the one-case iOS diagnostics settings section, server-owned dynamic UI target authoring/catalog/refresh surfaces, queue/trigger/prompt pre-execution catalog pins, public/iOS invoke/promote expected function revision tokens, the stale function revision error path, the `control::*` projection primitive plus iOS control DTO, and public engine/meta/catalog/worker/WebSocket catalog readout fields. OpenAI Responses support serializes only concrete function tools; retained capability evidence carries primitive name, operation, trace/root ids, theme color, presentation hints, status/result/duration, and runtime details. Dynamic UI is a schema-versioned runtime resource renderer and action-submission recorder. Queue, trigger, and prompt envelopes no longer carry target revisions, expected function revisions, target function ids, or catalog revisions before execution. Public `engine::invoke`, `engine::promote`, external worker invocation, iOS invoke frames, and the capability executor no longer require expected function revisions before execution. Control snapshot/inspect projection is deleted rather than trimmed. Retained public catalog revisions remain only as `catalog::watch_snapshot`/`engine::watch` cursors; child invocation function/catalog revisions remain execution evidence. Retained logs are compact evidence storage and are model-visible only through `execute.log_recent` beside `trace_list`/`trace_get`. Draft persistence stores only text, attachment metadata, and update time; prompt media flows through unified attachments; session fork lineage remains only in session/event truth; provider primitive surface resolution lives directly in the agent runner. The Mac onboarding slice gates only Full Disk Access. | Rust proof includes warning-free `cargo check --manifest-path packages/agent/Cargo.toml --bin tron`, PET-11 invariant suites, OpenAI/provider surface tests, primitive trace/log execution tests, unified attachment tests, dynamic-surface absence tests, queue/trigger/prompt envelope absence tests, engine invocation/transport expected-revision absence tests, control-projection absence tests, public catalog-readout absence tests, and default settings validation. iOS proof includes project regeneration, SourceGuard, generated UI DTO/renderer, settings parity/state/model/layout tests, capability/event reconstruction, draft repository/store, process-dashboard absence, prompt attachment, engine protocol frames, and session lineage/reconstruction runs. Mac proof includes project regeneration and focused menu/permission/path/uninstaller runs. Latest public catalog-readout proof: red targeted gate -> exit 101 on `currentCatalogRevision`; after implementation, `cargo check --manifest-path packages/agent/Cargo.toml --bin tron` -> exit 0; targeted and full absence gates -> exit 0; meta primitive, WebSocket, host invocation, catalog discovery, and public transport schema tests -> exit 0; iOS protocol frame and SourceGuard tests -> exit 0; scoped residue scan -> exit 1/no matches. Addenda below preserve exact command detail by slice. | PET-11 is not closed. Remaining audit targets include final fresh server/DB/trace proof, iPhone/iPad closeout screenshots, and the final retained-surface sweep. |

### PET-11 Queue, Trigger, And Prompt Envelope Flattening Addendum

This checkpoint removes pre-execution catalog/function state from the retained
queue, trigger, and prompt envelopes:

- `EngineQueueItem` and `EnqueueInvocation` no longer store `target_revision`,
  and the fresh SQLite queue table/codec no longer has a `target_revision`
  column;
- queue drains invoke the current target function with the original authority,
  trace, session, workspace, trigger, idempotency, runtime metadata, and payload
  only;
- trigger definitions no longer pin target revisions, registration no longer
  validates stale trigger target revisions, queued trigger dispatch no longer
  carries expected target revision state, and `trigger::dispatch` returns only
  the dispatched invocation id rather than target/catalog identity fields;
- prompt child invocation and prompt auto-drain no longer inspect the catalog
  before enqueueing just to stamp expected function revisions;
- prompt stream/runtime/persisted-user-message payloads no longer emit
  `catalogRevision` or `expectedFunctionRevision`.

Evidence:

- Red proof:
  `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants queue_trigger_and_prompt_envelopes_do_not_pin_preexecution_catalog_state -- --nocapture`
  -> exit 101 before implementation; the new invariant failed on
  `targetRevision`.
- `cargo fmt --manifest-path packages/agent/Cargo.toml --all` -> exit 0.
- `cargo check --manifest-path packages/agent/Cargo.toml --bin tron`
  -> exit 0.
- Targeted green proof:
  `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants queue_trigger_and_prompt_envelopes_do_not_pin_preexecution_catalog_state -- --nocapture`
  -> exit 0, 1 test.
- Full PET-11 invariant suite:
  `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants -- --nocapture`
  -> exit 0, 23 tests.
- Queue/trigger behavior:
  `cargo test --manifest-path packages/agent/Cargo.toml --lib state_queue -- --nocapture`
  -> exit 0, 8 tests;
  `cargo test --manifest-path packages/agent/Cargo.toml --lib triggers -- --nocapture`
  -> exit 0, 15 tests.
- Public/meta and worker transport regressions:
  `cargo test --manifest-path packages/agent/Cargo.toml --lib meta_primitives -- --nocapture`
  -> exit 0, 10 tests;
  `cargo test --manifest-path packages/agent/Cargo.toml --lib ledger_idempotency -- --nocapture`
  -> exit 0, 11 tests;
  `cargo test --manifest-path packages/agent/Cargo.toml --lib external_worker -- --nocapture`
  -> exit 0, 16 tests;
  `cargo test --manifest-path packages/agent/Cargo.toml --lib primitive_loop_calls_execute_observes_result_and_continues -- --nocapture`
  -> exit 0, 1 test.
- Scoped residue scan:
  `rg -n "targetRevision|target_revision|expectedFunctionRevision|expected_function_revision|targetFunctionId|catalogRevision" packages/agent/src/engine/queue.rs packages/agent/src/engine/queue/runtime.rs packages/agent/src/engine/queue/sqlite_codec.rs packages/agent/src/engine/primitives/queue.rs packages/agent/src/engine/triggers.rs packages/agent/src/engine/primitives/trigger.rs packages/agent/src/engine/types.rs packages/agent/src/engine/policy.rs packages/agent/src/domains/agent/operations/prompt.rs packages/agent/src/domains/agent/runtime/service/deps.rs packages/agent/src/domains/agent/runtime/service/events.rs packages/agent/src/domains/agent/runtime/service/execute.rs packages/agent/src/domains/agent/runtime/service/queue.rs packages/agent/src/domains/agent/stream.rs`
  -> exit 1/no matches.

Residual risk: this addendum intentionally does not close all catalog/revision
surfaces. Current function/catalog revisions still exist in host integrity,
promotion, catalog/watch, worker transport, and invocation/trace evidence. The
next PET-11 pass must decide which public engine/meta/control/transport
revision fields are primitive resource/version truth and which are removable
API envelope state.

### PET-11 Invocation Transport Expected-Revision Teardown Addendum

This checkpoint removes the remaining caller-held function revision token from
live engine invocation and promotion paths:

- `Invocation` no longer stores `expected_function_revision` and the
  `.expecting_revision(...)` builder is deleted;
- live catalog and host invocation preparation no longer compare caller-supplied
  expected function revisions before execution;
- `engine::invoke`, `engine::promote`, public `/engine` wire DTOs, and public
  transport contract schemas no longer accept `expectedRevision` or
  `expectedFunctionRevision`;
- external worker invocation DTOs no longer carry expected function revisions;
- iOS `EngineInvocationOptions` and outgoing invoke frames no longer expose
  expected revision fields;
- the capability executor no longer pins a resolved target function revision
  before calling the engine;
- the stale function revision error variant, public error code, and mapping are
  deleted as dead compatibility code;
- README public transport docs now describe authority/idempotency instead of
  caller-held revision state.

Evidence:

- Red proof:
  `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants engine_invocation_and_transport_do_not_require_expected_revision_tokens -- --nocapture`
  -> exit 101 before implementation; the new invariant failed on
  `expectedFunctionRevision`.
- `cargo fmt --manifest-path packages/agent/Cargo.toml --all` -> exit 0.
- Targeted green proof:
  `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants engine_invocation_and_transport_do_not_require_expected_revision_tokens -- --nocapture`
  -> exit 0, 1 test.
- Compile proof:
  `cargo check --manifest-path packages/agent/Cargo.toml --bin tron`
  -> exit 0.
- Focused runtime and transport proof:
  `cargo test --manifest-path packages/agent/Cargo.toml --lib host_invocation -- --nocapture`
  -> exit 0, 14 tests;
  `cargo test --manifest-path packages/agent/Cargo.toml --lib meta_primitives -- --nocapture`
  -> exit 0, 10 tests;
  `cargo test --manifest-path packages/agent/Cargo.toml --lib engine_ws -- --nocapture`
  -> exit 0, 10 tests;
  `cargo test --manifest-path packages/agent/Cargo.toml --lib external_worker -- --nocapture`
  -> exit 0, 16 tests;
  `cargo test --manifest-path packages/agent/Cargo.toml --lib capability_invocation_executor -- --nocapture`
  -> exit 0, 8 tests.
- iOS proof:
  `cd packages/ios-app && xcodegen generate` -> exit 0;
  `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/EngineProtocolBaseTypesTests/testEngineFunctionCallEncoding -only-testing:TronMobileTests/EngineProtocolBaseTypesTests/testEngineFunctionCallResponseDecoding`
  -> exit 0, 2 XCTest tests, result bundle
  `~/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.07_11-12-22--0700.xcresult`.
- Scoped residue scan:
  `rg -n "expectedFunctionRevision|expected_function_revision|expectedRevision|expected_revision|expecting_revision|StaleFunctionRevision|stale_function_revision|STALE_FUNCTION_REVISION" README.md packages/agent/src/engine/host.rs packages/agent/src/engine/host/meta.rs packages/agent/src/engine/invocation.rs packages/agent/src/engine/registry/invocation.rs packages/agent/src/engine/protocol.rs packages/agent/src/engine/external.rs packages/agent/src/engine/ledger/outcome.rs packages/agent/src/engine/errors.rs packages/agent/src/transport/engine_ws.rs packages/agent/src/transport/engine_ws/wire.rs packages/agent/src/transport/contracts.rs packages/agent/src/engine/tests/host_invocation.rs packages/agent/src/engine/tests/meta_primitives.rs packages/agent/src/engine/tests/external_worker.rs packages/agent/src/domains/agent/runner/agent/capability_invocation_executor.rs packages/agent/src/shared/server/error_mapping.rs packages/agent/src/shared/server/errors.rs packages/ios-app/Sources/Models/EngineProtocol/EngineProtocolTypes.swift packages/ios-app/Sources/Services/Network/EngineConnection.swift packages/ios-app/Sources/Services/Network/EngineConnectionProtocolFrames.swift`
  -> exit 1/no matches.

Residual risk: this addendum deliberately leaves state compare-and-set
`expectedRevision` fields under `state::*`; those are resource-version
primitives, not invocation/catalog state. Catalog/function revisions still exist
as post-execution ledger/trace evidence and as catalog/watch resource-version
truth. PET-11 still needs to challenge public catalog readouts and control
snapshots before closeout.

### PET-11 Control Projection Primitive Teardown Addendum

This checkpoint deletes the retained operator projection surface instead of
trimming its catalog readout:

- `control::snapshot` and `control::inspect` are removed from primitive worker
  registration and host-dispatched runtime routing;
- `packages/agent/src/engine/primitives/control.rs` is deleted;
- the stale iOS `ControlSnapshotDTO` file is deleted and the Xcode project is
  regenerated;
- trace graph projection helpers and store-backend trace/list wrappers that
  only existed for `control::inspect` are removed rather than left as dead code.

Evidence:

- Red proof:
  `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants control_projection_primitive_is_deleted -- --nocapture`
  -> exit 101 before implementation; the new invariant failed on
  `CONTROL_WORKER_ID`.
- `cargo fmt --manifest-path packages/agent/Cargo.toml --all` -> exit 0.
- Initial post-delete checks failed on the control-only trace projection
  helpers becoming unused. Owner: engine architecture cleanup. Fixed by
  deleting the trace graph helpers and backing runtime-host wrappers.
- `cargo check --manifest-path packages/agent/Cargo.toml --bin tron`
  -> exit 0.
- Targeted green proof:
  `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants control_projection_primitive_is_deleted -- --nocapture`
  -> exit 0, 1 test.
- Full teardown invariant suite:
  `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants -- --nocapture`
  -> exit 0, 25 tests.
- Focused runtime proof:
  `cargo test --manifest-path packages/agent/Cargo.toml --lib meta_primitives -- --nocapture`
  -> exit 0, 10 tests;
  `cargo test --manifest-path packages/agent/Cargo.toml --lib catalog_discovery -- --nocapture`
  -> exit 0, 16 tests.
- iOS project regeneration:
  `cd packages/ios-app && xcodegen generate` -> exit 0.
- iOS source-guard proof:
  `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/SourceGuardTests`
  -> exit 0, 26 Swift Testing tests passed, result bundle
  `~/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.07_11-25-40--0700.xcresult`.
- Residue scan:
  `rg -n "CONTROL_WORKER_ID|control::snapshot|control::inspect|ControlSnapshotDTO|mod control|control::registrations|control::dispatch" packages/agent/src packages/ios-app/Sources packages/ios-app/Tests packages/ios-app/project.yml README.md`
  -> exit 1/no matches.
- `git diff --check` -> exit 0.

Residual risk: public catalog/worker readout fields were removed in the
following PET-11 checkpoint. Control projection itself has no known retained
surface.

### PET-11 Public Catalog Readout Flattening Addendum

This checkpoint removes catalog revision state from public client/readout
envelopes while retaining revision truth only where it is a cursor or execution
evidence:

- `/engine` hello responses no longer send `currentCatalogRevision`;
- generic `/engine` response envelopes and Swift response frames no longer carry
  top-level `catalogRevision`;
- public transport schemas for `discover`, `inspect`, and `promote` no longer
  require or describe catalog revision readouts;
- `engine::discover`, `engine::inspect`, `engine::promote`, `catalog::list`,
  `catalog::inspect`, and `worker::list` no longer return catalog revision
  side channels;
- the primitive runtime host no longer exposes a dead `catalog_revision`
  accessor just for readout responses;
- `engine::invoke` keeps child invocation `functionRevision`/`catalogRevision`
  as execution evidence, and catalog watch responses keep `currentRevision` and
  `nextRevision` as cursor truth.

Evidence:

- Red proof:
  `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants public_catalog_readout_state_is_not_client_envelope_state -- --nocapture`
  -> exit 101 before implementation; the new invariant failed on
  `currentCatalogRevision`.
- `cargo fmt --manifest-path packages/agent/Cargo.toml --all` -> exit 0.
- Targeted green proof:
  `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants public_catalog_readout_state_is_not_client_envelope_state -- --nocapture`
  -> exit 0, 1 test.
- Compile proof:
  `cargo check --manifest-path packages/agent/Cargo.toml --bin tron`
  -> exit 0.
- Full teardown invariant suite:
  `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants -- --nocapture`
  -> exit 0, 26 tests.
- Focused runtime/transport proof:
  `cargo test --manifest-path packages/agent/Cargo.toml --lib meta_primitives -- --nocapture`
  -> exit 0, 10 tests;
  `cargo test --manifest-path packages/agent/Cargo.toml --lib engine_ws -- --nocapture`
  -> exit 0, 10 tests;
  `cargo test --manifest-path packages/agent/Cargo.toml --lib host_invocation -- --nocapture`
  -> exit 0, 14 tests;
  `cargo test --manifest-path packages/agent/Cargo.toml --lib catalog_discovery -- --nocapture`
  -> exit 0, 16 tests;
  `cargo test --manifest-path packages/agent/Cargo.toml --lib promote_transport_response_schema_matches_engine_promote_result -- --nocapture`
  -> exit 0, 1 test.
- iOS proof:
  `cd packages/ios-app && xcodegen generate` -> exit 0;
  `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/EngineProtocolBaseTypesTests/testEngineFunctionCallEncoding -only-testing:TronMobileTests/EngineProtocolBaseTypesTests/testEngineFunctionCallResponseDecoding`
  -> exit 0, 2 XCTest tests, result bundle
  `~/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.07_11-32-52--0700.xcresult`;
  `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/SourceGuardTests`
  -> exit 0, 26 Swift Testing tests, result bundle
  `~/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.07_11-33-28--0700.xcresult`.
- Scoped residue scan:
  `rg -n "currentCatalogRevision|\"catalogRevision\": catalog_revision|let currentCatalogRevision|\"catalogRevision\": self\\.catalog\\.revision\\(\\)\\.0|\"catalogRevision\": host\\.catalog_revision\\(\\)\\.0|\"catalogRevision\": catalog_revision\\.0|\"required\": \\[\"catalogRevision\"|\"catalogRevision\": \\{\"type\": \"integer\"\\}" packages/agent/src/transport/contracts.rs packages/agent/src/transport/engine_ws.rs packages/ios-app/Sources/Services/Network/EngineConnectionProtocolFrames.swift packages/ios-app/Sources/Models/EngineProtocol/EngineProtocolTypes.swift packages/agent/src/engine/host.rs packages/agent/src/engine/host/meta.rs packages/agent/src/engine/primitives/catalog.rs packages/agent/src/engine/primitives/runtime.rs packages/agent/src/engine/primitives/worker.rs README.md`
  -> exit 1/no matches.

Residual risk: none known for public catalog readout fields. Remaining
revision fields in this slice are cursor truth (`currentRevision`,
`nextRevision`) or child invocation evidence (`functionRevision`,
`catalogRevision`).

### PET-11 Server Primitive Identity Teardown Addendum

This checkpoint removes the server-side counterpart to the iOS primitive
identity cleanup:

- `CapabilityEventIdentity` now carries only `modelPrimitiveName`,
  `operationName`, `traceId`, `rootInvocationId`, `themeColor`, and
  `presentationHints`;
- capability started/completed persisted payloads and server activity summary
  lines no longer serialize contract, implementation, function, plugin, worker,
  schema, catalog revision, trust, risk, effect, or binding fields;
- primitive-surface stop tracking is keyed by model primitive name only;
- the dead `capability.resolution` event and runtime-stream adapter branch were
  deleted rather than renamed or aliased;
- `primitive_engine_teardown_plan_invariants::server_capability_identity_stays_primitive_only`
  now rejects the removed server identity vocabulary in the scoped event,
  runner, persisted-payload, projection, and primitive-surface paths.

Evidence:

- Red proof:
  `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants server_capability_identity_stays_primitive_only -- --nocapture`
  -> exit 101 before the teardown; the new gate failed on stale
  `contract_id` in `CapabilityEventIdentity`.
- After implementation, the same targeted invariant command -> exit 0, 1 test.
- `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants -- --nocapture`
  -> exit 0, 16 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml --lib capability_invocation_executor -- --nocapture`
  -> exit 0, 8 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml --lib turn_runner -- --nocapture`
  -> exit 0, 17 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml --lib activity_summary -- --nocapture`
  -> exit 0, 12 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml --lib tron_core -- --nocapture`
  -> exit 0, 12 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml --lib tron_catalog -- --nocapture`
  -> exit 0, 1 test.
- `cargo check --manifest-path packages/agent/Cargo.toml --bin tron`
  -> exit 0.
- `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`
  -> exit 0.
- Scoped stale-symbol scans for resolved-catalog identity vocabulary over
  `CapabilityEventIdentity`, capability invocation runner/persistence,
  payloads, session activity projection, and primitive-surface resolver
  -> exit 1/no matches.
- Stale event scan for `CapabilityResolution`, `capability.resolution`,
  `requestedContractId`, `requestedImplementationId`, and
  `requestedFunctionId` over `packages/agent/src` and `packages/agent/tests`
  -> exit 1/no matches.

### PET-11 iOS Primitive Identity Teardown Addendum

This checkpoint collapses retained iOS capability invocation identity and
presentation to true primitive execution fields:

- retained identity fields are now `modelPrimitiveName`, `operationName`,
  `traceId`, `rootInvocationId`, `themeColor`, and `presentationHints`;
- capability event plugins, current-turn reconstruction, dashboard activity
  lines, detail sheets, action rows, and session summaries no longer decode or
  render contract, implementation, function, plugin, worker, schema, trust,
  risk, effect, binding, `search`, or `inspect` identity metadata;
- presentation defaults are generic action/operation/trace rendering, with
  richer labels/icons/colors coming only from runtime-owned presentation hints;
- `SourceGuardTests.testCapabilityIdentityStaysPrimitiveOnly` now rejects the
  deleted identity vocabulary in the scoped capability path.

Evidence:

- `cd packages/ios-app && xcodegen generate` -> exit 0.
- First affected-suite run:
  `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/CapabilityInvocationDisplayModelTests -only-testing:TronMobileTests/CapabilityLifecyclePluginTests -only-testing:TronMobileTests/CapabilityInvocationStartedPluginTests -only-testing:TronMobileTests/CapabilityInvocationGeneratingPluginTests -only-testing:TronMobileTests/CapabilityInvocationCompletedPluginTests -only-testing:TronMobileTests/UnifiedEventTransformerActionProjectionTests -only-testing:TronMobileTests/UnifiedEventTransformerTests -only-testing:TronMobileTests/CapabilityInvocationCoordinatorTests -only-testing:TronMobileTests/DashboardCapabilityStreamTests -only-testing:TronMobileTests/CapabilityInvocationDetailViewTests -only-testing:TronMobileTests/EngineProtocolTypesTests -only-testing:TronMobileTests/EventDatabaseTests -only-testing:TronMobileTests/SourceGuardTests`
  -> exit 65, 152 XCTest tests ran with 6 stale expectation failures while
  SourceGuard still passed 19 tests; result bundle
  `~/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.07_07-36-43--0700.xcresult`.
- Focused red rerun for the five failing test methods -> exit 65, confirming
  stale expected labels/rows (`Run`, `Executor`, `Read File`, `Invocation`, and
  full trace prefix) after the primitive identity rewrite; result bundle
  `~/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.07_07-37-35--0700.xcresult`.
- Focused green rerun for those five test methods -> exit 0, 5 tests passed;
  result bundle
  `~/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.07_07-38-38--0700.xcresult`.
- Green affected-suite rerun with the command above -> exit 0, 152 XCTest
  tests plus 19 SourceGuard tests passed; result bundle
  `~/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.07_07-38-56--0700.xcresult`.
- SourceGuard rerun after adding
  `testCapabilityIdentityStaysPrimitiveOnly`:
  `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/SourceGuardTests`
  -> exit 0, 20 Swift Testing tests passed; result bundle
  `~/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.07_07-40-02--0700.xcresult`.
- `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`
  -> exit 0.
- Scoped stale-symbol scan over capability identity/presentation source and
  tests for `contractId`, `implementationId`, `functionId`, `pluginId`,
  `workerId`, `schemaDigest`, `catalogRevision`, `trustTier`, `riskLevel`,
  `effectClass`, `bindingDecisionId`, `capability::search`,
  `capability::inspect`, `sourceLabel`, `pluginLabel`, and `workerLabel`
  -> exit 1/no matches.
- iOS docs/README scan for stale identity vocabulary outside teardown evidence
  -> exit 1/no matches.
- `git diff --check` -> exit 0.

### PET-10 Client Cleanup Addendum

This checkpoint removed the remaining iOS client-side product planes that
survived the earlier primitive-shell pass:

- plugin-source settings, DTOs, client, status plugin, route, and tests;
- audio/transcription services, media DTO/client, mic input UI, microphone
  permission copy, transcription coordinator, and tests;
- memory-retain and rules event plugins, dispatch protocol requirements,
  chat-model state, system-event enum cases, notification pills, memory detail
  sheet, local event taxonomy/icon/summary support, detailed context DTO
  memory/rules fields, and tests;
- stale iOS docs/README references to those client surfaces.

Evidence:

- `cd packages/ios-app && xcodegen generate` -> exit 0.
- First focused iOS proof:
  `xcodebuild test -project packages/ios-app/TronMobile.xcodeproj -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/tron-xcode-pet-settings -only-testing:TronMobileTests/ServerSettingsTests -only-testing:TronMobileTests/SettingsStateTests -only-testing:TronMobileTests/AgentContextSettingsPageTests -only-testing:TronMobileTests/ServerSettingsPageTests -only-testing:TronMobileTests/SettingsParityTests -only-testing:TronMobileTests/AgentSettingsPageLayoutTests`
  -> exit 0, 19 XCTest tests and 41 Swift Testing tests passed; result bundle
  `/tmp/tron-xcode-pet-settings/Logs/Test/Test-Tron-2026.06.07_05-36-44--0700.xcresult`.
- First cleanup rerun:
  `xcodebuild test -project packages/ios-app/TronMobile.xcodeproj -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/tron-xcode-pet-ios-cleanup -only-testing:TronMobileTests/InteractionPolicyTests -only-testing:TronMobileTests/SendBlockReasonTests -only-testing:TronMobileTests/SessionStateInvariantsTests -only-testing:TronMobileTests/EventDispatchCoordinatorTests -only-testing:TronMobileTests/UnifiedEventTransformerTests -only-testing:TronMobileTests/EventIconProviderTests -only-testing:TronMobileTests/SessionEventSummaryTests -only-testing:TronMobileTests/NotificationPillTests -only-testing:TronMobileTests/IPadSheetPresentationTests -only-testing:TronMobileTests/SourceGuardTests -only-testing:TronMobileTests/AgentContextSettingsPageTests -only-testing:TronMobileTests/AgentSettingsPageLayoutTests`
  -> exit 65 at compile, stale `BrowserGetStatusResult` test remained after
  deleting the media/browser DTO. Owner: ios test cleanup. Fixed by deleting
  the stale browser protocol test block.
- Green focused cleanup proof: same command and derived-data path -> exit 0,
  173 XCTest tests plus 39 Swift Testing tests passed; result bundle
  `/tmp/tron-xcode-pet-ios-cleanup/Logs/Test/Test-Tron-2026.06.07_05-54-22--0700.xcresult`.
- Absence scans:
  `rg -n "BrowserGetStatusResult|browser::|BrowserClient|MediaClient|Transcribe|Transcription|transcription|AudioRecorder|AudioCaptureEngine|canRecordAudio|memory\\.retained|rules\\.activated|RulesActivatedPlugin|MemoryUpdatedPlugin" packages/ios-app/Sources packages/ios-app/Tests packages/ios-app/project.yml`
  -> exit 1/no matches;
  `rg -n "case rules|case memory|rulesLoaded|rulesActivated|memoryRetained|memoryAuto|MemoryRetain|UserMemory|LoadedRules|ActivatedRule" packages/ios-app/Sources packages/ios-app/Tests`
  -> exit 1/no matches.

Residual risk: the backend dead-source/test-only teardown and warning cleanup
were closed in the later PET-10 context/relay/typed-client checkpoint. PET-11
still owns final adversarial "cannot remove more" audit and fresh end-to-end
proof.

### PET-8 Approval-Plane Teardown Addendum

After the initial PET-8 shell proof, the iOS approval prompt plane was also
deleted to align with the upfront authority-envelope model. Additional source
changes removed `ApprovalClient`, `ApprovalPlugins`, `EngineApprovalState`,
`EngineApprovalCoordinator`, approval message/protocol DTOs, approval sheets,
approval status display, approval policy fields from generated UI actions,
approval state from capability invocation models, and the unused Work snapshot
DTO plane.

Additional evidence:

- `cd packages/ios-app && xcodegen generate` -> exit 0.
- Initial rerun
  `xcodebuild test -project TronMobile.xcodeproj -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/tron-xcode-pet8-green-8 -only-testing:TronMobileTests/SourceGuardTests`
  -> exit 65, stale test references to deleted approval plugins.
- Fixed stale dispatch mocks and reran with
  `/tmp/tron-xcode-pet8-green-9`; compile reached link, then failed with
  `errno=28 No space left on device`. Owner: environment capacity. Cleanup
  removed only PET-8 `/tmp/tron-xcode-*` derived-data directories and freed
  about 6 GB.
- Green SourceGuard proof:
  `xcodebuild test -project TronMobile.xcodeproj -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/tron-xcode-pet8-sourceguard-final -only-testing:TronMobileTests/SourceGuardTests`
  -> exit 0, 18 tests passed; result bundle
  `/tmp/tron-xcode-pet8-sourceguard-final/Logs/Test/Test-Tron-2026.06.07_01-18-41--0700.xcresult`.
- Final SourceGuard rerun after doc cleanup:
  same command and derived-data path -> exit 0, 18 tests passed; result bundle
  `/tmp/tron-xcode-pet8-sourceguard-final/Logs/Test/Test-Tron-2026.06.07_01-25-04--0700.xcresult`.
- Green affected-suite proof:
  `xcodebuild test -project TronMobile.xcodeproj -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath /tmp/tron-xcode-pet8-sourceguard-final -only-testing:TronMobileTests/CapabilityInvocationDisplayModelTests -only-testing:TronMobileTests/GeneratedUIDTOTests -only-testing:TronMobileTests/GeneratedUIRendererTests -only-testing:TronMobileTests/CapabilityInvocationDetailViewTests -only-testing:TronMobileTests/EventDispatchCoordinatorTests -only-testing:TronMobileTests/EventPluginTests -only-testing:TronMobileTests/AgentSettingsPageLayoutTests`
  -> exit 0, 56 XCTest tests plus 9 Swift Testing tests passed; result bundle
  `/tmp/tron-xcode-pet8-sourceguard-final/Logs/Test/Test-Tron-2026.06.07_01-19-57--0700.xcresult`.
- Absence scans:
  `rg -n "AgentWorkSnapshotParams|WorkSnapshotDTO|WorkAutonomyDTO|WorkActiveItemDTO|WorkGuardrailDTO|WorkWorkerDTO|WorkMilestoneDTO|WorkAuditRefDTO|WorkScopeDTO|agent::work_snapshot" packages/ios-app/Sources packages/ios-app/Tests packages/ios-app/project.yml`
  -> exit 1/no matches;
  `rg -n "approval|Approval|APPROVAL_REQUIRED|EngineApproval|ApprovalClient" packages/ios-app/Sources packages/ios-app/project.yml`
  -> exit 1/no matches.
- Fresh simulator proof used bundle id `com.tron.mobile.beta` and app product
  `/tmp/tron-xcode-pet8-sourceguard-final/Build/Products/Beta-iphonesimulator/TronMobile.app`.
  iPhone 17 Pro iOS 26.5 UDID
  `7BDA4AF9-1C40-47E3-A925-0F88C191F263`: bootstatus rc 0, install rc 0,
  launch rc 0, screenshot rc 0 at
  `/tmp/tron-pet8-ui/pet8-iphone17pro-ios265-shell-approval-teardown.png`.
  iPad Pro 13-inch (M5) iOS 26.5 UDID
  `099FE1B6-28C6-4028-A60F-28BDE4849BE5`: bootstatus rc 0, install rc 0,
  launch rc 0, screenshot rc 0 at
  `/tmp/tron-pet8-ui/pet8-ipadpro13-ios265-shell-approval-teardown.png`.

Residual risk from this addendum was closed by the later traceability and
dead-source cleanup checkpoints. PET-11 still owns final retained-surface audit
and fresh end-to-end proof.

### PET-11 iOS Draft Skills Teardown Addendum

This checkpoint deleted the retained iOS draft-storage skills residue from
first principles. `session_drafts` is a shell-local unsent-input cache, so its
primitive state is text, attachment metadata, and update time. The old
skill/spell columns were write-only product residue and not part of the bare
agent loop.

Changes:

- removed the draft skills column from fresh iOS schema creation;
- deleted the obsolete draft spell-column migration path;
- removed the repository's hard-coded empty skill JSON write;
- updated direct SQL tests and draft repository/store coverage around the
  primitive table shape;
- added SourceGuard coverage to keep draft persistence free of skills/spells
  state.

Evidence:

- Red proof:
  `cd packages/ios-app && xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/SourceGuardTests`
  -> exit 65. `SourceGuardTests.testDraftPersistenceHasNoSkillsResidue`
  failed with 6 issues on `skills_json` in `DraftRepository.swift`,
  `DatabaseSchema.swift`, `DraftRepositoryTests.swift`, and
  `EventDatabaseTests.swift`; result bundle
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.07_08-07-47--0700.xcresult`.
- `cd packages/ios-app && xcodegen generate` -> exit 0.
- Green focused proof:
  `cd packages/ios-app && xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/SourceGuardTests -only-testing:TronMobileTests/DraftRepositoryTests -only-testing:TronMobileTests/EventDatabaseTests/testSessionDraftsTableExists -only-testing:TronMobileTests/EventDatabaseTests/testSessionDraftsTable_basicCRUD -only-testing:TronMobileTests/EventDatabaseTests/testClearAll_includesSessionDrafts -only-testing:TronMobileTests/DraftStoreTests`
  -> exit 0, 37 XCTest tests and 21 SourceGuard Swift Testing tests passed;
  result bundle
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.07_08-10-41--0700.xcresult`.
- Stale-token scan:
  `rg -n "skills_json|spells_json|selectedSkills|SelectedSkill" packages/ios-app/Sources packages/ios-app/Tests -g '!SourceGuardTests.swift'`
  -> exit 1/no matches.

Residual risk: this closed the draft-storage open loop only. Later PET-11
addenda close the repo/task DTO, `Attachments`, SessionTree projection,
capability-support collapse, product update, and diagnostics/logging loops;
PET-11 still owns final fresh server/DB/trace proof, iPhone/iPad closeout
screenshots, and any remaining engine-envelope/catalog
terms that are not true primitive resource/version metadata.

### PET-11 User-Interaction Pause-Plane Teardown Addendum

This checkpoint deleted the hard-coded mid-turn prompt/answer plane from first
principles. The primitive loop should not carry a bespoke client-owned
question sheet, answer DTO, pause event family, or user-authorized
`submit_answers` transport shortcut. Upfront authority policies define what
the agent can do; outside-envelope work is blocked and recorded as evidence.
Future interaction must be agent-authored generated UI/action state rather
than a fixed harness feature.

Changes:

- deleted iOS `UserInteraction` message types, transformer, sheet/viewer,
  coordinator, state, `ChatViewModel+UserInteraction`, and their tests;
- removed `.userInteraction` message content, sheet cases, tap actions,
  deep-link/message-finder branches, reconstruction branches, and
  `userInteractionCalledInTurn` state;
- removed `AgentClient.submitAnswers`, `SubmitAnswersParams`,
  `SubmitAnswersResponse`, `AnswerSubmission`, and
  `agent::submit_answers` from the iOS engine client contract;
- removed `CapabilityPauseRequestedPlugin`,
  `CapabilityPauseResolvedPlugin`, `capability.pause.*` event types, pause
  dispatch handlers, and prompt/answer enrichment fields from the iOS event
  pipeline;
- removed the stale "pending questions superseded" send-message hook and
  answered-questions chip rendering;
- removed the stale iOS decoded `messageKind`/`answerCount` fields for
  answered-question chips and the matching server comments that still described
  confirmation/answer chip metadata;
- removed Rust `agent::submit_answers` transport actor special-casing and
  deleted `CapabilityPauseRequested`/`CapabilityPauseResolved` catalog
  variants plus their typed payload DTOs;
- added iOS SourceGuard and Rust invariant coverage so the prompt/pause/answer
  plane cannot return to retained primitive sources.

Evidence:

- Red proof:
  `cd packages/ios-app && xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/SourceGuardTests`
  -> exit 65. `SourceGuardTests.testPrimitiveShellHasNoUserInteractionPausePlane`
  failed with 119 stale prompt-plane matches before deletion; result bundle
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.07_08-14-58--0700.xcresult`.
- `cd packages/ios-app && xcodegen generate` -> exit 0.
- Green focused iOS proof:
  `cd packages/ios-app && xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/SourceGuardTests -only-testing:TronMobileTests/AgentClientTests -only-testing:TronMobileTests/UnifiedEventTransformerTests -only-testing:TronMobileTests/CapabilityLifecyclePluginTests -only-testing:TronMobileTests/CapabilityInvocationCoordinatorTests -only-testing:TronMobileTests/EventDispatchCoordinatorTests -only-testing:TronMobileTests/TurnLifecycleCoordinatorTests -only-testing:TronMobileTests/ChatViewModelEventRoutingTests -only-testing:TronMobileTests/MessageFinderTests -only-testing:TronMobileTests/ChatViewModelFindMessageTests -only-testing:TronMobileTests/ChatSheetTests -only-testing:TronMobileTests/SheetCoordinatorLifecycleTests -only-testing:TronMobileTests/IPadSheetPresentationTests -only-testing:TronMobileTests/MessagingCoordinatorTests`
  -> exit 0, 228 XCTest tests and 36 Swift Testing tests passed; result
  bundle
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.07_08-31-18--0700.xcresult`.
- `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check`
  -> exit 0.
- `cargo check --manifest-path packages/agent/Cargo.toml --bin tron`
  -> exit 0.
- `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants -- --nocapture`
  -> exit 0, 17 tests passed including
  `user_interaction_pause_plane_is_deleted_from_retained_sources`.
- `cargo test --manifest-path packages/agent/Cargo.toml tron_event_all_event_types -- --nocapture`
  -> exit 0.
- `cargo test --manifest-path packages/agent/Cargo.toml ordinary_client_invoke_remains_client_actor -- --nocapture`
  -> exit 0.
- `cargo test --manifest-path packages/agent/Cargo.toml capability_execute_invoke_uses_agent_actor -- --nocapture`
  -> exit 0.
- Targeted stale-token scans for `CapabilityPause`, `capability.pause`,
  `submit_answers`, `SubmitAnswers`, `AnswerSubmission`, `ask_user`,
  `.userInteraction`, prompt payload/status/answer fields, and
  `markPendingQuestionsAsSuperseded` returned exit 1/no matches outside
  absence tests. The only broad `UserInteraction` matches left are scroll
  gesture `hadUserInteraction` names, not the prompt plane.
- Follow-up payload cleanup proof:
  `cd packages/ios-app && xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/SourceGuardTests -only-testing:TronMobileTests/UnifiedEventTransformerTests -only-testing:TronMobileTests/MessagePayloadTests`
  -> exit 0, 64 XCTest tests and 22 SourceGuard Swift Testing tests passed;
  result bundle
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.07_08-35-14--0700.xcresult`.
- Follow-up stale-token scan for `answerCount`, `confirmationDecision`,
  `answered_questions`, `SubmitAnswers`, `agent::submit_answers`,
  `capability.pause`, `CapabilityPause`, `ask_user`, `interactionStatus`,
  `parsedAnswers`, and `markPendingQuestionsAsSuperseded` returned exit 1/no
  matches outside absence tests; formatter check, primitive invariant test,
  and `git diff --check` all returned exit 0.

Residual risk: this closed the hard-coded user-interaction/pause/answer open
loop only. Later PET-11 addenda close the repo/task DTO, `Attachments`,
SessionTree projection, capability-support collapse, diagnostics/logging, and
dynamic rendering loops. PET-11 still owns final fresh server/DB/trace proof,
iPhone/iPad closeout screenshots, and any remaining engine-envelope/catalog
terms that are not true primitive resource/version metadata.

### PET-11 iOS Repo/Task DTO Teardown Addendum

This checkpoint deleted stale iOS engine protocol DTOs for repo session
divergence and task list state. Neither surface is needed for the primitive
client shell: repo/task behavior is a removed product plane, while the retained
session list and prompt loop use session, event, message, and generic
capability/runtime evidence DTOs.

Changes:

- deleted `EngineProtocolTypes+Repo.swift`, including `RepoListSessionsParams`,
  `RepoSessionSummary`, `RepoListSessionsResult`, `RepoGetDivergenceParams`,
  and `RepoDivergence`;
- deleted `EngineProtocolTypes+Task.swift`, including `RpcTask`,
  `TaskListParams`, `TaskListResult`, and task status display helpers;
- removed the task DTO self-tests from `EngineProtocolTypesTests.swift`;
- extended SourceGuard's stale typed-domain client guard to reject the deleted
  repo/task files, DTO names, and operation labels.

Evidence:

- Source audit:
  `rg -n "RepoStatusParams|RepoStatusResult|RepoDiffParams|RepoDiffResult|RepoCommitParams|RepoCommitResult|repo::|TaskListParams|TaskListResult|TaskCreateParams|TaskCreateResult|TaskUpdateParams|TaskUpdateResult|task::|TaskItem|RepoFileChange|CommitInfo" packages/ios-app/Sources packages/ios-app/Tests packages/ios-app/project.yml`
  -> exit 0 only for `TaskListResult` self-tests and `EngineProtocolTypes+Task.swift`;
  the repo DTO file had no retained call sites. No separate failing SourceGuard
  run was captured before deletion; the source audit was the red signal.
- `cd packages/ios-app && xcodegen generate` -> exit 0.
- Stale-token scan:
  `rg -n "RepoListSessions|RepoSessionSummary|RepoGetDivergence|RepoDivergence|RpcTask|TaskListParams|TaskListResult|repo\\.listSessions|repo\\.getDivergence|tasks\\.list" packages/ios-app/Sources packages/ios-app/Tests packages/ios-app/project.yml -g '!SourceGuardTests.swift'`
  -> exit 1/no matches.
- SourceGuard proof:
  `cd packages/ios-app && xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/SourceGuardTests -only-testing:TronMobileTests/EngineProtocolTypesTests`
  -> exit 0, 22 SourceGuard Swift Testing tests passed; the
  `EngineProtocolTypesTests` selector intentionally selected no XCTest class
  because the file is split across concrete model test classes. Result bundle
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.07_08-39-18--0700.xcresult`.
- Correct focused model proof:
  `cd packages/ios-app && xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/SessionTypesTests -only-testing:TronMobileTests/TokenTypesTests -only-testing:TronMobileTests/EventTypesTests -only-testing:TronMobileTests/AttachmentTypesTests -only-testing:TronMobileTests/SystemTypesTests -only-testing:TronMobileTests/ModelTypesExtendedTests -only-testing:TronMobileTests/EngineProtocolBaseTypesTests`
  -> exit 0, 25 XCTest tests passed; result bundle
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.07_08-40-52--0700.xcresult`.
- `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants -- --nocapture`
  -> exit 0, 17 tests.

Residual risk: this closed only the repo/task DTO open loop. Later addenda
close the `Attachments`, SessionTree projection, capability-support collapse,
product update, and diagnostics/logging loops; PET-11 still owns dynamic
rendering, final fresh server/DB/trace proof, iPhone/iPad closeout
screenshots, and any remaining engine-envelope/catalog terms that are not true
primitive resource/version metadata.

### PET-11 iOS Process Dashboard Teardown Addendum

This checkpoint deleted the fixed iOS process dashboard from first principles.
The retained primitive loop still exposes `process_run` through `execute`, but
the app no longer owns a bespoke background-process state machine, sheet, or
`process.*` live event family. Process execution appears as generic primitive
capability evidence with trace ids and runtime details.

Changes:

- deleted `Plugins/Process`, including `process.spawned`,
  `process.completed`, `process.status_update`, and `job.backgrounded`
  parsers;
- removed `ProcessEventHandler` from the live event dispatch target and
  removed those plugins from `EventRegistry`;
- deleted `ProcessState`, `ChatViewModel+ProcessEvents`, `ProcessListSheet`,
  `ManageProcessResultViewer`, and `ProcessStateTests`;
- removed the chat process sheet route and `ChatMenuAction.processes`;
- removed process-sheet expectations from iPad sheet presentation tests;
- removed the stale process plugin row from iOS event docs;
- added SourceGuard coverage to keep the fixed process dashboard/event plane
  deleted without banning the retained `process_run` primitive.

Evidence:

- Source audit showed iOS retained process plugins/state/sheets while Rust no
  longer emitted the corresponding events:
  `rg -n "process\\.spawned|process\\.completed|process\\.status_update|job\\.backgrounded|ProcessSpawned|ProcessCompleted|ProcessStatusUpdate|JobBackgrounded" packages/agent/src packages/agent/tests README.md`
  -> exit 1/no matches.
- `cd packages/ios-app && xcodegen generate` -> exit 0.
- Focused iOS proof:
  `cd packages/ios-app && xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/SourceGuardTests -only-testing:TronMobileTests/EventDispatchCoordinatorTests -only-testing:TronMobileTests/IPadSheetPresentationTests`
  -> exit 0, 25 XCTest tests and 23 SourceGuard Swift Testing tests passed;
  result bundle
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.07_08-47-46--0700.xcresult`.
- Stale-token scan:
  `rg -n "ProcessListSheet|ProcessState|ProcessEventHandler|ProcessSpawnedPlugin|ProcessCompletedPlugin|ProcessStatusUpdatePlugin|JobBackgroundedPlugin|ManageProcessResultViewer|showProcessSheet|clearProcessState|handleProcessSpawned|handleProcessCompleted|handleProcessStatusUpdate|handleJobBackgrounded|process\\.spawned|process\\.completed|process\\.status_update|job\\.backgrounded|case processes" packages/ios-app/Sources packages/ios-app/Tests packages/ios-app/project.yml -g '!SourceGuardTests.swift'`
  -> exit 1/no matches.

Residual risk: this closed only the fixed process dashboard open loop at that
checkpoint. Later addenda close the retained/successor `Attachments`,
SessionTree projection, capability-support collapse, diagnostics/logging, and
dynamic rendering loops. PET-11 still owns final fresh server/DB/trace proof,
iPhone/iPad closeout screenshots, and any remaining engine-envelope/catalog
terms that are not true primitive resource/version metadata.

### PET-11 Unified Prompt Attachment Primitive Addendum

This checkpoint audited retained iOS `Attachments` from first principles. The
attachment UI/model path is bare prompt-input infrastructure: it lets the user
send images, PDFs, and documents into the first model turn. The removable layer
was the parallel image-only prompt API (`images`/`ImageAttachment`) that sat
beside unified attachments and was already bypassed by the iOS send path.

Changes:

- removed `images` from Rust `agent::prompt`, `agent::prompt_apply`, and
  `agent::run_turn` schemas;
- removed `PromptSubmission.images`, `PromptRequest.images`, prompt validation
  of the old array, runtime request propagation, and the separate image loop in
  user event/content builders;
- retained image support only through attachments whose `mimeType` starts with
  `image/`, and retained document extraction for non-image attachments;
- removed iOS `ImageAttachment`, `AgentPromptParams.images`, `AgentClient` and
  repository `images` parameters, stale send comments, and image-only mock
  state/tests;
- added Rust and iOS SourceGuard coverage so the prompt transport path has one
  attachment plane and no image-only field/DTO fallback.

Evidence:

- Targeted stale scans for legacy prompt image fields over the Rust prompt
  contract/runtime path and the iOS prompt DTO/client/repository/test path
  returned exit 1/no matches.
- Initial new Rust invariant run:
  `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants -- --nocapture`
  -> exit 101 because the new guard required the literal `attachments` string
  in `EngineProtocolTypesTests.swift`; the file correctly proved
  `FileAttachment` instead. Fixed the guard to accept the DTO type as the
  primitive proof.
- `cargo fmt --manifest-path packages/agent/Cargo.toml --all` -> exit 0.
- `cargo test --manifest-path packages/agent/Cargo.toml --lib unified_attachments -- --nocapture`
  -> exit 0, 2 tests proving unified attachments project to
  `message.user` image/document blocks and provider-facing multimodal content
  blocks.
- `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants -- --nocapture`
  -> exit 0, 18 tests including
  `prompt_media_uses_unified_attachment_primitive` and
  `agent_trace_records_are_first_class_and_agent_visible`.
- `cargo check --manifest-path packages/agent/Cargo.toml --bin tron`
  -> exit 0.
- `cd packages/ios-app && xcodegen generate` -> exit 0.
- Focused iOS proof:
  `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/SourceGuardTests -only-testing:TronMobileTests/AgentClientTests -only-testing:TronMobileTests/DefaultAgentRepositoryTests -only-testing:TronMobileTests/AttachmentTypesTests -only-testing:TronMobileTests/MessagingCoordinatorTests -only-testing:TronMobileTests/AttachmentTests -only-testing:TronMobileTests/InputBarStateTests -only-testing:TronMobileTests/InputBarContentAreaChipTests`
  -> exit 0, 75 XCTest tests plus 31 Swift Testing tests passed; result bundle
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.07_09-02-50--0700.xcresult`.

Residual risk: this closes the retained/successor iOS `Attachments` open loop
and removes the legacy prompt image API. Later addenda close the fixed iOS
tree projection, capability-support collapse, diagnostics/logging, and dynamic
rendering loops. PET-11 still owns final fresh server/DB/trace proof,
iPhone/iPad closeout screenshots, and any remaining engine-envelope/catalog
terms that are not true primitive resource/version metadata.

### PET-11 iOS SessionTree Projection Teardown Addendum

This checkpoint audited retained/successor iOS `SessionTree` from first
principles. The true primitive is session/event lineage: session rows and
stored events own parent/child fork truth, and generic reconstruction can ask
for ancestors or children without maintaining a second tree-specific DTO. The
removable layer was the fixed iOS tree visualization stack.

Changes:

- deleted `Sources/Views/SessionTree`, including event rows, fork indicators,
  and the fixed event icon catalog;
- deleted local `TreeRepository`, `EventTreeBuilder`, and `EventTreeNode`;
- removed `EventDatabase.tree`, `EventDatabaseProtocol.tree`, and
  `EventStoreManager.getTreeVisualization(_:)`;
- removed stale tree repository, fork button, icon provider, and branch-point
  tests;
- kept generic session repositories, session fork API tests, event ancestor and
  children queries, and stored-event reconstruction order tests;
- added Rust and iOS SourceGuard coverage rejecting fixed tree projection files,
  DTOs, builders, repository accessors, branch flags, fork-row state, and icon
  provider vocabulary.

Evidence:

- Stale-token scan:
  `rg -n "EventTreeNode|EventTreeBuilder|TreeRepository|ForkPointIndicator|ForkButtonState|EventIconProvider|getTreeVisualization|database\\.tree|eventDB\\.tree|isBranchPoint|childCount|hasChildren" packages/ios-app/Sources packages/ios-app/Tests packages/ios-app/project.yml -g '!SourceGuardTests.swift'`
  -> exit 1/no matches.
- Deleted-view proof:
  `test ! -e packages/ios-app/Sources/Views/SessionTree`
  -> exit 0 after the empty directory was removed. A direct `find` on the
  deleted root correctly returned exit 1 because the path no longer exists.
- Initial Rust invariant run:
  `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants -- --nocapture`
  -> exit 101 because the empty `Sources/Views/SessionTree` directory still
  existed. Removed the empty directory.
- Green Rust invariant proof:
  `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants -- --nocapture`
  -> exit 0, 19 tests including
  `ios_shell_has_no_fixed_session_tree_projection`.
- `cd packages/ios-app && xcodegen generate` -> exit 0.
- Focused iOS proof:
  `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/SourceGuardTests -only-testing:TronMobileTests/EventDatabaseTests -only-testing:TronMobileTests/EventStoreManagerTests -only-testing:TronMobileTests/SessionEventForkableTests -only-testing:TronMobileTests/SessionEventSummaryTests -only-testing:TronMobileTests/UnifiedEventTransformerReconstructionOrderTests -only-testing:TronMobileTests/SessionRepositoryTests -only-testing:TronMobileTests/SessionClientTests -only-testing:TronMobileTests/DefaultSessionRepositoryTests`
  -> exit 0, 117 XCTest tests plus 42 Swift Testing tests passed; result bundle
  `/Users/moose/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.07_09-14-42--0700.xcresult`.

Residual risk: this closes the fixed iOS SessionTree projection loop. The
following addenda close the capability-support collapse, diagnostics/logging,
and dynamic rendering loops. PET-11 still owns final fresh server/DB/trace
proof, iPhone/iPad closeout screenshots, and any remaining
engine-envelope/catalog terms that are not true primitive resource/version
metadata.

### PET-11 Capability-Support Domain Collapse Addendum

This checkpoint audited the former `capability_support` row from first
principles. The true primitive is the provider-call boundary resolving the single
model-visible `execute` tool and dispatching emitted tool calls through the
engine host. That belongs inside the agent runner. A top-level
`domains/capability_support` root was an unnecessary abstraction that made the
provider surface look like another retained domain.

Changes:

- moved `primitive_surface.rs` to
  `domains/agent/runner/agent/primitive_surface.rs`;
- inlined the one `ExecutionMode` enum into the moved primitive surface file;
- renamed internal structures from capability-surface/target naming to
  primitive-surface/target naming;
- deleted `domains/capability_support/` and its `implementations` submodule;
- updated agent-runner imports, docs, and static gates so the moved resolver is
  covered and the old top-level support domain must stay absent.

Evidence:

- `cargo fmt --manifest-path packages/agent/Cargo.toml --all` -> exit 0.
- `test ! -d packages/agent/src/domains/capability_support` -> exit 0.
- `cargo test --manifest-path packages/agent/Cargo.toml --lib primitive_surface -- --nocapture`
  -> exit 0, 2 tests proving the provider prompt surface still exposes only
  `execute`.
- `cargo test --manifest-path packages/agent/Cargo.toml --lib model_capability_invocation_invokes_execute_primitive_through_engine -- --nocapture`
  -> exit 0, 1 test proving model-emitted `execute` still invokes the engine
  primitive through the host.
- `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants -- --nocapture`
  -> exit 0, 19 tests including the moved primitive-surface path check and
  top-level `capability_support` absence check.

Residual risk: this closes the `capability_support` host indirection/naming
loop. Later addenda close the update-surface audit, diagnostics/logging, and
dynamic rendering loops. PET-11 still owns final fresh server/DB/trace proof,
iPhone/iPad closeout screenshots, and any remaining engine-envelope/catalog
terms that are not true primitive resource/version metadata.

### PET-11 Product Update-Surface Teardown Addendum

First-principles decision: release polling, update channels, update cadence,
Mac menu "check" actions, and CLI self-update wrappers are product maintenance
workflow, not bootstrap infrastructure. They are not required to start the
server, load auth/settings, accept a prompt, call a provider, execute the one
primitive, persist trace evidence, or render the thin client shell. Keeping a
disabled update plane would still preserve a hard-coded product abstraction.

Changes:

- deleted `packages/agent/src/platform/updater/` and the update-check scheduler;
- removed `system::check_for_updates` and `system::get_update_status`;
- removed `server.update` settings, update enums, updater path helpers, bundled
  default profile values, and runtime context fetcher/state fields;
- removed `tron self-update`, updater pause/state paths, and updater references
  from contributor scripts;
- removed iOS update DTOs, settings state, Controls UI, tests, and product copy;
- removed the Mac menu update action and updater cleanup path;
- updated README, iOS/Mac docs, inventory, and local managed profile defaults;
- added static absence gates in
  `primitive_engine_teardown_plan_invariants.rs` and iOS `SourceGuardTests`.

Evidence:

- `cargo fmt --manifest-path packages/agent/Cargo.toml --all` -> exit 0.
- `cargo check --manifest-path packages/agent/Cargo.toml --bin tron` -> exit 0.
- `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants -- --nocapture`
  -> exit 0, 20 tests including `primitive_branch_has_no_product_update_surface`.
- `cargo test --manifest-path packages/agent/Cargo.toml --test db_path_guard -- --nocapture`
  -> exit 0, 13 tests.
- `cargo test --manifest-path packages/agent/Cargo.toml default_settings_are_valid -- --nocapture`
  -> exit 0, 1 matched settings-schema test.
- `bash -n scripts/tron scripts/tron-lib.sh scripts/tron.d/automation.sh scripts/auto-deploy`
  -> exit 0.
- `scripts/tron help | rg -n "self-update|auto-deploy|Runtime|Deployment"`
  -> exit 0 with only `auto-deploy`, `Runtime`, and `Deployment` matches.
- `cd packages/ios-app && xcodegen generate` -> exit 0.
- Focused iOS run
  `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/SourceGuardTests -only-testing:TronMobileTests/ServerSettingsTests -only-testing:TronMobileTests/SettingsParityTests -only-testing:TronMobileTests/SettingsStateTests -only-testing:TronMobileTests/ServerSettingsPageTests -only-testing:TronMobileTests/AgentContextSettingsPageTests -only-testing:TronMobileTests/AgentSettingsPageLayoutTests`
  -> exit 0, 18 XCTest tests plus 61 Swift Testing tests passed, result bundle
  `~/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.07_09-49-25--0700.xcresult`.
- `cd packages/mac-app && xcodegen generate` -> exit 0.
- Focused Mac run
  `xcodebuild test -scheme TronMac -destination 'platform=macOS' -only-testing:TronMacTests/MenuBarItemBuilderTests -only-testing:TronMacTests/MenuBarActionHandlerTests -only-testing:TronMacTests/TronPathsTests -only-testing:TronMacTests/TronUninstallerTests`
  -> exit 0, 37 Swift Testing tests passed, result bundle
  `~/Library/Developer/Xcode/DerivedData/TronMac-fjgdtjmmbndhtwfqnfyaagtxvdvs/Logs/Test/Test-TronMac-2026.06.07_09-50-23--0700.xcresult`.
- Exact residue scan
  `rg -n "server\\.update|SystemCheckForUpdatesResult|SystemUpdateStatusResult|checkForUpdates|getUpdateStatus|check_for_updates|get_update_status|UpdateChannel|UpdateFrequency|UpdateAction|updateEnabled|updateChannel|updateFrequency|updateAction|ServerUpdateSettingsItem|SettingsLabels\\.updates|updatesSection|updater-state|auto-update|self-update|server\\.update_available|release_fetcher|updater_state_path|platform::updater|pub mod updater|UpdateSettings|Check for updates" packages/agent/src packages/agent/tests packages/ios-app/Sources packages/ios-app/Tests packages/mac-app/Sources packages/mac-app/Tests scripts README.md packages/ios-app/docs packages/mac-app/docs -g '!target' -g '!DerivedData' -g '!SourceGuardTests.swift' -g '!primitive_engine_teardown_plan_invariants.rs'`
  -> exit 1/no matches.
- Profile schema scan
  `rg -n "\\[settings\\.server\\.update\\]|server\\.update" packages/agent/defaults /Users/moose/.tron/profiles -g '*.toml'`
  -> exit 1/no matches.

Residual risk: this closes the product update-check loop. Later addenda close
diagnostics/logging and dynamic rendering. PET-11 still owns final fresh
server/DB/trace proof, iPhone/iPad closeout screenshots, and any remaining
engine-envelope/catalog terms that are not true primitive resource/version
metadata.

### PET-11 Diagnostics And Retained-Log Evidence Teardown Addendum

First-principles decision: observability is primitive, but fixed diagnostic
summaries, generic log-store DTOs, and inert payload-capture settings are not.
The loop needs durable trace records, retained logs, and bounded model-visible
evidence reads. It does not need a second `system::get_diagnostics` product
API, a generic `LogStore` abstraction that no retained caller uses, or iOS
state for settings that no longer drive behavior.

Changes:

- deleted `shared/logging/store.rs` and the unused `LogStore`,
  `LogEntry`, `LogQueryOptions`, and `SortOrder` exports;
- deleted `system::get_diagnostics`, `SystemDiagnosticsResult`,
  `getDiagnostics()`, and the fixed Rust diagnostics value builder;
- removed `payloadCapture`, `maxInlinePayloadBytes`, and matching iOS settings
  state/update fields from bundled and local managed default profiles;
- collapsed the one-case iOS diagnostics settings enum into a direct Runtime
  Evidence section;
- added `execute.log_recent` as the only model-visible retained-log read path,
  scoped to the current session plus global rows and bounded to 1..500 rows;
- updated README, scorecard, inventory, Rust static gates, iOS SourceGuard, and
  primitive trace execution tests around the retained trace/log evidence path.

Evidence:

- `cargo fmt --manifest-path packages/agent/Cargo.toml --all` -> exit 0.
- Initial primitive trace execution run after adding `log_recent`:
  `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_trace_execution -- --nocapture`
  -> exit 0, 2 tests, with one warning for now-dead `system::Deps.origin`.
  The field was removed because diagnostics was the only remaining caller.
- Rerun after removing the dead origin field:
  `cargo fmt --manifest-path packages/agent/Cargo.toml --all` -> exit 0.
- Static teardown proof:
  `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants -- --nocapture`
  -> exit 0, 21 tests including
  `diagnostics_logging_surface_is_flattened_to_execute_evidence`.
- Warning-free compile proof:
  `cargo check --manifest-path packages/agent/Cargo.toml --bin tron`
  -> exit 0.
- Agent-visible retained-log proof:
  `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_trace_execution -- --nocapture`
  -> exit 0, 2 tests including
  `execute_log_recent_exposes_bounded_session_trace_logs`. The fixture inserts
  current-session, global, and other-session log rows; `execute.log_recent`
  returns the current/global trace rows and excludes the other-session row.
- Hardening rerun after tightening the no-session path first failed with
  `PolicyViolation("session-scoped idempotency requires a session id")` because
  the test supplied a session-scoped idempotency key without a session id. That
  host invariant is correct; the fixture now omits idempotency for the
  sessionless edge case and proves `log_recent` returns global rows only rather
  than broadening to other sessions.
- Final trace/log rerun:
  `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_trace_execution -- --nocapture`
  -> exit 0, 2 tests.
- Default profile schema proof:
  `cargo test --manifest-path packages/agent/Cargo.toml default_settings_are_valid -- --nocapture`
  -> exit 0.
- iOS project regeneration:
  `cd packages/ios-app && xcodegen generate` -> exit 0.
- Focused iOS proof:
  `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/SourceGuardTests -only-testing:TronMobileTests/ServerSettingsTests -only-testing:TronMobileTests/SettingsParityTests -only-testing:TronMobileTests/SettingsStateTests -only-testing:TronMobileTests/ServerSettingsPageTests -only-testing:TronMobileTests/AgentContextSettingsPageTests -only-testing:TronMobileTests/AgentSettingsPageLayoutTests`
  -> exit 0, 18 XCTest tests plus 59 Swift Testing tests passed; result bundle
  `~/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.07_10-11-38--0700.xcresult`.
- Visual artifact emitted by the iOS settings layout run:
  `~/Library/Developer/CoreSimulator/Devices/7BDA4AF9-1C40-47E3-A925-0F88C191F263/data/Containers/Data/Application/97D46F17-177C-43C5-AFD0-CD53728F2ECB/Documents/tron-visual-artifacts/agent-settings-primitive-render.png`.
- Residue scan:
  `rg -n "payloadCapture|maxInlinePayloadBytes|PayloadCapture|observabilityPayloadCapture|observabilityMaxInlinePayloadBytes|Inline bytes|system::get_diagnostics|SystemDiagnosticsResult|getDiagnostics|system_diagnostics_value|ConnectionSettingsServerBackedSection|diagnosticsSection|LogStore|LogQueryOptions" packages/agent/src packages/agent/tests packages/agent/defaults packages/ios-app/Sources packages/ios-app/Tests README.md packages/ios-app/docs /Users/moose/.tron/profiles -g '!target' -g '!DerivedData' -g '!SourceGuardTests.swift' -g '!primitive_engine_teardown_plan_invariants.rs'`
  -> exit 1/no matches.
- `git diff --check` -> exit 0.

Residual risk: this closes the diagnostics/logging open loop. PET-11 still
owns final fresh server/DB/trace proof, iPhone/iPad closeout screenshots, and
any remaining engine-envelope/catalog terms that are not true primitive
resource/version metadata.

### PET-11 Dynamic Runtime Surface Teardown Addendum

This checkpoint keeps generic runtime rendering while deleting the fixed
generated-UI authoring framework that still encoded server-owned target
knowledge:

- deleted `ui::catalog`, `ui::surface_for_target`, `ui::refresh_surface`, the
  `engine/primitives/ui/authoring` module, UI action summary/control
  projection helpers, catalog DTOs, target templates, required grant/risk
  fields, bindings, redaction policy, refresh policy, and `WorkerRef`;
- retained `ui_surface` as a bounded schema-versioned runtime resource with
  `surfaceId`, `title`, `purpose`, `schemaVersion`, `layout`, `actions`, and
  `expiresAt`;
- retained `ui::submit_action` only as a normal host-dispatched primitive that
  validates surface/version/action/input and records accepted action
  coordinates, not as a special child-invocation gateway;
- updated iOS generated-UI DTOs and renderer validation to use
  `schemaVersion` and generic action coordinates only.

Evidence:

- Red proof:
  `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants dynamic_runtime_surfaces_are_schema_rendering_not_target_authoring -- --nocapture`
  -> exit 101 while `packages/agent/src/engine/primitives/ui/authoring`
  still existed.
- Compile/fix proof:
  `cargo fmt --manifest-path packages/agent/Cargo.toml --all` -> exit 0;
  first `cargo check --manifest-path packages/agent/Cargo.toml --bin tron`
  -> exit 101 on stale dynamic UI dispatch/import residue; after deleting the
  stale dispatch constants and restoring only the schema-validation import,
  rerun -> exit 0.
- Static proof after deleting the empty authoring directory and changing the
  invariant to assert deleted projection files absent:
  `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants dynamic_runtime_surfaces_are_schema_rendering_not_target_authoring -- --nocapture`
  -> exit 0, 1 test.
- Full PET-11 static proof:
  `cargo test --manifest-path packages/agent/Cargo.toml --test primitive_engine_teardown_plan_invariants -- --nocapture`
  -> exit 0, 22 tests.
- Warning-free Rust proof:
  `cargo check --manifest-path packages/agent/Cargo.toml --bin tron`
  -> exit 0.
- iOS project regeneration:
  `cd packages/ios-app && xcodegen generate` -> exit 0.
- Focused iOS proof:
  `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TronMobileTests/SourceGuardTests -only-testing:TronMobileTests/GeneratedUIDTOTests -only-testing:TronMobileTests/GeneratedUIRendererTests`
  -> exit 0, 35 Swift Testing tests passed; result bundle
  `~/Library/Developer/Xcode/DerivedData/TronMobile-eqctauwqsqxkqyelqqpembdspvdk/Logs/Test/Test-Tron-2026.06.07_10-40-12--0700.xcresult`.
- Scoped residue scan for deleted dynamic UI target/catalog/template
  vocabulary across retained Rust/iOS dynamic-surface source and tests
  -> exit 1/no matches.

Residual risk: dynamic rendering is now closed for PET-11. Remaining PET-11
work is the engine-envelope/catalog-term audit, final fresh server/DB/trace
proof, iPhone/iPad closeout screenshots, final diff hygiene, and final
scorecard closeout.

## Required Final Evidence

PET-11 must add:

- final branch and commit hash;
- full retained/deleted primitive inventory;
- provider model-facing tool export proof;
- fresh bare-session transcript or fixture output;
- database schema/table/resource/event proof for fresh state;
- trace record proof linking provider/model turn, invocation, VCS/resource
  evidence, content hashes, and the agent-visible query path;
- iOS simulator target name, UDID, bundle id, launch return code, and iPhone/iPad
  screenshots;
- final command list with exit codes;
- final `git status --short --branch`;
- explicit list of anything deferred to the self-adapting-agent successor.
