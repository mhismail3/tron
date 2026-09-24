# SDK-backed Anthropic model catalog

- **Started:** 2026-09-24
- **Status:** Active
- **Last updated:** 2026-09-24, CAT-3 correction
- **Goal:** Remove CortexKit's duplicate static model catalog while preserving correct subscription routing and per-model capabilities, and separately assess subscription-compatible discovery.

## Goal and constraints

Preserve existing sessions, model IDs, default selections, credentials, exact tool-name restoration, model-specific thinking behavior, and the user's disabled optional routing/warming features. A model appearing in a catalog is not evidence that a subscription can use it. Do not advertise account entitlement or verify it by issuing paid generation calls automatically.

The SDK remains the model-metadata authority; CortexKit owns its stream/auth adaptations; Tron owns catalog projection and presentation. Reuse supported SDK APIs, not private generated-file imports, copied catalog snapshots, hand-edited installed packages, or a second model database. Do not read credentials directly or create a new credential store.

Implementation belongs in an isolated branch/worktree of the local CortexKit source repository, with separate Tron changes only where a demonstrated consumer gap requires them. Package fixes remain local and unpublished unless separately authorized. Gateway transitions are manual user actions. Do not install a package over active Anthropic work without explicit coordination; a source commit does not prove live adoption.

The practical SDK-catalog change and optional live discovery are separate deliverables. Discovery failure must not hold up the static-catalog replacement. Approval activates the plan for task claims; it does not start implementation or authorize network probes using account credentials, package replacement, or deployment.

## Context

Inspected 2026-09-24:

- The local CortexKit Pi extension declares a fixed `configuration.models` list and replaces the built-in Anthropic catalog. Its alternate Claustrum registration also derives models from that list. Missing models cannot be recovered merely by refreshing Tron's catalog.
- The local source repository is the sibling checkout named cortexkit-anthropic-auth-toolname-fix; its relevant owner is packages/pi/src/index.ts, with request conversion in packages/pi/src/convert.ts and shared model behavior in packages/core/src/models.ts. Verify its current branch and package version before work; do not confuse it with the Tron repository.
- Installed local package `1.23.1-tron.3` retains transcript-derived exact tool-name mapping and exposes Opus 5.5 Low, Medium, High, Extra High and Max. Registration and synthetic wire tests passed, but live provider acceptance of every extended effort was not established by those tests.
- Tron uses SDK 0.87.1. Its current Anthropic metadata is a candidate source, not proof that every listed model is accepted by CortexKit's converter or the user's subscription. The public model-list API's compatibility with subscription OAuth has not been established.
- Existing Tron consumers include `packages/gateway/src/transport/gateway-service.ts`, `packages/gateway/src/providers/provider-usage.ts`, and `packages/ios-app/Sources/Models/ModelDisplayFormatting.swift`. Usage admission checks the custom CortexKit API and first-party base URL; preserve that boundary.

## Tasks

| ID | Status | Scope | Depends on | Owner |
| --- | --- | --- | --- | --- |
| CAT-1 | Done | Establish SDK catalog source and per-model adapter compatibility contract | none | catalog session, 2026-09-24 |
| CAT-2 | Done | Replace duplicate catalog with SDK-backed provider registration | CAT-1 | catalog session, 2026-09-24 |
| CAT-3 | Done | Validate package and Tron consumers; prepare controlled local adoption | CAT-2 | catalog session, 2026-09-24 |
| CAT-4 | Done | Assess subscription-authenticated discovery and record a go/no-go decision | none | catalog session, 2026-09-24 |

Follow the claim-on-main and isolated-worktree protocol before starting a task; keep cross-repository code commits and Tron plan handoffs explicitly linked.

## Task details

### CAT-1 — Catalog authority and compatibility

Read the pinned SDK's model/provider registration and extension documentation. Identify the supported source for the built-in Anthropic catalog independently of CortexKit's override. Prove that repeated registration cannot consume its own previously transformed catalog, recurse, duplicate models, or mutate SDK-owned objects.

Compare SDK entries with the existing CortexKit list and converter branches. Record which models can pass through unchanged, which require proven request adaptations, and which lack evidence. Include currently omitted Haiku/Sonnet/Opus variants where the SDK actually lists them; do not invent model IDs or support based on family-name guesses.

For each accepted model preserve display name, ID, input types/limits, context window, maximum output, reasoning capability, pricing tiers and relevant cache/sampling metadata. Retain only the narrow proven CortexKit overrides. In particular, resolve conflicts between SDK thinking metadata and actual CortexKit request behavior: do not expose unsupported choices or collapse distinct efforts silently. Models without a supported converter path require an explicit disposition, not a hidden fallback to another model.

Define retirement behavior: catalog removal must not rewrite canonical history, silently switch a session/default, or fabricate availability. Distinguish what a pinned SDK update can discover from live account access. If useful existing CortexKit-only entries are absent in the SDK, surface their disposition before deleting them; any temporary explicit additions need a concrete justification and removal condition, not a new parallel catalog.

### CAT-2 — SDK-backed registration

Build provider models from that supported catalog source and apply only necessary CortexKit transport/auth adaptations. Preserve the custom API identity and first-party endpoint so requests continue through the intended stream and usage owners. No raw-key proxy bypass or credential migration.

Use one transformation owner for normal registration and the existing alternate custody registration without enabling the latter. Preserve existing custody semantics; test projection with fixtures rather than activating it. Avoid introducing another polling service or settings store. Repeated reloads must be deterministic and changes in the effective SDK catalog must flow through the existing refresh/reconciliation path.

Tests must exercise the real pinned SDK catalog and registered provider, not a hand-built fixture that accidentally uses the built-in API instead of CortexKit's API. Cover an omitted model now included, exact model IDs/names, model-specific capabilities, absence of unintended aliases/duplicates, catalog mutation isolation, and models added/removed from a synthetic upstream catalog. Keep tool request/response round-trip regressions green.

### CAT-3 — Consumer verification and adoption

Verify the registered catalog through existing Gateway model listing/pagination and native model selection. Preserve authoritative names and decimal versions, exact selected IDs, context limits and supported thinking levels. Fix a generic consumer defect only when demonstrated; do not add per-model UI aliases as a substitute for correct catalog metadata where the authoritative name is available.

Use no-network request captures to prove each supported converter family preserves system instructions, tools, images and appropriate thinking/effort. Test representative advertised effort values and unsupported choices. Keep catalog inclusion separate from successful generation and subscription entitlement in docs and evidence.

Run focused package tests/typecheck/build and applicable Gateway/native tests, using the pinned official Node 22 toolchain and the iOS skill for native work. Update owning package and Tron docs, run documentation/personal-info guards, and build a versioned local package with checksum and source commit provenance. Do not publish it.

Coordinate adoption after source validation: install only through canonical package management under user authorization, avoid active-turn replacement, verify configured package/provider/catalog without logging credentials, and use a fresh session to avoid stale provider metadata. No Gateway rebuild is needed for a package-only change; identify any actual native/Gateway requirement separately. Live generation tests need an explicit bounded scope rather than probing every model. Record remaining account-access uncertainty honestly.

### CAT-4 — Optional discovery feasibility

Time-box an initial read-only source/documentation investigation. Establish whether an Anthropic endpoint supports subscription OAuth and whether its response describes general API models, subscription models, account entitlement, or merely visible IDs. Do not assume an API-key list proves subscription access; do not scrape private browser cookies or create a second login flow.

Before any credential-bearing probe, obtain the required user authorization and use the canonical auth owner, a fixed first-party HTTPS endpoint, bounded response/time, cancellation and sanitized errors. No token logging or automatic generation probes. Investigate pagination, capability completeness, entitlement filtering, deprecation/retirement and rate limits.

Record one outcome: supported and useful; unavailable for this auth mode; or inconclusive with a precise blocker. A useful endpoint may justify a separately scoped implementation using the SDK's existing model-refresh contract, with explicit stale/error behavior and account/credential fences. Do not silently turn this investigation into implementation or a persistent poller. SDK-supplied metadata is not an acceptable silent guess for unknown live IDs. CAT-1 through CAT-3 remain valuable even if discovery is unsupported.

## Findings

### CAT-1 findings

- Catalog source (verified by a read-only script against SDK 0.87.1): the supported source is `anthropicProvider().getModels()` from `@earendil-works/pi-ai/providers/anthropic`, which returns 15 models. Registering a provider with the same ID replaces that provider's models; it does not merge them. A list read after registration can therefore be CortexKit's own transformed list. CAT-2 must capture the built-in list before registering, deep-clone each model before adapting it, and derive both the normal and the Claustrum registration from that one capture. It must never import the generated catalog data.
- Metadata to preserve per model: `id`, `name`, `reasoning`, `thinkingLevelMap`, `input`, `inputLimits`, `cost` (with `tiers`), `promptCache`, `contextWindow`, `maxTokens`, `samplingParams`, `headers` and `compat`. CortexKit's proven adaptations are transport and auth only: the `cortexkit-anthropic-messages` API, the first-party base URL, the OAuth token and its stream. None of its static metadata overrides is otherwise needed.
- The CortexKit converter (packages/pi/src/convert.ts in its checkout) has dedicated branches for Fable and Mythos, Sonnet 5, Opus 5 and Opus 5.5. Every other model gets generic token-budget thinking. SDK effort maps on models without a branch (Opus 4.6 and 4.7, Sonnet 4.6) are therefore not evidence that the generic path works for them.
- Retirement (inspected): Gateway listing projects the current catalog. Pi resolves a missing saved default to an available fallback without rewriting it, and a restored session whose model is gone warns and falls back. Removal never rewrites history, but a later turn can run on the fallback model.

| Model | Today | Decision (user, 2026-09-24) |
| --- | --- | --- |
| Fable 5 and 5.1, Opus 5, Sonnet 5, Opus 4.8, Opus 4.5 (latest), Sonnet 4.5 (latest) | Offered, static metadata | SDK metadata plus the existing converter branch |
| Opus 5.5 | Offers Extra High and Max | Also offer Low, Medium and High if a request capture shows each effort sent; Minimal stays hidden because it cannot be told apart from Low |
| Haiku 4.5, Opus 4.6, Opus 4.7, Sonnet 4.6 and the dated aliases for Haiku 4.5, Opus 4.5 and Sonnet 4.5 | Not offered | Add each only after a no-network capture proves the right thinking and effort shape; otherwise record why it is excluded |
| Mythos 5 and 5.1 (not in the SDK) | Offered | Keep as labelled CortexKit additions, and remove each once the SDK lists it |

### CAT-4 findings

- Outcome: unavailable for this auth mode. Anthropic documents `GET /v1/models` for Console credentials (API key or workload identity) only. Claude Code skips it against the first-party endpoint. Anthropic's terms restrict subscription OAuth to Claude Code and its native apps. Even a successful response lists general API models (with capabilities, `created_at` and pagination, but no retirement field), not what a plan entitles.
- Claude Code obtains subscription model choices from an internal bootstrap endpoint that carries no capability data. Using it would mean relying on an undocumented surface, so it was not pursued. No credentialed request was made.
- Consequence: the pinned SDK catalog stays the model authority. A new model reaches Tron through an SDK update plus CAT-2's projection, not through live discovery.

## Handoff log

Approved and committed at the user's request. No tasks claimed, code changed, packages installed, account probes made, or runtime transitions performed. The earlier rough effort estimate was provisional; CAT-1 must validate the metadata/adapter boundary before promising full model support.

### CAT-1 · Done · 2026-09-24 · catalog session

- Result: established the catalog source, the replacement hazard and each model's disposition; see the CAT-1 findings. The user decided the three open questions: the new models, Mythos and the Opus 5.5 levels.
- Evidence: a read-only script against the pinned SDK (verified); the SDK types, the Pi docs `custom-provider.md` and `models.md`, and the CortexKit sources packages/pi/src/index.ts, packages/pi/src/convert.ts and packages/core/src/models.ts in its checkout (inspected). No live generation.
- Changes: this commit (plan only).
- Tasks added: none.
- For the next agent: CAT-2 must put request-capture proof ahead of each newly added model and each restored Opus 5.5 level.

### CAT-4 · Done · 2026-09-24 · catalog session

- Result: unavailable for subscription OAuth; see the CAT-4 findings.
- Evidence: Anthropic's Models API and authentication docs, Claude Code's gateway and legal docs, and the CortexKit sources (inspected). No credentialed probe.
- Changes: this commit (plan only).
- Tasks added: none.

### CAT-2 · Done · 2026-09-24 · catalog session

- Result: CortexKit builds its Anthropic catalog from one snapshot of the pinned SDK's `anthropicProvider().getModels()`, taken before registration and deep-cloned for each registration (normal and the still-disabled Claustrum). A converter-proven allowlist filters it. Only the transport and auth identity are adapted; every SDK metadata field is kept. The static model list is deleted.
- Models and levels (user decisions, 2026-09-24):
  - Added: Haiku 4.5 and its dated alias, plus dated Opus 4.5 and Sonnet 4.5. They use the budget path, offering Off through High.
  - Mythos 5 and 5.1: kept as labelled additions, to be removed once the SDK lists them.
  - Excluded: Opus 4.6, Opus 4.7 and Sonnet 4.6. The SDK sends adaptive effort for them, while the converter would send token budgets.
  - Fable, Mythos, Opus 5 and Sonnet 5: now offer Low through Max, with each level sent as its own effort value. By the user's choice to fix the converter, adaptive Minimal is sent as Low, as the SDK does. Minimal is hidden where it would duplicate Low. Off is hidden where those models always think.
  - Opus 5.5: Low through Max, each proven distinct.
  - Opus 4.8: keeps its previous budget levels. The SDK's Extra High and Max stay hidden, because the SDK marks it adaptive and CortexKit sends budgets.
- Evidence (verified): pi tests went from 138 in 2.36 s before to 144 in 2.38 s after. A table-driven, no-network request matrix over the real projected catalog checks each included model at each offered level for the right shape (effort, a budget, or nothing for Off), a valid value, and distinct values across levels. Build, typecheck, lint and the pre-commit Biome hook pass. Negative controls, each failing its test: removing the adaptive null overrides, removing the budget null overrides, reusing a projected list, and dropping an allowlist entry.
- Evidence (not established): no live generation was tried, and catalog presence does not prove the subscription can use a model.
- Changes: CortexKit commit `9bfd6cc` (branch `tron/cat-2`, fast-forwarded into the local CortexKit `main`; not published or installed). Tron: this plan entry.
- Tasks added: none.
- Deviations: supervisor review twice sent back the lane's version. The first copied SDK level maps the converter cannot honor: Minimal sent as an invalid effort, and Max silently falling to a medium budget on Opus 4.8. The second held the converter to exact SDK wire values, which the SDK's own mid-conversation behavior makes wrong for CortexKit.
- For the next agent: an adaptive converter branch for Opus 4.8, 4.6 and 4.7 and Sonnet 4.6 would let those models and levels in.

### CAT-3 · Done · 2026-09-24 · catalog session

- Result: isolated Pi ModelRuntime plus Tron's catalog pager projected all 14 CortexKit Anthropic models through 498 pages (limit 3), with exact SDK IDs, names and contexts. Thinking levels matched the SDK's supported-level calculation for all 14. Usage admission already accepts the CortexKit API at Anthropic's first-party host; its focused regression now enumerates all 14 IDs. iOS consumes per-session supported levels dynamically and authoritative catalog names; ID-only fallback formatting covers latest and dated Haiku/Opus/Sonnet names. No live generation or entitlement was tested.
- Evidence (verified): no-network projection with temp agent/auth paths; Gateway build and provider-usage test (20 passed); iOS test build and focused formatting suite (3 passed); CortexKit package build/typecheck and 144 tests passed. Projection was a temporary script and deleted. The first iOS focused run exposed formatting assumptions; the aliases required for correct ID-only decimal names remain as fallback, while catalog summaries use authoritative names.
- Changes: this commit (Tron `ModelDisplayFormatting.swift` and its test, `provider-usage.test.ts`, `packages/ios-app/docs/architecture.md`); CortexKit commit `adde152` (version 1.23.1-tron.4, on top of `9bfd6cc`). Local artifact cortexkit-pi-anthropic-auth-1.23.1-tron.4.tgz in the CortexKit checkout's artifacts folder, SHA-256 `c8b7a73efc856b277709f42aec2efc1e3d8298a38afdb6ab0ca462b8ec7350ae`, 30,737 bytes; not published.
- Adoption: not performed. User must explicitly update the canonical package source in settings, install through package management, and verify provider/catalog in a fresh session. Do not install over an active turn or infer subscription entitlement from catalog presence.
- Tasks added: none.

### CAT-3 correction · Done · 2026-09-24 · catalog session

- Result: this corrects the CAT-3 entry. The adopted package 1.23.1-tron.4 failed to load when installed: the Gateway logged a `runtime.diagnostic` error "Cannot find module" at 20:53 UTC. Pi's extension loader aliases only the pi-ai root, `/compat`, `/oauth` and `/providers/all`, and CAT-2 had imported `@earendil-works/pi-ai/providers/anthropic`. CAT-3's isolated check resolved modules through the package's own `node_modules`, not through the loader, so it missed this. CortexKit commit `8b811d6` (1.23.1-tron.5) reads the catalog with `getBuiltinModels('anthropic')` from `/providers/all`, still deep-cloned. A new test requires every Pi import in the extension to appear in the loader's alias table.
- Evidence (verified): loading the packed artifacts through Pi's real `loadExtensions`, against the installed dependency tree, reproduces the tron.4 failure and loads tron.5 with no errors. Removing the fix fails the new alias test, which names `/providers/anthropic`. CortexKit pi tests 145/145, typecheck and Biome pass. Artifact cortexkit-pi-anthropic-auth-1.23.1-tron.5.tgz (SHA-256 `aac04f863ec389954bf6961776e60bb3de0b90492f5fc831a6ef7af5c08130cb`); not published.
- Changes: CortexKit `8b811d6`; Tron: this entry.
- Tasks added: none.
- For the next agent: until the user installs tron.5, CortexKit is not loaded, and Anthropic requests go through the SDK's built-in provider. Verify an extension adoption with Pi's loader, not only with module resolution.
