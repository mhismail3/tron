# Token Accounting Hardening Scorecard

Created: 2026-05-31

Initial score: **0/100**

Current score: **100/100 final checkpoint, post-checkpoint audit complete**

Status: **Phase 4 implementation complete; post-checkpoint audit found no remaining token-accounting open loops**

This scorecard owns the token-accounting hardening pass across the Rust
server, provider adapters, event persistence, session counters, pricing, and
iPhone-only iOS display surfaces. It is a living implementation checkpoint for
this campaign, not a replacement for code-adjacent module docs.

## Operating Rules

- The Rust server is the single source of truth for provider identity, model,
  raw provider token fields, computed context-window accounting, cache buckets,
  pricing, and unavailable-cost state.
- iOS is display-only for token price and cost. It may show provisional live
  stream totals while a turn is active, but persisted analytics and message
  metadata must reconcile to the server `tokenRecord`.
- Missing required token-record fields fail visibly at the decoding boundary.
  Do not restore silent defaults such as a missing turn number becoming `1`, an
  unknown provider becoming Anthropic, or a partial token record producing a
  plausible-looking cost.
- Provider semantics are explicit. Cache-supporting providers expose cache
  read/write buckets; no-cache providers report provider identity and zero-cache
  fields without inventing hidden cache semantics.
- Unknown or stale pricing returns an unavailable pricing record with a reason.
  No client or server path may guess a cost from a model-name substring.
- iPhone Simulator is the only manual UI target for this pass. iPad coverage is
  intentionally skipped and remains outside this scorecard.

## Canonical Glossary

Canonical records are serialized as typed `TokenRecord` values and carried by
`message.assistant`, `response.complete`, `agent.turn_end`, session counters,
DB denormalized columns, and iOS DTOs.

Raw provider fields:

- `rawInputTokens`: provider-reported input or prompt tokens.
- `rawOutputTokens`: provider-reported output or completion tokens.
- `rawCacheReadTokens`: provider-reported prompt-cache read/hit tokens.
- `rawCachedInputTokens`: provider-specific cached input alias when distinct
  from cache read.
- `rawCacheCreationTokens`: provider-reported cache write/creation tokens.
- `rawCacheCreation5mTokens`: provider-reported 5-minute cache write tokens.
- `rawCacheCreation1hTokens`: provider-reported 1-hour cache write tokens.
- `rawReasoningOutputTokens`: provider-reported reasoning output tokens.
- `rawThoughtTokens`: provider-reported thought tokens.
- `rawToolUsePromptTokens`: provider-reported tool-use prompt tokens.
- `rawTotalTokens`: provider-reported total when available.

Computed fields:

- `contextWindowTokens`: tokens currently occupying the provider context
  window after applying provider cache semantics.
- `newInputTokens`: the input increase against the active context segment
  baseline.
- `billableBaseInputTokens`: non-cache base input bucket used for pricing.
- `billableCacheReadTokens`: cache-read bucket used for pricing.
- `billableCacheWriteTokens`: aggregate cache-write bucket used for pricing.
- `billableCacheWrite5mTokens`: 5-minute cache-write bucket used for pricing.
- `billableCacheWrite1hTokens`: 1-hour cache-write bucket used for pricing.
- `billableOutputTokens`: output bucket used for pricing.
- `totalTokens`: provider total when exposed, otherwise the canonical raw total.
- `pricing`: server-authoritative component costs plus an unavailable state.
- `provider`, `model`, `contextSegmentId`, `baselineResetReason`: segment
  identity for provider switches, reload/resume, compaction, interruption, and
  cache baseline resets.

Segment rules:

- Provider or model switch starts a new context segment. The next turn baseline
  is reset to zero and analytics identity must use the server segment id, not
  just the display turn number.
- Session resume preserves the segment only when the same provider/model and
  context baseline are still valid; otherwise the server emits a reset reason.
- Cache hits reduce billed base input only for providers whose raw usage
  semantics include cached tokens inside prompt/input totals. Anthropic-style
  `input_tokens` already excludes cache read/write buckets.
- Interrupted turns may persist a partial token record only when provider usage
  exists; otherwise no fallback token usage is fabricated.
- Compaction records the new provider context baseline and must not double
  count pre-compaction input.

## Provider-Doc Audit

Docs rechecked during implementation because cache and pricing semantics are
time-sensitive:

| Provider | Official source | Required accounting behavior |
|----------|-----------------|------------------------------|
| OpenAI Responses | `https://developers.openai.com/api/reference/responses/overview` and OpenAI prompt-caching guidance | Decode `input_tokens`, `output_tokens`, `total_tokens`, `input_tokens_details.cached_tokens`, and `output_tokens_details.reasoning_tokens`; use `prompt_cache_key` only on request paths that cleanly support it. |
| Anthropic | `https://platform.claude.com/docs/en/build-with-claude/prompt-caching` | Preserve `cache_read_input_tokens`, `cache_creation_input_tokens`, and detailed `cache_creation` 5-minute/1-hour write buckets. |
| Google Gemini | `https://ai.google.dev/api/generate-content#UsageMetadata` | Decode prompt, cached content, candidates, thoughts, tool-use prompt, total, and modality details where present. |
| MiniMax | `https://platform.minimax.io/docs/api-reference/anthropic-api-compatible-cache` | Use Anthropic-compatible explicit `cache_control` markers, preserve `cache_creation_input_tokens` and `cache_read_input_tokens`, and price 5-minute cache read/write explicitly. MiniMax docs currently describe a 5-minute ephemeral cache, so no 1-hour TTL marker is sent. |
| Kimi | `https://platform.kimi.ai/docs/api/chat` and `https://platform.kimi.ai/docs/guide/use-kimi-k2-thinking-model` | Decode `cached_tokens`, `prompt_tokens_details.cached_tokens`, `completion_tokens_details.reasoning_tokens`, and `prompt_cache_key`; preserve reasoning content token accounting when the provider exposes it. |
| Ollama | Ollama local generation/chat usage docs | Report provider identity and total/input/output when local usage exposes them; cache buckets remain explicit zero/unavailable unless the API adds cache usage fields. |

## Static Gates

`packages/agent/tests/threat_model_invariants.rs` owns the cross-cutting gates:

- This scorecard must exist and be linked from the README living-doc map.
- `Provider::default()` must remain `Unknown`; no provider default may silently
  coerce missing data to Anthropic.
- Event payload token records must stay typed, not opaque `serde_json::Value`
  blobs.
- `message.assistant` typed payloads must allow provider usage to be absent
  without synthesizing zero-token records.
- Server serialization must include cache read/write, 5-minute/1-hour write,
  cached input, reasoning, thought, tool-use, provider, total, and pricing
  fields.
- Token pricing must not restore dead display helpers, `calculate_cost`
  compatibility wrappers, or model-string provider detection.
- iOS token records must decode full strict server records including pricing,
  provider, model, segment, and reset reason.
- iOS analytics and message metadata must not contain local pricing tables or
  fallback cost recomputation.
- `message.assistant` reconstruction must not rebuild token totals from legacy
  `tokenUsage` when a canonical `tokenRecord` is absent.
- `TurnStartPlugin` and `TurnEndPlugin` must not default missing turn numbers
  to `1`.
- Imported Claude Code sessions must emit canonical `tokenRecord` payloads and
  use server pricing; the import pipeline must not restore a duplicate token
  cost estimator.
- `stream.turn_end` must not persist synthetic zero-token usage when provider
  usage is absent.
- `sessions.last_turn_input_tokens` must come from
  `tokenRecord.computed.contextWindowTokens`, never legacy
  `tokenUsage.inputTokens`.
- MiniMax must keep explicit prompt-cache markers and strip unsupported 1-hour
  TTL from MiniMax requests.

## Scenario Ledger

| ID | Status | Score delta | Scope | Tests/evidence | Residual risks |
|----|--------|-------------|-------|----------------|----------------|
| TAH-0 | Complete | +10 | Scorecard, glossary, provider-doc audit, and static-gate plan | This scorecard plus README and invariant-test updates | Provider docs can drift; rerun the doc audit before changing pricing again. |
| TAH-1 | Complete | +15 | Canonical Rust `TokenRecord`, provider raw fields, computed buckets, and pricing records | `cargo test --manifest-path packages/agent/Cargo.toml tokens --lib -- --nocapture` passed 221 tests; pricing now requires explicit provider identity and returns unavailable for missing provider. | Provider docs can drift; rerun the doc audit before changing pricing again. |
| TAH-2 | Complete | +15 | Provider adapter decoding and cache request markers for OpenAI, Anthropic, Google, MiniMax, Kimi, and Ollama | Focused provider filters passed: `anthropic` 215, `openai` 248, `google` 146, `kimi` 93, `minimax` 66, and `ollama` 107 tests. MiniMax sends 5-minute cache markers only. | Live provider accounting evidence is captured in TAH-6; provider API docs should still be rechecked before future semantic changes. |
| TAH-3 | Complete | +15 | Session persistence, denormalized columns, counters, context baselines, interruption, resume, provider switch | `turn_runner::persistence` 12 tests, `append_counters` 19 tests, `event_store` 572 tests, focused static gate, and `cargo check` passed. `stream.turn_end` no longer fabricates zero-token usage and `last_turn_input_tokens` requires canonical `tokenRecord.computed.contextWindowTokens`. DB evidence from live canaries confirms session counters equal canonical records. | None for token-accounting persistence. |
| TAH-4 | Complete | +15 | iOS strict DTOs, analytics, message metadata, context displays, and removal of local pricing | iPhone 17 Pro Simulator targeted XCTest passed: token/plugin/analytics set 58 tests; final post-audit targeted suite passed 251 XCTest cases plus 30 Swift Testing cases. Static scan found no token-turn `?? 1` fallback and no local pricing table/recompute path in production code. Import preview now consumes server `totalCost`, and imported events use canonical token records instead of a duplicate estimator. Dashboard and deep Agent Control evidence confirm running-app fit for provider/model/token/cost/cache rows. | None for token-accounting UI. |
| TAH-5 | Complete | +10 | Automated verification sweep | Final post-audit `scripts/tron ci fmt check clippy test` passed; final iPhone 17 Pro Simulator targeted XCTest/Swift Testing passed 251 XCTest cases plus 30 Swift Testing cases after the Agent Control pending-state fix. | None for the automated token-accounting gates. |
| TAH-6 | Complete | +10 | Live provider matrix | Current-server live canaries produced canonical, priced token records for Anthropic, OpenAI, Google, MiniMax, Kimi, and Ollama. Anthropic cache write/read, Google cached input/thought tokens, Kimi cache-read pricing, and no-cache MiniMax/Ollama behavior are recorded in the event DB. | The ROC-2 Kimi execute workflow still stopped after a provider `tool_calls` response without materialized execute calls; a separate no-tool Kimi canary reached `end_turn` and verified token accounting. Treat the tool-call behavior as a non-accounting follow-up. |
| TAH-7 | Complete | +10 | iPhone Simulator manual flow | The open iPhone 17 Pro Simulator was force-quit/reopened on the same device, the freshly built Tron Beta app was installed, and Computer Use verified dashboard, message metadata, Agent Control overview, Analytics detail, and Context detail. The Agent Control overview now shows pending placeholders during event-summary load and then reconciles to server values (`14.8k`, `$0.002`, `2 turns`) for Kimi live canary `sess_019e7d99-2338-7d81-a41d-05398a473f17`. | iPad intentionally skipped by scope. |
| TAH-8 | Complete | +0 | Post-checkpoint audit cleanup | Removed dead token-pricing compatibility/display helpers and model-string provider detection; made typed `message.assistant` token usage optional when provider usage is absent; clarified import aggregate-cost comments to describe available server-priced token-record sums; fixed Agent Control overview cards so pending event sync shows placeholders instead of misleading zero token/history values. Focused pricing, typed-payload, static-gate, full Rust CI, final iPhone targeted tests, and live Simulator manual checks pass. | No token-accounting open loops found in the audit. Residual Kimi tool-call materialization caveat remains unchanged from TAH-6 and is non-accounting. |

## Final Automated Verification

- Final post-audit `scripts/tron ci fmt check clippy test` passed after the
  server cleanup and iOS audit fixes.
- Final iPhone 17 Pro Simulator targeted test command passed 251 XCTest cases
  and 30 Swift Testing cases across event transformation, turn grouping,
  context state, lifecycle coordination, event dispatch, chat routing, token
  formatting, and Agent Control pending-state formatting.
- Earlier focused suites passed for provider token fixtures, import canonical
  records, strict iOS token decoding, turn start/end fallbacks, analytics
  segment identity, and no-local-pricing static scans.

## Live Provider Evidence

Evidence was captured from the current user server and the event-store DB:

| Provider | Model | Session | Token-accounting evidence |
|----------|-------|---------|---------------------------|
| Anthropic | `claude-sonnet-4-6` | `sess_019e7d8e-c010-78c3-8876-813e51be409c` | Session totals: input `5`, output `669`, cache read `36033`, cache write `19401`, cost `$0.1262634`. Turn records preserve cache write/read buckets and per-turn pricing. |
| OpenAI | `gpt-5.5` | `sess_019e7d8e-f7a0-7d83-8bfe-bf7790d1ec9b` | Session totals: input `55169`, output `335`, cache read/write `0`, cost `$0.285895`. Records use provider `openai`, direct calculation, and server pricing. |
| Google | `gemini-2.5-flash` | `sess_019e7d8f-1f5a-73f2-84e2-fcbb8887a058` | Session totals: input `51644`, output `412`, cache read `15964`, cost `$0.003098925`. Records preserve cached input plus thought-token buckets. |
| MiniMax | `MiniMax-M2.7` | `sess_019e7d8f-431f-73c1-8167-3bd9a08a9684` | Session totals: input `65815`, output `883`, cache read/write `0`, cost `$0.0208041`. Records keep explicit provider identity and zero-cache semantics for this canary. |
| Kimi | `kimi-k2.5` | `sess_019e7d99-2338-7d81-a41d-05398a473f17` | No-tool canary reached `end_turn`; totals: input `14726`, output `67`, cache read `14592`, cost `$0.0017406`. Records preserve Kimi cached-token pricing. |
| Ollama | `gemma4:e4b` | `sess_019e7d92-c8b6-7232-bbbf-2563eee2ef65` | Session totals: input `13300`, output `994`, cache read/write `0`, cost `$0.0`. Records keep provider `ollama` and free local-model pricing. |

The Kimi ROC-2 execute-matrix session
`sess_019e7d8f-66d0-7e42-ab43-c57202cd0da1` also emitted a canonical Kimi
token record and priced session totals (`15033` input, `281` output,
`$0.0098628`), but it did not complete the execute workflow. That residual is
tracked as provider tool-call materialization, not token accounting.

## iPhone Simulator Evidence

Manual target: iPhone 17 Pro Simulator
`267F6468-09AE-471D-9157-29144173EB82`, Tron Beta
`com.tron.mobile.beta`.

Final post-audit manual verification used Computer Use against the open
Simulator after force-quitting/reopening the same iPhone target and explicitly
installing the freshly built Tron Beta app:

- `/tmp/tron-token-qa/iphone-dashboard-final.png`
- `/tmp/tron-token-qa/iphone-dashboard-reopened.png`

The dashboard shows the live provider sessions with server-owned token/cost and
model metadata fitting in-row, including long model titles, unavailable-small
cost display (`<$0.01`), zero-cache local-model pricing, and cache-heavy hosted
provider sessions. The post-audit manual pass also verified the Kimi live
canary chat row, Agent Control pending placeholders, Agent Control reconciled
analytics/history values, Analytics detail cache-read/cost breakdown, and
Context detail sections on iPhone.

## iPhone Manual Evidence Protocol

Use the open Tron Beta iPhone Simulator. If it is inaccessible, force quit
Simulator and reopen the same iPhone target before continuing.

Manual coverage target: dashboard, new chat, cached prompt flow, provider switch, reload/resume, metadata, analytics, and context views.

Required flow:

1. Dashboard loads without stale token/cost metadata.
2. New chat creates a session and streams a response.
3. Cacheable prompt flow records cache write on first turn and cache read on a
   follow-up where the provider supports caching.
4. Provider/model switch creates a new segment and does not merge analytics by
   repeated display turn number.
5. Reload/resume preserves or resets baselines only according to server segment
   rules.
6. Message Metadata, Agent Control Analytics, and Context views display
   provider, model, input, output, cache, total, and cost/unavailable state
   without clipping long model ids or overriding server truth.

## Phase Checkpoints

| Phase | Status | Checkpoint contract |
|-------|--------|---------------------|
| Phase 1 | Complete | Scorecard, glossary, provider-doc audit, and failing/static coverage added; open loops recorded. |
| Phase 2 | Complete | Server canonical schema, adapters, pricing, persistence, counters, and context baselines. |
| Phase 3 | Complete | iOS DTO/UI cleanup and removal of legacy fallback/pricing logic. |
| Phase 4 | Complete | Full automated tests, live provider matrix, iPhone manual evidence, docs/README updates, ledger entry, and final commit. |
