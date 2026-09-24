# Agent-owned Knowledge enrichment

- **Started:** 2026-09-23
- **Status:** Active
- **Last updated:** 2026-09-23, approval
- **Goal:** Let authorized agents and automations enrich existing Library sources through the canonical Knowledge owner, with dynamic dashboard updates and no deployment per content update.

## Goal and constraints

Preserve canonical source evidence, stable record identity, privacy/admission rules, existing capture and summarization behavior, and native navigation/scroll continuity. Do not modify Knowledge files or its catalog outside the owning interfaces. Do not replace the existing storage architecture, add a mirror, introduce an arbitrary JSON patch API, or build a backfill-only publishing mechanism.

The initial backfill and future automated processing must use the same bounded, typed enrichment contract. Agents may publish summaries, semantic/keyword tags, important evidence-backed links/references, and supported metadata without a new Gateway build per item or batch. New executable capabilities or genuinely new field types can still require code changes; this is not arbitrary schema evolution at runtime.

No production deployment or Gateway rebuild/restart/update may be initiated by an agent. The maintainer performs the one-time runtime update after source validation. Do not enable recurring automation, change provider/model settings, repair credentials, or spend on a corpus-wide run as part of drafting/implementation. Existing user authorization covers DeepSeek pilot processing; larger execution requires an explicit bounded run policy.

## Context

Inspected 2026-09-23 on `main` at `be5da003c`; this is a focused owner-boundary inspection, not an exhaustive audit.

- `packages/gateway/docs/knowledge.md` describes immutable record revisions and content-addressed objects plus a **canonical transactional SQLite catalog**. The catalog owns heads, exact revision ownership, lexical indexes, receipts, exclusions, and checkpoints. Files are durable evidence, not an independently editable application API.
- `packages/gateway/src/knowledge/knowledge-store.ts` owns serialized publication. Files are synchronized before the catalog publishes heads and receipts; failed publication must not expose partial state.
- `packages/gateway/src/knowledge/knowledge-service.ts` and `packages/gateway/src/knowledge/knowledge-contract.ts` expose model-owned source summarization. It generates through the configured Knowledge model; it does not accept externally generated enrichments. The agent-facing Knowledge tool lacks the required publishing operation.
- Existing iOS source detail rendering supports summaries and tags. `packages/ios-app/Sources/UI/Automations/KnowledgeDashboardView.swift` already incorporates `knowledgeInvalidationRevision` into its managed load identity. Trace and reuse its producer before adding any notification or polling mechanism; verify open detail-sheet refresh as well as catalog refresh.
- Three DeepSeek v4.1 Flash candidates were retained outside the canonical Library. They use freshly fetched public pages, not proven-identical saved source evidence, and have differing tag field names. They are untrusted candidates, not directly importable records. No Library update has been made from them.
- Live Raindrop metadata retrieval failed with credential unavailable. Retained provider representations may supply original save dates without network/credentials; verify through the owner's exact-record object read. Do not rely on an unverified corpus census or filesystem inspection.

## Plan rules

- This plan is approved and Active. Claim each task on `main`, implement in its own isolated branch/worktree, and update this plan with the implementation commit.
- Evidence and interpretation remain distinct. Summary text is a model interpretation; provider-save dates and publication dates need field-specific source evidence. An ingestion timestamp is never an originating save date.
- Never bind a fresh web-page summary to an old source digest merely because the URL matches. Capture refreshed evidence through the source owner first, or regenerate against the retained exact revision. Preserve historical evidence and original-save provenance.
- Do not claim semantic correctness from schema validation. Verify structural safety at publication and evaluate content quality with a bounded human-reviewed pilot.
- Existing sessions/automation owners orchestrate work; parent sessions retain Gateway capability authority. Delegated workers receive bounded evidence packets and return candidates. Do not grant them credentials or unrestricted canonical access.

## Tasks

| ID | Status | Scope | Depends on | Owner |
| --- | --- | --- | --- | --- |
| E1 | Ready | Define and implement evidence-bound source enrichment publication through the existing owner and agent tool | none | — |
| E2 | Ready | Add verified provider-date recovery and refreshed-evidence handling | E1 | — |
| E3 | Ready | Make external enrichment visible in catalog, search, and open source details | E1 | — |
| E4 | Ready | Wire a bounded agent/automation processing procedure using the shared contract | E1, E2 | — |
| E5 | Ready | Validate cross-boundary failure/recovery behavior and document the operational contract | E2, E3, E4 | — |
| E6 | Ready | Maintainer runtime update, then apply and inspect the three-item pilot | E5 | — |

## Task details

### E1 — Canonical enrichment publication

Owning seams: `packages/gateway/src/knowledge/knowledge-contract.ts`, `packages/gateway/src/knowledge/knowledge-service.ts`, `packages/gateway/src/knowledge/knowledge-store.ts`, `packages/gateway/src/transport/gateway-service.ts`, and `packages/gateway/src/workspace/tron-core-extension.ts`.

Implement a typed enrichment command exposed consistently to authorized parent-agent Knowledge tools and existing transports. Final naming is an implementation decision, but do not overload a generation request with ambiguous generate-versus-import semantics. Separate model execution from publication while reusing one publication validator/store boundary for built-in generation and external candidates.

Contract requirements:

- Command ID, target source ID, expected source revision, exact evidence references, bounded summary/tags/references, and producer provenance including provider/model and generation time. Label caller-supplied producer claims appropriately; do not imply cryptographic model attestation.
- Explicit supported fields; unknown/unbounded fields rejected. Define omitted/present/empty-field behavior, preserve unrelated values, and never offer arbitrary record replacement. No implicit clearing of existing enrichments or evidence.
- Separate original/provider tags from generated semantic/keyword tags. Distinguish verified important references from raw extracted links. Bound counts, lengths, encoded size, and URL schemes/credentials.
- Owner verifies evidence authority and derives evidence fingerprints from the cited immutable material. Fingerprint all input dimensions that affect the result, not just convenient title/text fields. Document whether evidence is full saved text, a bounded excerpt, a captured thread, or linked source revisions. Do not imply full discussion coverage from complete HTTP capture.
- Receipt replay and same-command/different-payload rejection before publication; exact revision/config/privacy fences; exclude/forget/suppress races fail closed. Successful replay cannot recreate deleted data. No model dispatch on candidate import.
- Short publication transaction; agent/model computation remains outside the catalog lock where feasible, with final compare-and-publish fencing. Do not hold the owner hostage during remote inference.
- Preserve unchanged old records without rewriting the corpus. No speculative backward-compatibility layers or automatic migration/backfill.

Focused tests must cover successful publish/read/replay, changed-payload replay rejection, stale source revision, evidence mismatch, unsafe references, oversized candidates, and suppression/forget racing completion. Update owning Gateway docs in the same change.

### E2 — Evidence and date recovery

Owning seams: `packages/gateway/src/knowledge/source-capture.ts`, `packages/gateway/src/knowledge/connectors.ts`, Knowledge service/store, and `packages/gateway/docs/knowledge.md`.

Provide a bounded owner-mediated metadata reconciliation path. Prefer retained provider-api objects bound to exact source revisions; recover Raindrop `created` as originating save time, not publication time. Preserve the original field provenance and uncertainty. Recover original provider tags separately from AI tags when available. Unknown publication dates remain unknown; `lastUpdate`, capture time, and filesystem mtime are not substitutes.

Fresh article/thread/linked-page evidence must pass through the existing capture authority before enrichment can cite it. Inspect extraction quality: navigation/tag-menu boilerplate must not consume the useful evidence budget unnoticed. Missing/poor extraction is a per-item needs-evidence outcome, not fabricated successful enrichment. Reuse or fix the owning extractor rather than adding per-website summary hacks.

Acceptance: retained provider evidence can recover a date without credentials; absent/ambiguous metadata makes no unsupported claim; invalid object authority fails; refreshed source evidence invalidates or marks dependent enrichment stale; unrelated metadata-only edits do not unnecessarily discard still-valid interpretations. Test old misfiled Raindrop publication timestamps and preserve recoverable values without blindly relabeling them.

### E3 — Dynamic dashboard and search

Owning seams: Gateway Knowledge mutation notification path, `packages/ios-app/Sources/State/AppModel.swift`, `packages/ios-app/Sources/State/KnowledgeRPCClient.swift`, `packages/ios-app/Sources/Models/KnowledgeModels.swift`, and `packages/ios-app/Sources/UI/Automations/KnowledgeDashboardView.swift`.

Trace successful external publication through the existing Knowledge invalidation mechanism. Reuse that mechanism rather than introducing a new journal, mirror, broad polling timer, or duplicate event system. Publish invalidation only after commit; failed or replayed operations must not masquerade as new revisions.

An active Library list and an already-open source/details sheet must eventually show the authoritative new revision without reopening the app or restarting the Gateway. Reconnect/reactivation re-reads authoritative data after missed invalidations. Use managed presentation activity and latest-request fences through every await; preserve scroll, selected source identity, navigation, and accepted mutation ownership. Do not overwrite unsaved note edits.

Update canonical lexical search fields for new summary/tags as appropriate; stale intake boilerplate must not remain the only searchable description. Existing list ordering is update-time based: preserve its contract and test movement/continuation behavior, not an invented stable order.

Tests: background-agent publish while list visible, while details visible, while details subsheet is open, disconnected, inactive, and during a newer search request. Demonstrate old responses cannot overwrite new data. Capture an actual simulator before/after with synthetic records and label it honestly. Follow the iOS skill and avoid device installs.

### E4 — Shared processing procedure

Use existing session/schedule orchestration with parent-owned publication. Do not introduce a second job engine or parallel Knowledge database. Provide bounded tool results sufficient to construct exact evidence packets without manually paging an entire corpus into a model.

Procedure: enumerate eligible sources with bounded owner pagination; read exact evidence; skip valid enrichment; recover metadata; capture additional evidence only under authorized scope; delegate bounded interpretation to the selected model; validate returned structure/coverage; publish with a stable command ID; read back the resulting revision; report applied/skipped/conflicted/needs-evidence/failed counts.

Explicit first-run policy: small batch, bounded parallelism, user-selected `opencode-go/deepseek-v4.1-flash`, limits on items and tool/model consumption, and a stop rule. Do not change the global Knowledge model just to support one run. Reuse existing durable receipts/checkpoints where needed; avoid a permanent full-library shadow queue. Enumeration must tolerate update-time reordering and repeated sources; do not claim a snapshot census from moving pages.

Resume uses accepted command receipts and fresh eligibility checks, not blind replay of provider/model calls after uncertainty. Bound automatic retries and distinguish idempotent publication from exactly-once paid inference, which is not guaranteed by a write receipt alone. Cancellation stops new dispatches and preserves already accepted publication outcomes.

Document use by both initial backfills and future explicitly configured automations. Reading or opening a sheet never triggers paid generation. Implementing this procedure does not create/enable a recurring schedule.

### E5 — Integration confidence and owner docs

Run focused gateway contract/store/service/capture tests and native state/model/UI owners, then a final cross-boundary integration case. Include negative controls proving evidence/revision fences and catalog invalidation are necessary. Test failure between immutable bytes and head/receipt commit, stale completion after recapture, duplicate delivery, config/privacy changes, disconnect/reconnect, and runtime interruption with explicit receipt recovery.

Update `packages/gateway/docs/knowledge.md`, `packages/gateway/README.md` where appropriate, and `packages/ios-app/docs/knowledge-sources.md`. Explain actual boundaries and operational recovery, not implementation inventories. Verify tool registration and generated/external consumers. Run `scripts/personal-info-guard.sh` and diff checks. Keep real bookmark payloads, account IDs, personal URLs, candidate drafts, and tokens out of repository fixtures/docs; use synthetic fixtures.

Acceptance evidence separates source compilation, unit tests, simulator behavior, and live pilot results. No live provider calls or live Library mutations are necessary to validate implementation.

### E6 — One-time activation and pilot

This task remains blocked operationally until the maintainer performs the validated Gateway update (and native app update if changed UI contracts require it). Agents may prepare artifacts and report exact manual actions, but must not initiate lifecycle transitions. Verify live capability availability afterward; source merges do not prove a running capability exists.

Before applying the three existing candidates, read the latest target revisions and validate their evidence. Normalize their differing tag shapes at the procedure boundary. Either capture the fresh fetched material through the owner and rebind/regenerate, or regenerate from exact saved evidence. Never stamp the old stored digest onto an externally researched summary. Retain only useful references, and shorten overlong summaries for the intended Library surface.

Run the three-item pilot through the same procedure future automations use. Verify all accepted results through Knowledge reads and dashboard refresh; separately inspect original save/publication provenance and important links. Report exact applied counts and remaining failures. Do not infer success from output artifacts alone. Expand to a larger backfill only after the pilot is judged useful and a bounded run policy is approved.

Completion bar: one successful agent-generated update and one update from the existing automation execution path (a controlled fixture may validate orchestration without enabling recurrence), both visible via the canonical dashboard read path without a second Gateway rebuild. Subsequent ordinary content updates require neither a deployment nor source changes.

## Handoff log

Approved for tracking and committed at the user's request. No tasks claimed or executed. Drafting inspected the storage owner documentation, summarization entrypoints, and existing dashboard invalidation consumption; implementation must complete producer-to-consumer tracing before choosing changes. No tests, live writes, schedules, or Gateway lifecycle actions were performed for this proposal.
