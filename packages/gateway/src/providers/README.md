# gateway/providers

## Purpose

Provider-facing policy on top of Pi's model runtime: account usage reads, first-party
OpenAI account eligibility, context-window policy, model fallback queues, recents and
release dates, virtual models and provider-specific request policy (Moonshot Kimi K3).

## Owns

`provider-usage.ts`, `openai-model-eligibility.ts` (`OpenAIModelEligibility`),
`context-window-policy.ts`, `model-queue.ts` and `model-queue-extension.ts`,
`recent-models.ts`, `model-release-date-catalog.ts` (+ JSON data), `virtual-model.ts`,
`kimi-k3-policy.ts`, `jev-model-pricing.ts`.

## Contract

- **Pi stays canonical** for provider IDs, credentials, models and retries. The global
  provider runtime (`GlobalProviderResources`, in admin) loads the user's global
  extensions without project resources; project-only extension providers stay in
  their trusted project runtime. It replays every extension's ordered provider
  contributions after unregistering old layers, so removing or reordering a
  contributor leaves no stale fields; a per-extension failure keeps that extension's
  last working registration. Catalog, usage and refresh reads serialize with this
  reconciliation; new global auth is refused retryably while it is pending.
- **Virtual models** are replayed by `GlobalProviderResources`; the picker marks them
  virtual while assistant rows, context limits, usage and cost use Pi's routed
  physical model. Jev uses Pi `ModelRuntime.classify()` with TypeSafe's `jev-latest`;
  Tron keeps input bounds, price ceilings and assessment versions.
- **`provider.usage`** (`provider-usage.v1`) queries only exact first-party shapes:
  Anthropic OAuth (subscription quota `/api/oauth/usage`; also CortexKit's
  `cortexkit-anthropic-messages` at Anthropic's host), OpenAI Codex, OpenRouter, Kimi
  Coding, Z.ai (incl. China), Moonshot Open Platform (balances per region and
  currency, no windows) and OpenCode Go (5-hour, weekly and monthly windows; a 403 is
  unsupported only for `EntitlementError`, rejected for `AuthError`, else unavailable).
  Custom base URLs are unsupported and never sent to a first-party endpoint. Values a
  provider omits stay absent. Exhaustion is a readable window at 100%; no usage read
  skips a model-queue entry. At most 16 providers, 16 windows, 4 balances; successes
  cache 60 s keyed by provider and auth fingerprint, failures back off.
- `provider.list` reports `usageSupported` (the same predicate) and `localOnly` (every
  model and provider base URL host is loopback, so clients show unlimited). A
  credential-only provider may list `modelCount: 0`.
- **OpenAI usage is borrowed** from Codex: only while `openai` uses OAuth and both
  `openai` and `openai-codex` resolve to first-party shapes, `provider.usage` for
  `openai` runs the Codex `wham` read with the Codex credential (`source`
  `openai-codex.wham`) and `provider.list` sets `usageLentTo: "openai"` on the Codex row.
  The `openai` credential is never used for usage; a missing Codex login is
  `unconfigured`; a login change mid-read answers `unavailable`. AuthBroker serializes
  OpenAI and Codex OAuth (both use callback port 1455).
- **OpenAI OAuth eligibility.** One Gateway-wide `OpenAIModelEligibility` owner (Home
  borrows it) reads the same token's `GET https://api.openai.com/v1/models` (paged, 5 s
  bound, fresh 60 s) and keeps only `visibility: "list"` slugs the SDK registers, in
  account order. That list is the only authority for first-party OAuth choices; before
  a success, or after a failure without a same-token success, OAuth OpenAI offers no
  choices. API-key OpenAI and custom endpoints are unchanged, and a provider with any
  non-first-party model is left alone. Chat/default model changes, `provider.list`
  counts and `model.list.available` apply it; a new session replaces an ineligible
  saved default with the first available model without rewriting settings; existing
  sessions are never rewritten. Extension `ctx.setModel` and extension re-registration
  of `openai`/`openai-codex` are outside this policy (no SDK pre-selection hook).
- **Moonshot Kimi K3** caps the completion reservation at 32,768 tokens via
  `max_completion_tokens` (Moonshot TPM counts the reservation). Account and org quota
  errors are non-retryable; max-concurrency with explicit guidance gets one bounded
  retry; transient overload stays retryable.
- **Context extension descriptor.** `contextWindowModule` registers the existing
  context-window hooks through SessionContext's `restore`/`apply` port. The concrete
  session policy remains the sole owner of budgets and canonical overrides.
- Context windows, recents and release dates:
  [runtime configuration](../admin/runtime-configuration.md#context-windows).
  Model fallback queues: [settings contract](../../docs/settings-contract.md).

## Invariants

- Raw credentials and provider response bodies never leave the Mac or reach logs.
- An account's usage or eligibility list never serves another token or account.
- Tron never migrates or aliases a retired provider ID.

## Entry points

- Usage adapters: `provider-usage.ts`; eligibility: `OpenAIModelEligibility`.
- Queue resolution for background and subagent roles: `model-queue.ts`.
- `readWorkerQueueSelection` projects this owner's canonical fallback entries
  after the latest explicit choice. Settings can mask that progression with
  Project without resetting it to the original worker seed.

## Signals

| Signal | Level | Meaning |
|---|---|---|
| `model-queue.skip` | warning | A fallback queue skipped a model for a background call, or a call hit a usage limit: `source: models`, `code` (queue role); the message names `provider/id` and the reason |
| `model-queue.projection` | info when published; warning on failure | A parent published the exact child model-queue projection before launch (`mac` or `task-launch`, ordered model IDs), or publication failed and the child tool call was blocked |
| `model.release-dates` | info on refresh; warning on failure or ignored persisted data | A release-date fetch completed or persisted state was rejected: `updated`, `providers`, `unrecognizedDates`, up to three `unknownDateSamples`, `reason` |
| `request cache coverage` | debug; warning for a non-empty conversation without a cache marker | External: CortexKit Pi `pi-cache` logger, not a Tron stream nor in `system.logs.export`. Model, request ID, cache mode, TTL, wire bytes and breakpoint coverage; a missing marker identifies uncached-history replay |
| `response cache usage` | info, once per metered stream | External, as above: uncached input, output, cache read/write and one-hour writes, with `response-ttl` or `catalog-estimate` pricing basis; estimates are not quota |

## Verify

```bash
scripts/tron verify --module gateway/providers
scripts/tron test gateway src/providers/provider-usage.integration.test.ts \
  src/providers/context-window-policy.integration.test.ts
```

`src/transport/openai-model-eligibility.integration.test.ts` and
`src/sessions/openai-model-eligibility.integration.test.ts` cover the account list.
Live sign-in and the current account's membership remain manual maintainer checks.

## Not here

- Provider auth flows and the model catalog store: [admin](../admin/README.md).
- Connection accounts: [connections](../../docs/connections.md).
