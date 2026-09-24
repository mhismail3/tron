# SDK-backed Anthropic model catalog

- **Started:** 2026-09-24
- **Status:** Active
- **Last updated:** 2026-09-24, approval
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
| CAT-1 | Claimed | Establish SDK catalog source and per-model adapter compatibility contract | none | catalog session, 2026-09-24 |
| CAT-2 | Ready | Replace duplicate catalog with SDK-backed provider registration | CAT-1 | Unassigned |
| CAT-3 | Ready | Validate package and Tron consumers; prepare controlled local adoption | CAT-2 | Unassigned |
| CAT-4 | Claimed | Assess subscription-authenticated discovery and record a go/no-go decision | none | catalog session, 2026-09-24 |

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

## Handoff log

Approved and committed at the user's request. No tasks claimed, code changed, packages installed, account probes made, or runtime transitions performed. The earlier rough effort estimate was provisional; CAT-1 must validate the metadata/adapter boundary before promising full model support.
