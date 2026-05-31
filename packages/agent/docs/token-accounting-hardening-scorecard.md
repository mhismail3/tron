# Token Accounting Hardening Scorecard

Created: 2026-05-31

Initial score: **0/100**

Current score: **75/100 in progress**

Status: **Phase 2 complete; iOS hardening and live/manual verification open**

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
| Kimi | Moonshot/Kimi API docs for prompt caching and usage details | Decode `cached_tokens`, `prompt_tokens_details.cached_tokens`, `completion_tokens_details.reasoning_tokens`, and `prompt_cache_key`. |
| Ollama | Ollama local generation/chat usage docs | Report provider identity and total/input/output when local usage exposes them; cache buckets remain explicit zero/unavailable unless the API adds cache usage fields. |

## Static Gates

`packages/agent/tests/threat_model_invariants.rs` owns the cross-cutting gates:

- This scorecard must exist and be linked from the README living-doc map.
- `Provider::default()` must remain `Unknown`; no provider default may silently
  coerce missing data to Anthropic.
- Event payload token records must stay typed, not opaque `serde_json::Value`
  blobs.
- Server serialization must include cache read/write, 5-minute/1-hour write,
  cached input, reasoning, thought, tool-use, provider, total, and pricing
  fields.
- iOS token records must decode full strict server records including pricing,
  provider, model, segment, and reset reason.
- iOS analytics and message metadata must not contain local pricing tables or
  fallback cost recomputation.
- `message.assistant` reconstruction must not rebuild token totals from legacy
  `tokenUsage` when a canonical `tokenRecord` is absent.
- `TurnEndPlugin` must not default missing turn numbers to `1`.
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
| TAH-1 | Complete | +15 | Canonical Rust `TokenRecord`, provider raw fields, computed buckets, and pricing records | `cargo test --manifest-path packages/agent/Cargo.toml tokens --lib -- --nocapture` passed 221 tests; pricing now requires explicit provider identity and returns unavailable for missing provider. | Live provider canaries still open. |
| TAH-2 | Complete | +15 | Provider adapter decoding and cache request markers for OpenAI, Anthropic, Google, MiniMax, Kimi, and Ollama | Focused provider filters passed: `anthropic` 215, `openai` 248, `google` 146, `kimi` 93, `minimax` 66, and `ollama` 107 tests. MiniMax sends 5-minute cache markers only. | Live provider canaries still open. |
| TAH-3 | Complete | +15 | Session persistence, denormalized columns, counters, context baselines, interruption, resume, provider switch | `turn_runner::persistence` 12 tests, `append_counters` 19 tests, `event_store` 572 tests, focused static gate, and `cargo check` passed. `stream.turn_end` no longer fabricates zero-token usage and `last_turn_input_tokens` requires canonical `tokenRecord.computed.contextWindowTokens`. | Need DB/event-log evidence from live canaries. |
| TAH-4 | In progress | +15 | iOS strict DTOs, analytics, message metadata, context displays, and removal of local pricing | Swift tests drafted; xcodebuild verification pending | Need full compile/test pass and visual fit checks. |
| TAH-5 | Pending | +10 | Automated verification sweep | Planned: `cargo fmt`, `cargo check`, focused Rust suites, `xcodegen generate`, targeted iPhone XCTest/Swift Testing | Broad CI may be expensive; run focused suites first and escalate on shared-contract failures. |
| TAH-6 | Pending | +10 | Live provider matrix | Planned: deterministic fixtures first, then small canaries for every configured credentialed provider | Missing credentials or provider outages are recorded as unavailable evidence, not hidden. |
| TAH-7 | Pending | +10 | iPhone Simulator manual flow | Planned: dashboard, new chat, cached prompt flow, provider switch, reload/resume, metadata, analytics, context views | iPad intentionally skipped. |

## iPhone Manual Evidence Protocol

Use the open Tron Beta iPhone Simulator. If it is inaccessible, force quit
Simulator and reopen the same iPhone target before continuing.

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
| Phase 3 | In progress | iOS DTO/UI cleanup and removal of legacy fallback/pricing logic. |
| Phase 4 | Pending | Full automated tests, live provider matrix, iPhone manual evidence, docs/README updates, ledger entry, and final commit. |
