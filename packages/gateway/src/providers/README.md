# gateway/providers

## Purpose

Provider-facing policy on top of Pi's model runtime: account usage reads, first-party
OpenAI account eligibility, context-window policy, model fallback queues, recents and
release dates, virtual models and provider-specific request policy (Moonshot Kimi K3).

## Owns

`provider-usage.ts`, `openai-model-eligibility.ts` (`OpenAIModelEligibility`),
`context-window-policy.ts`, `model-queue.ts` and `model-queue-extension.ts`,
`recent-models.ts`, `model-release-date-catalog.ts` (+ JSON data), `virtual-model.ts`,
`kimi-k3-policy.ts`, `jev-model-pricing.ts`, `provider-runtime.ts`.

Queue roles, setting-key addresses and lexical model-reference parsing belong to
[the settings vocabulary](../kernel/settings/README.md), not provider queue execution.
Gateway composition constructs the provider queue with the shared usage/runtime,
projection path and lazy settings reader; Home shares that owner.
The runtime policy assembles its ordinary-session extension after the other modules
and before worker controls, reading canonical fixed settings and the worker fact.

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
  `jev-model-pricing.ts` owns the shared qualified model identity and catalog price;
  the bounded provider decision client consumes that metadata and retains its
  input bounds and price ceilings.
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
  borrows it through the composition-supplied `sessionRuntimeView`; method overrides stay
  session-local, with the view and Home cache policy created only on lazy acquisition) reads the same token's `GET https://api.openai.com/v1/models` (paged, 5 s
  bound, fresh 60 s) and keeps only `visibility: "list"` slugs the SDK registers, in
  account order. That list is the only authority for first-party OAuth choices; before
  a success, or after a failure without a same-token success, OAuth OpenAI offers no
  choices. API-key OpenAI and custom endpoints are unchanged, and a provider with any
  non-first-party model is left alone. Chat/default model changes, `provider.list`
  counts and `model.list.available` apply it; a new session replaces an ineligible
  saved default with the first available model without rewriting settings; existing
  sessions are never rewritten. Extension `ctx.setModel` and extension re-registration
  of `openai`/`openai-codex` are outside this policy (no SDK pre-selection hook).
- **Runtime construction.** `createProviderModelRuntime` supplies canonical auth/model paths,
  offline refresh defaults and Kimi-then-Jev policy wrapping for Gateway and session runtimes.
  The registry receives this factory from composition; injected raw factories use the same policies.
- **Moonshot Kimi K3** caps the completion reservation at 32,768 tokens via
  `max_completion_tokens` (Moonshot TPM counts the reservation). Account and org quota
  errors are non-retryable; max-concurrency with explicit guidance gets one bounded
  retry; transient overload stays retryable.
- **Context extension descriptor.** `createContextWindowModule` registers the existing
  context-window hooks through SessionContext's `restore`/`apply` port and attaches
  owned runtimes through `modelRuntimeInstalled`. Composition supplies the eligibility
  owner; borrowed Home views never attach. Slots retain and release their exact attachment.
  The same policy owns `initialModel`: new runtimes refresh eligibility before accepting a
  saved default or selecting the first eligible fallback; existing transcripts never use it.
  Its `contextPolicy` factory constructs the concrete session policy after SDK creation;
  the runtime keeps only the neutral `ContextPolicy` port and exact-session binding.
  The provider policy remains the sole owner of budgets and canonical overrides.
- **Model recency.** The provider descriptor owns `RecentModelStore`, `model.recent`
  and the `modelUsed` hook. Only admitted user-input runs record usage; preference
  writes stay off the run path, failures diagnose, and shutdown drains writes before
  shared stores release. The kernel never holds or forwards the preference store.
- Context windows, recents and release dates:
  [runtime configuration](../admin/runtime-configuration.md#context-windows).
  Model fallback queues: [settings contract](../../docs/settings-contract.md).

Provider queues and usage adapters consume the common upstream-error vocabulary
in `util/upstream-error.ts`; transcript projections use that same classification.
Queue eligibility still treats both usage caps and throttling as usage-limit
failures. OpenCode Go's usage endpoint retains its distinct entitlement/auth/other
403 outcomes; transcript copy never interprets every 403 as a subscription issue.

## Invariants

- Raw credentials and provider response bodies never leave the Mac or reach logs.
- An account's usage or eligibility list never serves another token or account.
- Tron never migrates or aliases a retired provider ID.

## Entry points

- Usage adapters: `provider-usage.ts`; eligibility: `OpenAIModelEligibility`.
- Queue availability and fallback for worker, background and subagent roles:
  `model-queue.ts`; Home owns worker choice at delegation. Typed queues are the
  routing authority, not learned Profile prose.
- `readWorkerQueueSelection` projects this owner's canonical fallback entries
  after the latest explicit choice. Settings can mask that progression with
  Project without resetting it to the original worker seed.

## Signals

| Signal | Level | Meaning |
|---|---|---|
| `model-queue.skip` | warning | A fallback queue skipped a model for a background call, or a call hit a usage limit: `source: models`, `code` (queue role); the message names `provider/id` and the reason |
| `model-queue.projection` | info when published; warning on failure | A parent published the exact child model-queue projection before launch (`global` or `task-launch`, ordered model IDs), or publication failed and the child tool call was blocked |
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
