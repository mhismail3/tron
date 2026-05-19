# Production-Grade Codebase Audit

Last verified: 2026-05-19 on `next/modular-capability-engine`.

This document is the repo-wide proof map for production-grade codebase
hygiene. It answers the same class of question as "does folder organization
match the intended architecture?", but applies it across every package,
submodule, test boundary, generated project, script, and durable document.

The rule is evidence over impression. A subsystem stays only when it has a
current owner, caller, route, capability registration, UI entrypoint, test,
operator role, generated-artifact role, or documented extension point.
Unresolved areas become explicit blockers with an acceptance criterion.

## Audit Questions

Every audited area is evaluated against these questions:

| Question | Passing evidence |
|---|---|
| Ownership | One owner and one reason to exist are documented in code, `mod.rs`, README, or this audit |
| Architecture fit | Folder location matches runtime architecture and dependency direction |
| Reachability | Binary, route, capability, UI entrypoint, script, test, generated project, or docs reference exists |
| State truth | Durable state, projection/cache state, generated state, or no state is correctly classified |
| Security boundary | Grants, auth, secrets, sandboxing, file roots, network policy, or client trust boundary is explicit |
| Data flow | Inputs, outputs, side effects, retries, idempotency, and failure modes are explicit when relevant |
| Test ownership | Tests live with the owning concern or are explicitly centralized for integration/static proof |
| Deletion readiness | Removal impact is known; no-impact code is a remove candidate |
| Documentation | README, local docs, package docs, and progressive-disclosure docs match behavior |
| Operational readiness | Operator can inspect, recover, debug, or safely ignore the subsystem |
| Dependency hygiene | Dependencies and generated artifacts are justified by package manifest or project config |
| Drift protection | Static gates, absence tests, or deletion bars protect critical invariants |

## Classification Key

| Classification | Meaning |
|---|---|
| `substrate` | Core engine/kernel state, policy, execution, resource, or ledger fabric |
| `capability module` | Worker/domain capability with current contract and caller |
| `thin client` | UI/client projection over server-owned truth |
| `platform/support` | Runtime platform, distribution, build, deployment, or OS integration |
| `test/support` | Test fixture, integration/static gate, or test helper |
| `generated` | Generated project/build artifact that is intentionally tracked |
| `docs` | Durable documentation or proof artifact |
| `remove candidate` | No current proof of caller/contract/operator value |
| `defer with reason` | Keep for now; deletion/conversion requires a named replacement or proof |

## Package Map

| Area | Classification | Evidence | Decision | Risk | 100% acceptance |
|---|---|---|---|---|---|
| `packages/agent` | substrate / capability host | `Cargo.toml`, `src/lib.rs`, `src/main.rs`, README Rust module table, full Rust CI | Keep | High | All modules classified; no unowned public capability/state path |
| `packages/ios-app` | thin client | `project.yml`, `Sources/`, `Tests/`, Engine Console/generated UI tests, product-shell reachability map | Keep | Medium | Every remaining fixed shell has reachability decision or generated UI replacement |
| `packages/mac-app` | platform/support thin client | `project.yml`, `Sources/MenuBar`, `Sources/Wizard`, server lifecycle services, tests | Keep | Medium | Mac docs/tests classify install wizard, server lifecycle, pairing, and generated project state |
| `scripts/` | platform/support | README CLI table, `scripts/tron`, release/version helpers, CI usage | Keep | High | Every script has README or docs entry and no production deploy is run by agents |
| `.github/` | platform/support | workflow files, README repository structure | Keep | Medium | CI/release jobs match current build/test policy and secrets assumptions |
| `docs/` | docs | README links, architecture/audit/scorecard/proof docs | Keep | Medium | Docs distinguish current behavior from future plans and local links pass |
| `packages/agent/skills/` | platform/support | managed skill rules in AGENTS, `.managed` sentinels, source-controlled skills | Keep | Medium | Managed skill sync rules remain documented and tests/static scans protect personal data |
| Generated Xcode projects | generated | `project.yml`, tracked `.xcodeproj`, `xcodegen generate` no-diff check | Keep | Medium | Generated projects regenerate cleanly and are not hand-edited |
| Build outputs and caches | generated / ignored | `.gitignore`, untracked build dirs, no tracked `target`/build cache scan | Keep ignored | Low | No build/cache artifact becomes tracked source |

## Rust Agent Package

| Area | Classification | Evidence | Decision | Risk | 100% acceptance |
|---|---|---|---|---|---|
| `app` | platform/support | bootstrap, health, metrics, onboarding, shutdown modules; README module table | Keep | Medium | Startup and shutdown paths remain documented and covered by tests/static gates |
| `transport` | platform/support | `/engine`, worker socket transport, auth gate, protocol tests | Keep | High | Transport stays thin and does not own domain policy or durable truth |
| `engine` | substrate | host, catalog, ledger, resources, grants, primitives, queues, streams, tests | Keep | High | Engine owns invocation, authority, resources, and projections without duplicate planes |
| `domains` | capability module | `domains/registration.rs`, per-domain contracts/handlers/deps | Keep | High | Every domain has contract, current registration/caller, and output/state classification |
| `platform` | platform/support | APNs, updater/device sidecars | Keep | Medium | Platform integrations remain isolated from engine/domain policy |
| `shared` | platform/support | foundation, protocol DTOs, logging, server helpers | Keep | Medium | Shared code stays neutral and does not import domain/app policy upward |
| `bin/tron-program-worker.rs` | platform/support | Cargo binary, static gate for worker binary packaging | Keep | Medium | Program worker remains packaged and not duplicated by another process path |
| `packages/agent/tests` | test/support | integration, static invariants, DB path guard, program worker tests | Keep | High | Static/integration tests stay focused and cover removal/absence gates |
| `Cargo.toml` / `Cargo.lock` | platform/support | package manifest and lockfile | Keep | High | Dependencies are justified; optional deeper unused-dependency tooling is added or explicitly deferred |

## Engine Submodule Map

| Area | Classification | Evidence | Decision | Risk | 100% acceptance |
|---|---|---|---|---|---|
| `host` | substrate | invocation dispatch, prepare/finish, stores, full CI | Keep | High | Host dispatches/enforces but does not absorb primitive-specific projection logic |
| `catalog` / `registry` | substrate | function/worker definitions, discovery, catalog tests | Keep | High | Catalog remains canonical for registered workers/capabilities |
| `ledger` / `invocation` | substrate | invocation records, idempotency, causality tests | Keep | High | Every capability call and result is reconstructable and idempotent where required |
| `grants` | substrate | grant store/model, `engine/tests/grant_authority.rs` | Keep | High | All authority decisions derive from grants; no raw scope fallback |
| `resources` | substrate | focused resource kernel modules, `resource_kernel` tests | Keep | High | Resource kernel remains uniform and resource types do not create separate stores |
| `queue` | substrate | queue store/drainer, activation retry tests | Keep | High | Queue retry does not duplicate grants/workers/resources/invocations |
| `leases` | substrate | lease APIs and tests in engine tests | Keep | Medium | Resource mutations use lease/CAS where concurrency risk exists |
| `streams` | substrate | stream store/subscription tests | Keep | Medium | Streams remain rebuildable/projection facts, not durable truth planes |
| `policy` | substrate | visibility/authority validation tests | Keep | High | Policy remains engine-owned and test-backed |
| `external` | substrate | external worker lifecycle tests/static gates | Keep | High | Worker lifecycle is canonical and no parallel spawn path appears |
| `engine/tests/mod.rs` | test/support | declaration-only test root with static gate forbidding test bodies | Keep | Medium | Root stays limited to ownership docs, module declarations, and fixture exports |
| `packages/agent/src/engine/tests/support.rs` | test/support | shared engine test fixtures used by concern files | Keep | Medium | Shared setup stays reusable without becoming a catch-all behavior test file |
| `engine/tests/` concern files | test/support | `ids_types`, `catalog_discovery`, `ledger_idempotency`, `host_invocation`, `meta_primitives`, `triggers`, `streams`, `state_queue`, `leases_compensation`, `approval`, `external_worker`, plus focused grant/resource/UI/module/domain-output tests | Keep | Medium | Test folders mirror substrate concerns and no central catch-all file returns |

## Engine Primitive Map

| Primitive | Classification | Evidence | Decision | Risk | 100% acceptance |
|---|---|---|---|---|---|
| `action_summary` | substrate projection | shared action consequence helper used by control/module/UI | Keep | Medium | One canonical action summary model, no duplicate UI/control action templates |
| `approval` | substrate | approval primitive tests and high-risk capability flow | Keep | High | Approval state remains engine-owned and resumable through invocation ledger |
| `catalog` | substrate | primitive catalog worker | Keep | Medium | Catalog inspection remains read-only and engine-owned |
| `control` | substrate projection | `control::snapshot`, `control::inspect`, no `control::act` static gate | Keep | High | Control is projection/action advertisement only |
| `grant` | substrate | `grant::*` capability contracts and grant tests | Keep | High | Grants are only authority model |
| `module` | substrate / capability module | package lifecycle, trust, health, activation tests | Keep | High | Parent remains lifecycle coordinator; policy/runtime helpers stay in focused submodules |
| `observability` | platform/support | log/query primitive tests | Keep | Medium | Observability remains bounded/redacted and does not own control state |
| `queue` | substrate | queue primitive and retry tests | Keep | High | Queue remains invocation substrate, not separate scheduler plane |
| `resource` | substrate | generic resource wrapper capabilities | Keep | High | Durable output wrappers compose resource kernel only |
| `runtime` | substrate | host-dispatched primitive boundary | Keep | High | Runtime dispatch does not accumulate projection/state ownership |
| `state` | substrate | state primitive tests | Keep | Medium | State is scoped/rebuildable where appropriate and not a duplicate resource store |
| `storage` | platform/support | unified SQLite stats/checkpoint/export | Keep | Medium | Storage reports/retention do not become resource truth |
| `stream` | substrate projection | stream primitive tests | Keep | Medium | Stream cursors/events stay append-only/rebuildable |
| `ui` | substrate projection/resource | fixed catalog, authoring, action submission, validation submodule | Keep | High | UI actions execute only stored canonical targets |
| `worker` | substrate | worker lifecycle and spawn/registration tests | Keep | High | `worker::spawn` remains canonical public worker creation path |

## Resource Kernel Map

| Submodule | Classification | Evidence | Decision | Risk | 100% acceptance |
|---|---|---|---|---|---|
| `types` | substrate | public resource structs/constants | Keep | High | Types own no persistence or UI runtime logic |
| `definitions` | substrate | built-in resource type definitions and schemas | Keep | High | Definitions do not drift into store/runtime modules |
| `validation` | substrate | generic request/lifecycle/schema/link validation | Keep | High | Invalid payloads fail before persistence |
| `versions` | substrate | payload hash helpers | Keep | Medium | Version/hash/current-state helpers stay centralized |
| `ui_surface` | substrate | fixed UI catalog/payload validation | Keep | High | Dynamic catalogs/fallback renderers remain forbidden |
| `store` | substrate | in-memory/SQLite resource store | Keep | High | Store persists generic resources only and does not own type definitions |

## Module Primitive Map

| Submodule | Classification | Evidence | Decision | Risk | 100% acceptance |
|---|---|---|---|---|---|
| Parent `module.rs` | substrate / lifecycle coordinator | registrations, package/config/activation entrypoints, shared helpers | Keep narrow | High | Shared helpers do not grow into second policy/runtime plane |
| `activation_runtime` | substrate | spawn composition, cleanup, recovery helpers, retry/soak tests | Keep | High | Local-process packages launch/stop only through canonical worker capabilities |
| `source_trust` | substrate | source/signature/policy/trust tests | Keep | High | Package activation never bypasses source policy |
| `health_integrity` | substrate | health, integrity, conformance, recovery tests | Keep | High | Health/recovery evidence is resource-backed and does not fabricate success |
| `trust_review` | substrate projection/evidence | simulation/review tests | Keep | Medium | Simulation remains side-effect-free; review evidence recomputes server-side |
| `trust_audit` | substrate projection/evidence | schedule/status/retention tests | Keep | Medium | Audit schedules are decisions; no audit/scheduler table |

## Rust Domain Map

| Domain | Classification | Evidence | Decision | Risk | 100% acceptance |
|---|---|---|---|---|---|
| `agent` | capability module / core runtime | agent contracts, runner, subagent/chat tests | Keep | High | Agent outputs stay resource/invocation linked; fixed subagent UI has replacement plan |
| `auth` | capability module | provider credential storage and auth operations | Keep | High | Secrets remain in auth/profile stores and never logs/UI |
| `blob` | capability module | blob client/capabilities and storage payload refs | Keep | Medium | Blobs stay referenced by resources/invocations where durable |
| `browser` | capability module | product-shell map defers browser/display deletion | Defer with reason | Medium | Keep only active capability/event paths; remove with route/DTO proof |
| `capability` | capability module | registry/index projection and tests | Keep | High | Registry remains projection over engine/domain contracts |
| `capability_support` | capability module support | enrichment/support tests | Keep | Medium | Support code is owned by capability domain only |
| `context` | capability module | context operations/queries | Keep | Medium | Context remains bounded projection into agent runtime |
| `cron` | capability module | cron contracts, scheduler, static notes, removed fixed dashboard | Keep | High | Cron state is classified; no hidden product dashboard returns |
| `device` | platform/support | APNs/device registration tests | Keep | Medium | Device state is support infrastructure, not generated UI truth |
| `display` | capability module / projection | display client/tests, reachability map | Defer with reason | Medium | Ephemeral stream frames stay non-durable unless materialized |
| `events` | capability module support | event projection registrations | Keep | Medium | Event DTOs remain protocol projections |
| `filesystem` | capability module | materialized output/resource tests | Keep | High | Mutating durable file outputs remain resource-backed |
| `git` | capability module | source-control/worktree caller paths | Keep | Medium | Git workflows stay explicit and user-reviewed |
| `import` | capability module | implementation tests for parser/assembler/writer | Keep | Medium | Import outputs are classified before becoming durable |
| `job` | capability module | job operations and clients | Keep | Medium | Job state remains operator-inspectable |
| `logs` | platform/support | observability/logging callers | Keep | Low | Logs remain bounded/redacted support data |
| `mcp` | capability module | product protocol tests | Keep | High | MCP adapters do not bypass engine grants/resources |
| `memory` | capability module | retain tests and settings | Keep | Medium | Memory output/state has explicit retention and privacy contract |
| `message` | capability module | message helpers and protocol use | Keep | Low | Message formatting remains stateless/helper-owned |
| `model` | capability module | providers, auth, streaming tests | Keep | High | Provider implementations do not own durable agent truth |
| `notifications` | platform/support / thin shell dependency | inbox/APNs tests and reachability map | Defer with reason | Medium | Convert only after delivery/read receipt resource contract exists |
| `plan` | capability module | plan capability/state paths | Keep | Medium | Plan files/state are classified before any deletion |
| `process` | capability module | sandbox/read-only/materialized process rules | Keep | High | Write-like process paths remain sandbox/resource-backed |
| `program` | capability module | program worker tests/binary | Keep | High | Program outputs are execution resources or child resource refs |
| `prompt_library` | capability module | resource-backed prompt tests/static gates | Keep | Medium | No prompt-specific table reader returns |
| `repo` | capability module | repository metadata operations | Keep | Low | Repo helpers remain stateless/support unless materialized |
| `sandbox` | capability module | worker spawn/stop capabilities and static gates | Keep | High | No public `sandbox::spawn_worker`; worker lifecycle is canonical |
| `session` | platform/support / chat harness | event store, reconstruction, transport callers | Keep | High | Session state is thin harness and not central product architecture |
| `settings` | platform/support | settings parity tests and profile TOML rules | Keep | High | Server/iOS settings parity remains exact |
| `skills` | capability module | managed skills, discovery/tracker tests | Keep | Medium | Managed skills sync remains repo-owned and safe |
| `system` | platform/support | system capabilities | Keep | Medium | System capabilities remain bounded and operator-visible |
| `transcription` | capability module | voice note caller and reachability map | Keep | Medium | Transcripts become durable only through caller-owned resources |
| `tree` | capability module | tree helpers/capabilities | Keep | Low | Tree state remains clearly classified |
| `voice_notes` | capability module | resource-backed voice note tests/static gates | Keep | Medium | No file-scan/delete source truth returns |
| `web` | capability module | web capability contracts | Keep | Medium | Web/network policy remains explicit |
| `worktree` | capability module | worktree/git workflow tests and iOS source-control callers | Keep | High | Worktree mutation remains user-reviewed and recoverable |

## iOS Package Map

| Area | Classification | Evidence | Decision | Risk | 100% acceptance |
|---|---|---|---|---|---|
| `App` | thin client | app entrypoint and dependency container | Keep | Medium | App bootstrap owns no server policy |
| `Core` | thin client support | event registry, concurrency, repositories tests | Keep | Medium | Core remains UI/client infrastructure |
| `Database` | thin client cache | repository/schema tests | Keep | Medium | Local DB is read-only/redacted projection where applicable |
| `Models` | thin client DTOs | EngineProtocol DTO tests | Keep | High | DTOs tolerate additive server fields without policy ownership |
| `Services` | thin client transport | Engine clients, generated UI/control clients, notification/media clients | Keep | High | Services submit canonical requests only and own no grants/policy |
| `ViewModels` | thin client projection | chat, engine console, settings, subagent tests | Keep | High | View models manage UI state but not durable server truth |
| `Views` | thin client | chat, Engine Console, generated UI renderer, product-shell map | Keep/defer | High | Remaining fixed shells are replaced or justified by reachability map |
| `Theme` | thin client support | typography/color tests | Keep | Low | Theme remains presentation only |
| `Utilities` | thin client support | formatting/parsing tests | Keep | Low | Utilities stay stateless |
| `Protocols` | thin client support | service abstractions | Keep | Low | Protocols do not become policy layer |
| `Resources` / assets | generated/support | asset catalogs, fonts, project config | Keep | Low | Assets remain referenced by project or removed |
| `Tests` | test/support | top-level XcodeGen test source root | Keep | Medium | Tests remain grouped by app concern; no hidden unreferenced test folders |
| `project.yml` | generated support | `xcodegen generate` no-diff verification | Keep | High | Project file remains canonical input to generated Xcode project |

### iOS View Surface Decisions

| View area | Classification | Decision | 100% acceptance |
|---|---|---|---|
| Chat / Session / InputBar / MessageBubble | thin chat harness | Keep | Chat stays harness over server truth and resources |
| EngineConsole / EngineApproval | thin control client | Keep | Engine Console renders server projections/generated UI only |
| AgentControl / SourceChanges / Subagents | defer with reason | Keep until generated UI/resource lineage covers current workflows |
| Notifications | defer with reason | Keep until notification delivery/read semantics are resource-backed |
| PromptLibrary | thin client | Keep | Server prompt state remains artifact resources |
| VoiceNotes | thin client | Keep | Recording stays affordance; fixed list remains removed |
| Settings / Onboarding / Skills / System / Components | thin client/support | Keep | Settings parity and pairing/setup remain tested |

## Mac Package Map

| Area | Classification | Evidence | Decision | Risk | 100% acceptance |
|---|---|---|---|---|---|
| `Sources/MenuBar` | thin client | Mac menu bar wrapper | Keep | Medium | Menu bar controls server lifecycle without duplicating policy |
| `Sources/Wizard` | thin client | install/onboarding wizard steps | Keep | Medium | Wizard reflects current install requirements and tests |
| `Sources/Services/Server` | platform/support | server lifecycle services | Keep | High | Start/stop/status paths are safe, test-backed, and non-production-deploying |
| `Sources/Services/Pairing` | platform/support | pairing support | Keep | Medium | Pairing remains scoped to local engine connection |
| `Sources/Services/Feedback` / `Observability` | platform/support | diagnostics/feedback paths | Keep | Medium | Diagnostics stay redacted |
| `Sources/Theme` / resources | thin client support | assets/fonts/project config | Keep | Low | Assets remain referenced or removed |
| `Tests` | test/support | Mac test target | Keep | Medium | Tests cover wizard, server lifecycle, menu bar, observability |
| `project.yml` / generated project | generated support | XcodeGen inputs/project | Keep | Medium | Generated project regenerates cleanly |
| `scripts` | platform/support | Mac helper scripts | Keep | Medium | Scripts are documented and do not duplicate root deploy behavior |

## Repo Support Map

| Area | Classification | Evidence | Decision | Risk | 100% acceptance |
|---|---|---|---|---|---|
| `README.md` | docs | canonical project reference | Keep | High | README links all durable architecture/audit docs and matches code |
| `docs/collapsed-modular-engine-architecture.md` | docs | substrate target | Keep | Medium | Architecture doc describes current substrate accurately |
| `docs/modular-engine-cleanup-audit.md` | docs | cleanup proof map | Keep | Medium | Cleanup decisions stay evidence-backed |
| `docs/modular-engine-maturity-scorecard.md` | docs | substrate scorecard | Keep | Medium | Substrate score remains distinct from repo-wide rubric |
| `docs/product-shell-reachability-map.md` | docs | fixed shell deletion bar | Keep | Medium | Every remaining fixed shell is classified before deletion |
| `docs/production-grade-codebase-audit.md` | docs | this repo-wide audit | Keep | Medium | Every package/submodule remains classified |
| `docs/production-grade-rubric.md` | docs | repo-wide 100-point rubric | Keep | Medium | Score has evidence and blockers |
| `.github` | platform/support | workflows and templates | Keep | Medium | CI/release docs match workflows |
| Project rules (`AGENTS.md`, `.claude`, `.Codex`) | platform/support | agent/developer guidance | Keep | Medium | Rules are current and not contradictory |
| Version files | platform/support | `VERSION.env`, Xcode project settings | Keep | Medium | Version/build metadata remains single-source |

## Test Organization Findings

| Finding | Evidence | Decision | Acceptance |
|---|---|---|---|
| Engine catch-all split completed | `packages/agent/src/engine/tests/mod.rs` has declarations only; `support.rs` owns shared fixtures; concern files own behavior tests | Keep | Static gates require the old `engine/tests.rs` to stay absent and focused modules to exist |
| Engine focused tests are current | `engine/tests/{ids_types,catalog_discovery,ledger_idempotency,host_invocation,meta_primitives,triggers,streams,state_queue,leases_compensation,approval,external_worker,generated_ui,grant_authority,module_activation,prompt_library_resources,resource_kernel,domain_outputs}.rs` | Keep | New engine tests go into the owning concern file or a new concern-named file |
| Domain test ownership split completed | `packages/agent/src/domains/memory/retain/tests/mod.rs`, `packages/agent/src/domains/mcp/product_protocol/tests/mod.rs`, and `packages/agent/src/domains/session/commands/tests/mod.rs` are declaration-only roots with `support.rs` fixtures and concern-owned test files | Keep | Static gates require old broad `tests.rs` files to stay absent and new concern modules to exist |
| Rust domains use mixed but documented layouts | Inline `#[cfg(test)]`, sibling `tests.rs`, and `*_tests.rs` are accepted by convention for small/local concerns | Standardize when touched | High-churn or broad domains migrate toward focused `tests/` folders as cleanup work |
| iOS tests use top-level test root | `packages/ios-app/project.yml` includes `Tests` source root | Keep | Continue category grouping unless app chooses source-co-located tests later |
| Mac tests use top-level test root | `packages/mac-app/Tests` | Keep | Keep category grouping and project-generation checks |

## Rust Test Placement Convention

- Large subsystems use a focused `tests/` module tree. The engine test suite is
  the reference pattern: `tests/mod.rs` declares modules, `tests/support.rs`
  owns shared fixtures, and behavior tests live in concern-named files.
- Sibling `tests.rs` or `*_tests.rs` files are acceptable for small private
  modules when the test scope is local and unlikely to grow into cross-cutting
  behavior.
- Inline `#[cfg(test)]` modules are acceptable for narrow pure helpers and
  parser/formatter checks where the behavior is easier to understand beside
  the implementation.
- New engine tests must not be added to a catch-all root. They belong in the
  owning `engine/tests/*.rs` concern file, with shared setup promoted to
  `engine/tests/support.rs` only when at least two concern files need it.
- New broad domain tests follow the same pattern: a declaration-only
  `tests/mod.rs`, shared setup in `tests/support.rs`, and concern files named
  for behavior rather than implementation accidents.

## Prioritized Cleanup Backlog

| Priority | Work | Acceptance criteria |
|---:|---|---|
| 1 | Replace one remaining fixed iOS shell | Product-shell reachability map proves replacement; old view/navigation/DTO/tests removed with absence gate |
| 2 | Add optional dependency/dead-code tooling | `cargo machete`/`cargo udeps` or equivalent is added to documented local audit path if stable |
| 3 | Mac app deep audit | Add focused Mac score/evidence for server lifecycle, pairing, wizard, generated project, and tests |
| Completed | Resolve inert prompt schema ambiguity | `modular-engine-v3` fresh schema no longer creates `prompt_history`, `prompt_snippets`, or prompt indexes; static gates enforce absence |
| Completed | Migrate current high-churn Rust domain tests | Memory retain, MCP product protocol, and session commands broad tests are split into focused `tests/` folders |

## Verification Record

This audit is designed to be verified with:

- `git status --short --branch`;
- `git ls-files` inventory scans;
- local Markdown link scan;
- forbidden-symbol scans;
- `cargo test --test threat_model_invariants -- --nocapture`;
- focused `cargo test generated_ui`, `resource_`, and `module_` filters;
- `RUSTFLAGS="-D warnings" cargo check --all-targets`;
- `scripts/tron ci fmt check clippy test`;
- `xcodegen generate` for iOS and Mac when project files are touched;
- targeted iOS/Mac tests for touched client surfaces.
