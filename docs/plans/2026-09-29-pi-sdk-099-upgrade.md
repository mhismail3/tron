# Pi SDK 0.99 integration and built-in MCP adoption

- **Started:** 2026-09-29
- **Status:** Active
- **Last updated:** 2026-09-30, P99-17 Gateway evidence correction and observability
- **Goal:** Move Tron's pinned Pi runtime from 0.87.1 to 0.99.1, disposition every upstream delta, replace Tron's custom MCP adapter with Pi's built-in MCP, codemode and tool-search extensions, and support the new capabilities end to end on the Gateway and iOS.

## Goal and constraints

What must not change:

- Canonical runtime JSONL, settings, credentials, packages and resources stay
  authoritative (AGENTS rule 3). Old sessions open unchanged; no session is
  rewritten or migrated.
- Chat identity, scroll continuity, composer behavior and existing tool cards
  are preserved. A nested tool call never becomes a canonical chat row.
- No Gateway rebuild, restart, promotion or deployment by agents (rule 8). The
  upgrade changes `packages/gateway/package-lock.json`, so the user adopts it
  only through a newly signed Tron build; "Rebuild from Source" refuses a lock
  change by design.
- No compatibility shims, dual MCP schemas, or a second MCP configuration
  authority. After this plan Tron has exactly one MCP client (Pi's) and one MCP
  configuration authority (Pi's `mcp.json`).

Rules that override an agent's judgment:

- Pin **0.99.1**, not 0.99.0: 0.99.1 fixes the missing bundled
  `openai-chatgpt.js` module and adds GPT-6.1 Sol. Re-check npm `latest` at
  claim time; a newer patch restarts P99-1.
- Use `npm run update:pi-sdk -- <exact-version>`; never hand-edit lockfiles.
- All work happens on one candidate branch in an isolated worktree with its own
  `npm ci`, and merges to `main` once, after P99-17. Gateway and iOS protocol
  changes ship together.
- "Full support" means every applicable delta in the change matrix has one
  disposition: inherited with targeted evidence; adapted and tested; obsolete
  Tron code removed; deferred with reason and acceptance; not applicable with
  owner rationale; or open blocker. Compilation alone is insufficient.
- Any event, persistence, projection, packaging, UI or UX difference not listed
  here as an accepted delta is a behavior-delta stop: compare current and
  candidate behavior and get an explicit product decision.
- Tests follow the testing policy: E2E first, with a retained artifact at a
  stable path; isolated tests only for a written failure mode that E2E misses.

## Context

Dated 2026-09-29.

### Release facts

- npm publishes `0.99.0` and `0.99.1` directly after `0.87.1`; there are no
  0.88–0.98 releases, so the 0.99.0 and 0.99.1 changelogs are the whole delta.
- Node engine is unchanged (`>=22.19.0`); project Node 22.22.0 meets it. The
  `pi` bin is still `dist/bundle/cli.js`. Pi's build moved to TypeScript 7 with
  an ES2024 target; Tron's TypeScript 5.9.3 reads the new declarations.
- `pi-coding-agent` adds two family packages, `@earendil-works/pi-mcp`
  (standalone MCP client, no official SDK dependency) and
  `@earendil-works/pi-codemode` (QuickJS sandbox, pulls in `quickjs-wasi` with a
  `.wasm` file). Both install nested under `pi-coding-agent`'s shrinkwrap, like
  its existing nested `pi-ai`/`pi-tui` copies.
- The SDK does **not** load built-in extensions. The CLI loads `llama.cpp`,
  `codemode`, `tool-search` and `mcp` as `builtin:<name>` extensions; SDK hosts
  must add `createCodemodeExtension()`, `createToolSearchExtension()` and
  `createMcpExtension()` to `DefaultResourceLoader.extensionFactories`
  themselves. The llama.cpp factory is not root-exported.

### Probe evidence (disposable worktree, unmodified Tron source)

A detached worktree at the plan's base commit installed 0.99.1 with
`npm install --ignore-scripts` (no lock or source committed; the worktree was
removed afterwards):

- `tsc --noEmit`: 5 errors. Three are compatibility-manifest exhaustiveness
  (new events `mcp_servers_change`, `provider_stream_event`; new `ExtensionAPI`
  members `getSettings`, `registerMcpServer`, `unregisterMcpServer`,
  `getMcpServers`, `registerVirtualModel`, `unregisterVirtualModel`; new
  `ToolDefinition` fields `annotations`, `outputSchema`, `exposure`,
  `namespace`, `defaultActive`, `prepareLoadout`). Two are in
  `packages/gateway/src/sessions/runtime-slot.ts`: the subagent stop path passes
  `createContext()` where tool `execute` now needs an `ExtensionToolContext`
  (use `extensionRunner.createToolContext(id, signal)`), and `preflightResult`
  now reports a `"handled" | "queued" | "started"` disposition and is **no
  longer called on rejection**.
- Full Gateway Vitest under Node 22.22.0: 2,197 of 2,198 pass (204 files,
  85 s). The only failure is `rekeys the owning slot when a completed session is
  forked`: a fork holding only a user entry now materializes its JSONL at once
  (Pi #10000), where the test asserts it stays unmaterialized.
- `node scripts/check-pi-sdk.mjs` rejects the lock: unexpected `pi-codemode` and
  `pi-mcp`.
- The small compile/test surface is misleading: nothing in the current suite
  loads the built-in extensions, issues nested tool calls, or registers a
  virtual model. Those are where the real integration work is.

### Live installation facts (read-only)

- `~/.tron/state/integrations/connections.json` holds one instance
  (`knowledge.raindrop`) and **no MCP instance**. There is no `mcp.json` in the
  agent directory. Removing Tron's MCP adapter therefore strands no user data.
- Installed packages: `pi-subagents@0.59.0`, `pi-web-access@0.22.0`,
  `pi-agent-browser-native` (git), `@mocito/pi-goal@0.1.11`, CortexKit
  `1.23.1-tron.7`. None registers `/mcp`, `codemode` or `tool_search`, so none
  would replace a built-in. `pi-subagents` runs children as `pi --mode json -p`,
  i.e. through the CLI, which **does** load the built-ins; with an explicit
  extension list it passes `--no-extensions`, which in 0.99 also drops them.

### Tron's current MCP footprint (to be removed)

| Owner | What exists only for MCP |
| --- | --- |
| `mcp-adapter.ts` in `packages/gateway/src/integrations/` (303 lines, deleted in P99-7) + test (222) | Official `@modelcontextprotocol/sdk` 1.25.2 client, HTTP endpoint lock, stdio env allowlist, bounded discovery (128 tools), `mcp_<instance>_<tool>` names, per-connection call lane, unknown-outcome reporting |
| `packages/gateway/src/integrations/connection-contract.ts`, `connection-owner.ts` | `mcp` implementation kind, `McpConnectionConfiguration`, `mcp.remote-http` definition, `endpoint`/`local-command` setup methods, `markRuntimeReady`, `admitRuntimeBinding` and `RuntimeBinding` (only caller is the adapter) |
| `packages/gateway/src/sessions/runtime-slot.ts`, `runtime-registry.ts`, `packages/gateway/src/gateway-main.ts` | Adapter wiring and `tron-mcp-<n>` inline extensions |
| `packages/gateway/src/protocol/types.ts`, `packages/gateway/src/sessions/gateway-work-registry.ts`, `packages/gateway/src/transport/gateway-service.ts` | `McpToolSource`, `modules.list.connections`, `mcp-tool-call` work kind |
| `packages/gateway/src/sessions/agent-instructions.ts` | `{ kind: "mcp" }` source detected from `<inline:tron-mcp-*>` |
| `packages/gateway/docs/mcp.md`, `packages/gateway/docs/connections.md` | Adapter contract docs |
| iOS | `IntegrationsSettingsView` MCP surface and setup form, `McpToolSource`, `mcpToolCall`, MCP rows in `ExtensionsSettingsView`, `AgentInstructionsSheet` MCP kind, Settings "MCP Servers" link, related tests |

### Pi built-in MCP compared with Tron's adapter

| Area | Tron adapter | Pi 0.99 built-in |
| --- | --- | --- |
| Configuration | ConnectionOwner instance set up from iOS | `mcp.json` in the agent dir plus trusted project `.pi/mcp.json`; `pi.registerMcpServer()` for extensions |
| Transports | stdio, streamable HTTP | same; HTTP retries transient failures twice; lazy reconnect |
| Auth | Static bearer from Keychain | `${ENV}`/`!command` header values; OAuth with PKCE and dynamic client registration, refresh with cross-process lock, tokens in `mcp-auth.json` |
| Tool naming | `mcp_<instance>_<tool>` | `mcp__<server>__<tool>`, namespace per server |
| Exposure | all tools declared | `codemode` (default), `codemode-deferred`, `deferred`, `direct`, `hidden`, per-tool `toolExposure` |
| Features | tools only | tools, `list_changed`, resources (`list_mcp_resources`, `list_mcp_resource_templates`, `read_mcp_resource`), server instructions, progress, logging to `mcp.log`, structured results |
| Result bounds | 512 KiB result, 256 KiB text | 16 MiB message cap; text over 20 KB is middle-truncated for the model with the full text in a temp file |
| stdio environment | SDK allowlist + configured env | inherits the Gateway environment (same as the `bash` tool) |
| HTTP endpoint | redirects refused, origin/path locked | normal fetch; OAuth reaches authorization servers |
| Write policy | connection needed explicit `allowWrites` | adding the server is the trust decision; annotations (`readOnlyHint`, `destructiveHint`, …) exposed to `tool_call` gates |
| Drain tracking | `mcp-tool-call` work item | ordinary tool execution inside the owning agent run |
| Management | iOS setup/disconnect | `/mcp` (TUI manager; plain status text in RPC mode), `/mcp login|logout|reconnect`, `pi mcp add|remove|list [--json]|login|logout` |
| Hooks for hosts | — | `createMcpExtension({ loadConfig, createTransport, credentials, logPath, openUrl, updateConfig, startupWaitMs })` |

Pi covers everything the adapter did except the stricter endpoint lock, stdio
environment allowlist and per-connection write approval; those are recorded as
accepted deltas or decisions below rather than rebuilt.

## Plan rules

### Decisions

The user answered D-1 through D-7 on 2026-09-29. The plan remains Proposed
until the user approves it.

- **D-1 MCP management surface: CLI plus a Tron patch writer.** `mcp.json` is
  the only configuration authority. The Gateway lists status with the bundled
  CLI (`pi mcp list --json`, out of process and bounded like HTML export), adds
  and removes servers with `pi mcp add|remove` (global, or `-l` in a trusted
  project), and signs out with `pi mcp logout`. A bounded Tron writer edits
  only `enabled` and `exposure` of one existing entry so the iPhone can toggle
  them now. The writer is deleted once Pi root-exports `updateMcpServerConfig`
  (P99-19). Rejected: keeping ConnectionOwner MCP instances fed through
  `pi.registerMcpServer()` (two configuration authorities).
- **D-2 Static bearer tokens: Keychain plus `!command`.** The token is stored
  in the Mac Keychain; `mcp.json` holds a header whose `!command` prints
  `Bearer <token>` via `/usr/bin/security`, so the secret never enters a file,
  log or projection.
- **D-3 Codemode reach: allow every tool.** Codemode scripts may call any
  `direct` tool, including `ask_user`, `display`, `computer`,
  `native_capture`, `notify`, `schedule`, `jev` and `subagent`, in parallel and
  in loops. No exposure restriction or nested-call gate is added. Instead each
  Tron tool must stay correct when called nested and concurrently (P99-5 and
  P99-6), and existing per-tool limits (notification quotas, Jev charge
  ceilings, subagent limits) are the bounds.
- **D-4 MCP call approval: adding the server approves it.** No per-call
  prompt.
- **D-5 Codemode and tool search: only when MCP needs them.** Not in
  `defaultTools`; the MCP extension activates them when a server's exposure
  needs them; iOS Settings offers `+codemode` and `+tool_search` toggles and
  `codemode.mode`.
- **D-6 Jev: migrate to Pi now.** Tron's `JevDecisionClient` is replaced by
  `ModelRuntime.classify()` over Pi's `typesafe` provider, and the credential
  moves to Pi's provider credential store (P99-20). Accepted loss: the `jev`
  tool no longer returns the score legend or score probabilities, and `noul`
  answers become Pi's `bool` probability. Knowledge assessment uses only choice,
  confidence and score, which Pi returns. **User-chosen addendum (2026-09-30):**
  Tron follows Pi's catalog model `jev-latest`; TypeSafe's actual model and price
  may change without a Tron release. The pre-dispatch ceiling and recorded
  estimated costs use Tron's qualified $0.042/M input, zero-output estimate,
  not Pi's zero catalog cost; this is an estimate, not provider billing.
- **D-7 Virtual models: support them.** Selectable in the iOS picker, routed
  physical model shown per response, limits and cost from the physical model.
- **D-8 Nested presentation persistence is parent-owned.** A Tron inline
  extension observes nested `tool_result` events with `parentToolCallId` for
  admitted display artifacts and trusted browser live views. It retains only
  bounded artifact descriptors and a browser receipt resealed for the parent
  call ID, never payload bytes or secrets. Count/byte overflow sets `complete:
  false`. On the parent's result it returns `details` equal to original details
  plus `tronNested: { display, browserLiveViews, complete }`; it does not return
  `content`, preserving Pi content and `structuredContent`. The per-parent stash
  clears on parent completion, `agent_end` (including abort), and runtime
  `session_shutdown`. Pi persists this enrichment on the parent result; Gateway
  live/cold projection reads that same canonical details key and authorizes
  browser receipts against the parent's canonical tool-call ID. The accepted
  wire addition is namespaced `details.tronNested`; older iOS clients ignore it.
  The 0.87.1 rollback reader must likewise ignore the extra details key.

### Accepted deltas

Adopting Pi's MCP accepts these changes from the adapter's contract: stdio
servers inherit the Gateway environment; HTTP transports follow normal fetch
redirects and reach OAuth authorization servers; results use Pi's bounds and
temp-file truncation; tools default to codemode exposure instead of direct
declaration; a server listed in `mcp.json` needs no separate write approval
several loaded runtimes each run their own stdio server process. Codemode
scripts may call every `direct` tool, including interactive, paid and
subagent tools (D-3). Each accepted delta is documented in `packages/gateway/docs/mcp.md`. Pi's process-global markdown/select/settings helpers use deterministic `dark` colors rather than the host-owned RPC callback palette because no public per-instance global setter exists; the user confirmed this visible color difference on 2026-09-30; it is tracked for an upstream setter request in P99-19.

### Ownership rules for this plan

- Nested tool calls (`parentToolCallId`, IDs `<parent>/<n>`) are live
  presentation children of their parent tool execution. They never create
  canonical rows, invocation receipts or top-level tool cards; cold history
  reads them from the parent result's `nestedCalls`.
- Tron composes built-in extensions in one shared list used by session
  runtimes and session-free administrative loads, so `-builtin:<name>` and the
  Extensions screen agree.
- The MCP extension is bound explicitly to Tron's agent directory
  (`loadConfig`, `credentials`, `logPath`); it must not read `getAgentDir()`
  implicitly, because tests and the Gateway pass the agent directory by
  argument.
- Record each delta's disposition in the change matrix below until close-out.

### Change matrix

Every 0.99.0 and 0.99.1 changelog entry, with Tron's disposition and owning task.

| Upstream delta | Tron disposition | Task |
| --- | --- | --- |
| Built-in `codemode`, `tool_search`, MCP extensions (stdio/HTTP, OAuth, `mcp.json`, `registerMcpServer`, `/mcp`, `pi mcp …`) | **Adopt**: P99-22 qualifies runtime transports; P99-7 removes Tron's adapter; P99-8 adds CLI administration, bounded patching and the session-bound OAuth relay through Pi's `/mcp login` command, with local PKCE/dynamic-registration/callback/token-refresh evidence | P99-6, P99-7, P99-8, P99-22 |
| Tool API: `exposure`, `namespace`, `annotations`, `outputSchema`/`structuredContent`, `isError` results, `prepareLoadout`, `ctx.executeTool` with `parentToolCallId` and bounded `nestedCalls` | **Adapt**: P99-3 classifies the new API and attributes `prepareLoadout`; P99-5 projects nested calls as bounded children under the parent and preserves failed/structured-result semantics; P99-22 parts 2a/2b verify nested interactive limits, notification and schedule receipts, desktop serialization, native-view session ownership, plus part 2c verifies concurrent Jev pre-dispatch ceilings and nested foreground-subagent Stop/workspace handoff. P99-23 persists bounded Tron presentation descriptors on the parent's canonical result under `details.tronNested`; rollback readers ignore this additive details key. | P99-3, P99-5, P99-6, P99-22, P99-23 |
| Warning when an extension replaces a built-in | **Adapt**: project `LoadExtensionsResult.warnings` in extension/package lists | P99-6 |
| Virtual models (`registerVirtualModel`, routed model, per-physical-model cost, router state entry) | **Adapt** per D-7: global administrative resource reload replays and removes virtual registrations; model.list marks virtual rows; context/compaction policy uses SDK-routed physical limits; assistant rows project physical identity and thinking level; SDK stats/usage remain attached to physical response models. Resume/fork/automatic retry/compaction cross-path integration evidence remains a P99-17 checkpoint. | P99-10, P99-15 |
| Sign in with ChatGPT on `openai`; `deviceId` in global settings | **Adapted**: AuthBroker passes the global SettingsManager's stable `getDeviceId`; settings projection omits `deviceId`; OpenAI and Codex legacy OAuth are serialized on shared fixed port 1455; provider list exposes both OpenAI methods without claiming OpenAI OAuth usage support. Fake-fetch AuthBroker test captures `urn:uuid` host ID and relays the callback through token exchange. | P99-9 |
| `system` theme default; `#rgb`/`oklch()`/`okhsl()`; `theme.style()`, `theme.colors`, `theme.appearance`; revised dark/light | **Adapted; user confirmed color delta on 2026-09-30**: process-global markdown/select/settings helpers explicitly initialize `dark` because the Gateway has no terminal and no public per-instance global setter; this output differs from the host-owned RPC callback baseline. Remote frames parse dark-theme truecolor into bounded RGB styles; callback-injected baseline output is unchanged. P99-19 should request a root-exported per-instance theme setter. | P99-11, P99-19 |
| Classifier models (`ModelRuntime.classify`, TypeSafe `jev-latest`, inherited Jev on OpenRouter/Cloudflare/Vercel/OpenCode Zen) | **Adopt/adapt**: codemode classification is inherited; Tron routes Knowledge, session search, and the `jev` tool through `ModelRuntime.classify()` on catalog `typesafe/jev-latest`, preserves request bounds and the pre-dispatch qualified-price ceiling, assessment versions, and notSent/sent/uncertain semantics; tool answers use Pi bool/score shape. TypeSafe remains visible with configured credentials and no chat models. | P99-12, P99-20 |
| llama.cpp classifier; llama.cpp context-window fix | **Not applicable**: Tron does not load the llama.cpp built-in (factory not root-exported) | — |
| `fullscreenWheelScrollLines` setting | **Not applicable** (TUI only); not added to the settings projection | — |
| Per-input disposition for `prompt`/`steer`/`follow_up`; `steer()`/`followUp()` return `"handled" \| "queued"` | **Adapt**: handled prompts settle without an agent turn; SDK rejections settle admission through the thrown error; handled items during queue rebuild get completed receipts and are removed from the queued projection | P99-3 |
| `ModelRuntime` image generation and typed model accessors; discriminated extension model lists | **Verified/inherited**: image and classifier model definitions validate through Pi's models.json schema; typed catalog image/classifier entries persist and reload, while chat `model.list` remains chat-only. Image generation deferred to P99-21. | P99-12, P99-21 |
| pi.dev catalog `types=chat,image,classifier` | **Verified/inherited**: fake-fetch refresh asserts all three requested types, persists the typed catalog in `models-store.json`, and restores its chat projection offline. | P99-12 |
| `mcp_servers_change`, `provider_stream_event` | **Classify** `pi-runtime`; no Tron consumer | P99-3 |
| HTML export show/hide toggle for `display: false` messages | **Inherit** through the out-of-process `--export`; the P99-17 artifact verifies hidden custom messages retain `display: false` and the renderer's hidden-message class/toggle | P99-17 |
| Claude Sonnet 5.5 (0.99.0); GPT-6.1 Sol and Codex default (0.99.1); Kimi K3 defaults for Fireworks/Together/OpenCode Go | **Verified/inherited**: refreshed release-date snapshot; catalog regression pins Sonnet 5.5 at 1,000,000 context / 128,000 output and GPT-6.1 Sol at 272,000 / 128,000. K3's 1,048,576 context/output catalog metadata does not widen Tron's 32,768 TPM reservation cap; payload normalization keeps the provider's `max_tokens` field. | P99-12 |
| Built-in section in `pi config`; `-builtin:<name>` in `extensions`; SDK `builtin: true` | **Adapted**: compose built-ins in Gateway; Extensions settings patches `-builtin:` switches from the scoped settings projection | P99-6, P99-15 |
| `defaultTools` `+name`/`-name` entries | **Adapted**: Extensions settings projects and patches default tools, including `+codemode`, `+tool_search`, and `codemode.mode` | P99-6, P99-15 |
| codemode `models.classify` cost added to tool result usage; `ctx.executeTool` usage added to the calling result | **Verified** Pi's session stats include tool-result usage, exercised with a priced nested fixture result | P99-5 |
| TypeScript 7 / ES2024 build; `tsx` replaced by Node type stripping | **Adapt**: P99-3 resolves its five candidate API integration errors; Node 22.22.0 is the validation runtime | P99-2, P99-3 |
| Startup header/banner and `[Themes]` changes; light/dark detection order; `TERM=*-direct` | **Not applicable** (TUI only) | — |
| OpenAI Codex provider renamed "OpenAI Codex (legacy)" | **Inherit**; iOS shows provider names from the Gateway | P99-9 |
| `builtin:<name>` naming in errors, diagnostics and source info | **Adapt**: agent-instructions and extension diagnostics map `builtin:` sources | P99-6 |
| `--no-extensions` also disables built-ins | **Verified**: normal `pi-subagents` child launch (`pi --mode json -p`) leaves ambient extensions enabled and loads codemode, tool-search and MCP; its explicit extension-list branch adds `--no-extensions`, and the same Pi 0.99.1 loader then registers none of those built-ins. The default child inherits the Gateway's agent-dir environment, therefore shares global `mcp.json`/`mcp-auth.json`; explicit MCP direct-tool selections serialize a bounded config subset via `--mcp-config`, with the same auth store. | P99-14 |
| Tool calls without a renderer show arguments; MCP titled `server/tool` | **Adapt** iOS generic tool card for MCP titles | P99-16 |
| `bash`/`powershell` structured results up to 1 MiB with `truncated`/`full_output_path`; empty output `""` instead of `(no output)` | **Verified/adapted**: a retained faux-provider codemode E2E proves Tron `DirectBashProcessOwner` preserves Pi's output schema through owned `BashOperations`, including >1 MiB truncation, full-output path, empty output and nonzero exit; nested abort kills its owned process tree. Gateway projection preserves empty content; existing `ToolDetailPresentationTests.commandAndExplicitEmptyOutput` confirms iOS renders no fabricated result. | P99-13 |
| Managed git packages no longer auto-install Pi peers; warning for host modules in `dependencies` | **P99-14 correction (P99-17)**: the earlier qualification accidentally loaded upstream `pi-agent-browser-native@0.8.2`, not the installed fork. A read-only copy of the actual user installation is `0.4.1` + Tron-only commit `1b5f11bb251843f5b7536eea9eea7b17f96ac970`; settings pin `d6cde09af8d7757bbfba5a4ffaf83381bb392683`, so reinstall drops the Tron browser-binding change. Browser package-upgrade qualification must account for Node 24.21, trusted binding authorization, codemode/tool-search overlap and the native engine change 0.33.2 → 0.38.1; no upgrade or user install change is authorized here. | P99-14 correction, P99-24 |
| New sessions persisted at the first user message (#10000) | **Adapted**: forks materialize with retained user entries; catalog parent identity comes from normalized canonical header paths; pre-message receipts persist with the first user message, proven by teardown/reopen integration | P99-4 |
| RpcClient listener fix; X11 clipboard; Finder paste; Kitty images; cursor after exit; `/settings` input; autocomplete fixes; pinned `-e` git refs | **Not applicable** (Tron uses the SDK, not RpcClient or the TUI) | — |
| Provider fixes: Vercel 1-hour cache pricing, `samplingParams`, Mistral GLM and reasoning, OpenAI Fast pricing, OpenCode qwen thinking replay, Responses without `output_index`, OAuth error redirects and busy callback port, Copilot Opus levels | **Inherit**; classifier/image `ProviderModelConfig` union definitions also qualify through models.json validation and CortexKit-style custom-provider configuration. Provider-specific fix coverage remains with Pi except where an owning Tron seam has a regression. | P99-12 |
| Footer/bash/`sanitizeBinaryOutput` CPU reductions | **Inherit** | — |
| Family graph: `pi-mcp`, `pi-codemode`, `quickjs-wasi` | **Adapt**: checker admits the new packages at the observed nested `pi-coding-agent` paths; helper tests lock down placement. Payload verification deferred because the bundler performs `npm ci` and publishes generated resources. | P99-2 |

## Tasks

| ID | Status | Scope | Depends on | Owner |
| --- | --- | --- | --- | --- |
| P99-1 | Done | Verify npm latest, activate plan, claim, create isolated candidate worktree | none | orchestrator session, 2026-09-29 |
| P99-2 | Done | Pin 0.99.1 with the helper; admit `pi-mcp`/`pi-codemode` in the SDK checker; rollback baseline 0.87.1; payload verification | P99-1 | luna-worker, 2026-09-29 |
| P99-3 | Done | SDK API adaptations: manifest, tool context, prompt/steer/follow-up dispositions, attribution of `prepareLoadout`, `deviceId` redaction | P99-2 | luna-worker, 2026-09-29 |
| P99-4 | Done | Session materialization at first user message (#10000): tests, ownership, durability docs | P99-2 | luna-worker, 2026-09-29 |
| P99-5 | Done | Nested tool calls, `isError` and structured results through live and canonical projections and protocol | P99-3 | luna-worker, 2026-09-29 |
| P99-6 | Done | Compose Pi built-ins (codemode, tool search, MCP) in sessions and admin loads; codemode reach policy; `defaultTools` | P99-3, P99-5 | luna-worker, 2026-09-29 |
| P99-7 | Done | Delete Tron's MCP adapter, `@modelcontextprotocol/sdk`, ConnectionOwner MCP generality and protocol fields | P99-6 | luna-worker, 2026-09-29 |
| P99-8 | Done | Gateway MCP administration RPCs and OAuth sign-in relay | P99-6 | luna-worker, 2026-09-30 |
| P99-9 | Done | Provider auth: Sign in with ChatGPT, device ID, Codex legacy, usage disposition | P99-3 | luna-worker, 2026-09-29 |
| P99-10 | Done | Virtual models on the Gateway (D-7) | P99-3 | luna-worker, 2026-09-29 |
| P99-11 | Done | Theme default and remote extension host rendering | P99-3 | luna-worker, 2026-09-29 |
| P99-12 | Done | Catalog, provider and classifier deltas; release dates; K3 policy | P99-2 | luna-worker, 2026-09-29 |
| P99-13 | Done | `bash` structured output and empty-output change | P99-3 | luna-worker, 2026-09-29 |
| P99-14 | Done | Qualify installed packages and subagent children against 0.99 | P99-6 | luna-worker, 2026-09-30 |
| P99-15 | Done | iOS settings: MCP Servers screen, built-in toggles, default tools; remove old MCP UI and models | P99-7, P99-8 | luna-worker, 2026-09-30 |
| P99-16 | Done | iOS chat: codemode, nested calls, MCP and tool-search cards, routed model display | P99-5, P99-10 | luna-worker, 2026-09-30 |
| P99-17 | Claimed | Docs, observability, full validation, E2E artifacts, rollback matrix, payload | P99-2 … P99-16, P99-20 | luna-worker, 2026-09-30 |
| P99-18 | Ready | Integration to `main` (user approval), manual acceptance gates, close-out | P99-17 | Unassigned |
| P99-20 | Done | Migrate Tron's Jev client, tool, assessments and session-search ranking to `ModelRuntime.classify()` (D-6) | P99-12 | luna-worker, 2026-09-29 |
| P99-19 | Needs scoping | Upstream requests: root-export MCP config helpers (retires the D-1 patch writer); root-export a per-instance theme setter; public per-session MCP status/process count (user authorizes filing) | P99-8, P99-11 | Unassigned |
| P99-21 | Needs scoping | Image generation through `ModelRuntime.generateImages()` as a Tron capability | P99-12 | Unassigned |
| P99-22 | Done | Complete P99-6 nested/concurrent first-party tool and Pi MCP stdio/HTTP E2E qualification before allowing codemode access broadly | P99-6 | luna-worker, 2026-09-29 |
| P99-23 | Done | Parent-owned persistence/projection for bounded nested display artifacts and trusted browser live-view receipts, with no child canonical rows or independent receipts | P99-22 | luna-worker, 2026-09-29 |
| P99-24 | Needs scoping | Browser-package upgrade follow-up: reconcile Node 24.21 requirement; carry the Tron-only browser-binding commit (install pin currently points to d6cde09 and reinstall drops it); authorize `agent_browser_code` in `browser-live-view-adapter.ts`; account for overlap with codemode/tool-search and native engine 0.33.2 → 0.38.1. docs/plans/2026-09-30-node-runtime-lifecycle.md (Proposed) proposes taking over the runtime requirement. | P99-14, P99-17 | Unassigned |

## Task details

### P99-1 — Verify, activate, claim, isolate

Confirm `npm view @earendil-works/pi-coding-agent dist-tags.latest` is 0.99.1
(or restart with the newer patch and re-read its changelog). After approval,
commit this plan as Active, claim P99-1 on `main`, and create the candidate
branch and worktree with a real `npm ci` (no symlinked `node_modules`). Run
Vitest with Node 22.22.0 (the nvm install works; the app-bundled Node cannot
load Rolldown's native binding).

### P99-2 — Package graph and payload

- `npm run update:pi-sdk -- 0.99.1` in the candidate worktree.
- Add `@earendil-works/pi-mcp` and `@earendil-works/pi-codemode` to
  `PI_PACKAGES` in `packages/gateway/scripts/check-pi-sdk.mjs` after checking
  their registry metadata (version, gitHead, integrity, engines) matches the
  family; extend `check-pi-sdk.test.mjs` and `update-pi-sdk.test.mjs` with the
  nested-shrinkwrap placement the probe observed. Drop `pi-client` and
  `pi-protocol` only if the release no longer publishes them.
- Set `packages/gateway/pi-sdk-baseline.json` `rollbackVersion` to 0.87.1
  (it still says 0.84.4).
- Stage the Mac payload with `packages/mac-app/scripts/bundle-gateway.sh` and
  verify it: `quickjs.wasm`, codemode worker files and `pi-mcp` must be present
  and hashed; the `.bin/pi` alias and runtime tree check must pass.
- Evidence: `check:pi-sdk`, `test:pi-sdk-scripts`, `npm audit signatures`,
  `compare-pi-sdk-graph.mjs` output, payload verifier.

### P99-3 — SDK API adaptations

Owning files: `packages/gateway/src/extensions/compatibility-manifest.ts`,
`packages/gateway/src/sessions/runtime-slot.ts`,
`packages/gateway/src/extensions/owner-attribution.ts`,
`packages/gateway/src/admin/settings-service.ts`.

- Manifest: classify the two events, six API members and six tool fields as
  `pi-runtime` (virtual model registration notes P99-10).
- Subagent stop: call the tool with
  `extensionRunner.createToolContext(toolCallId, signal)`.
- Prompt admission: map `preflightResult` dispositions to the invocation
  lifecycle. Rejection now arrives only as the thrown SDK error, so audit every
  path that waited for `preflightResult(false)` and resolve admission from the
  rejection instead. Consider projecting `handled` distinctly (extension
  command or input handler consumed the prompt) rather than as an accepted
  run.
- Queue rebuild: `session.steer()`/`followUp()` may return `"handled"`; such an
  item is not in Pi's queue and must be terminalized, not left as queued.
- Owner attribution: wrap `prepareLoadout` with the extension's owned callback
  like `renderCall`, so its failures carry attribution.
- Settings: remove `deviceId` from the global-document projection sent to iOS
  (Pi omits it from bug reports); do not add terminal-only
  `fullscreenWheelScrollLines`.
- Acceptance: `tsc` clean; focused runtime-registry cases for extension
  command, input-handled and queued prompts; queue rebuild with a consuming
  input handler.

### P99-4 — Session materialization at the first user message

Pi now writes a new session file when it first contains a user or assistant
message. Setup-only sessions still stay in memory; canonical receipts appended
before the first message are flushed with it.

- Update `rekeys the owning slot when a completed session is forked` in
  `packages/gateway/src/sessions/runtime-registry.integration.test.ts` to
  assert the fork is materialized at its retained first user entry and the cold
  catalog reads its parent identity from the canonical header. Remove the live
  parent-identity projection: forks cannot remain unmaterialized after copying
  a user entry.
- Re-examine live-only ownership in `packages/gateway/src/sessions/runtime-registry.ts`
  (automation-owned sessions are bound "until Pi persists their first
  user or assistant message") and the catalog admission paths keyed on
  `persistedSessionFile`.
- The durability limitation documented in `packages/gateway/README.md`
  (automation lease, notification admission, invocation receipts) and at
  `persistVerifiedCustomEntry` in `runtime-slot.ts` shrinks: receipts appended
  before the first user message are flushed with it. Pre-message failures of a
  brand-new session remain memory-only. Rewrite those passages to the new
  boundary and add the crash/reopen integration test the comment asks for (the
  first invocation's receipt survives a runtime teardown after the user
  message is appended).
- Update the context-window override warning in
  `packages/gateway/src/providers/context-window-policy.ts` ("persist after the
  first user or assistant message").
- Accepted product delta: a session whose first turn fails now stays in the
  session list. Confirm with the user in P99-18 if it surprises them.

### P99-5 — Nested tool calls, error and structured results

Nested calls from codemode reach Tron's session subscriber as
`tool_execution_start|update|end` with `parentToolCallId` and IDs
`<parent>/<n>`. Today `runtime-slot.ts` would create top-level live tool rows
for them that never receive a canonical result.

- Live projection: attach nested executions to their parent
  `ToolExecutionState` (bounded list: name, status, duration, bounded args or
  byte count), never as independent rows, segments, receipts or extension
  activity. Retire them with the parent.
- Canonical projection: expose the parent result's `nestedCalls` record
  (bounded, `complete` flag) in `packages/gateway/src/sessions/projection.ts`
  so reload shows the same children.
- Audit every owner keyed by `toolCallId` for nested IDs: invocation lineage,
  tool segments, `observeTrustedAgentBrowserResult`, ask-user and display
  admission, the `tool_call` subagent workspace handoff in
  `packages/gateway/src/workspace/tron-core-extension.ts`.
- `isError` results and `structuredContent`: failures reported without
  throwing must project as failed; `structuredContent` stays out of mobile
  payloads unless bounded and needed by a card.
- Cost: session totals include tool-result `usage` (codemode classify cost).
- Protocol: add the fields to `packages/gateway/src/protocol/types.ts` and the
  iOS models in the same change (P99-16 renders them).
- E2E: a faux-provider session runs a codemode script that calls `read`, `bash`
  and a failing tool in parallel; the retained snapshot artifact shows one
  codemode row with three children live and after reload, and no orphan rows.

### P99-6 — Built-in extension composition

- One Tron-owned list of `{ name, factory, builtin: true, replaceable: true }`
  entries for `codemode`, `tool-search` and `mcp`, used by the runtime factory
  in `runtime-slot.ts` and by
  `packages/gateway/src/admin/session-free-extensions.ts` (and the provider
  loader in `packages/gateway/src/admin/global-provider-resources.ts` if
  virtual models need it), so `-builtin:<name>` disables them everywhere and
  `hooks.list`/`packages.list` report them.
- `createMcpExtension` options: `loadConfig` bound to Tron's agent dir and the
  trust service's decision; `credentials` and `logPath` under the same agent
  dir; `openUrl` routed to the P99-8 relay (never the Mac browser); keep the
  default `startupWaitMs` unless Stop latency during the first prompt's wait
  proves a problem.
- Codemode reach per D-3: no exposure restriction. Prove each first-party tool
  under nested, concurrent calls from one script: concurrent `ask_user` forms
  are serialized or rejected truthfully by the semantic UI broker; `notify`
  quota and rate limits hold; `computer` and `native_capture` actions do not
  interleave on one desktop target; `display` artifacts attach to the codemode
  row; `schedule` mutations keep command receipts; `jev` enforces its per-call
  charge ceiling; nested `subagent` calls keep the Gateway workspace handoff
  and foreground-subagent stop routing, which today assume a top-level tool
  call ID.
- `defaultTools` per D-5: settings projection and validated patch for
  `defaultTools` (including `+`/`-` entries) and `codemode.mode`/`inlineBudget`.
- Tool projections (`availableTools`, agent resources, `setTools`) carry
  `exposure`, `namespace` and `annotations`; `setTools` rejects `hidden`.
  Active tools can now change without Tron's `setTools` (MCP activation,
  `tool_search`), so the snapshot must re-read the active set rather than rely
  on `session.contextChanged` from Tron's own mutation.
- Diagnostics: agent-instructions and extension error projections map
  `builtin:<name>` sources; project `LoadExtensionsResult.warnings`.
- Codemode lifecycle: Stop aborts a running script's worker; a Gateway drain
  waits for it; a script cannot outlive its runtime. Prove with a script that
  sleeps and one that loops tool calls.
- E2E with fixture servers (stdio and streamable HTTP, in-repo test fixtures):
  codemode exposure, direct exposure, deferred via `tool_search`, resources,
  `list_changed`, a server crash and lazy reconnect, and stdio process-group
  cleanup on session shutdown and runtime eviction (no orphan processes).

### P99-7 — Remove Tron's MCP implementation

Delete the footprint listed in Context: the adapter and its test, the
`@modelcontextprotocol/sdk` dependency, the `mcp` implementation kind,
`McpConnectionConfiguration`, the `mcp.remote-http` definition, `endpoint` and
`local-command` setup methods, `markRuntimeReady`, `admitRuntimeBinding`,
`RuntimeBinding`, the `mcp-tool-call` work kind, `modules.list.connections`,
`mcpToolSourceInstances`, the `tron-mcp-*` wiring and the `mcp` instruction
source. Update the `connections` tool description in
`tron-core-extension.ts`. Persisted state: the live store has no MCP instance;
confirm on the candidate that the connection loader still accepts the current
file. Rewrite `packages/gateway/docs/mcp.md` as the built-in adoption boundary
(authority, credentials, accepted deltas, sign-in relay) and remove the MCP
clauses from `packages/gateway/docs/connections.md`.

### P99-8 — Gateway MCP administration and sign-in

- RPCs per D-1: `mcp.list` (scope global or trusted project cwd; runs the
  bundled `pi mcp list --json` out of process with bounded output, timeout and
  drain-aware work registration, only on explicit request, never polled),
  `mcp.add`, `mcp.remove`, `mcp.logout`, and `mcp.update` for `enabled` and
  `exposure`. `mcp.update` is the D-1 patch writer: it changes one existing
  entry in the scope's `mcp.json` under a file lock, preserves every other key
  and entry, rejects unknown servers and exposures, bounds the file size, and
  fails closed on a file it cannot parse. Mutations
  carry command IDs with bounded receipts; results name the servers a running
  session will pick up only after reload.
- Bearer tokens per D-2: Keychain item plus `!command` header; the token never
  reaches `mcp.json`, logs or projections.
- OAuth sign-in: reuse the `AuthBroker` loopback-callback capture and relay in
  `packages/gateway/src/admin/auth-broker.ts`. The MCP extension's `openUrl`
  hook hands the authorization URL (its `redirect_uri` names Pi's loopback
  listener) to a sign-in operation bound to the session; iOS presents it like
  provider OAuth and returns the callback, which the Gateway relays. Pi's
  pasted-redirect input stays available as the fallback. A session-free
  sign-in path, if needed, waits for P99-19.
- Running sessions pick up sign-ins on their next turn (Pi reconnects on
  `turn_start`); add/remove need `/reload` or a new session — say so in the
  RPC result.
- File the P99-19 requests only with the user's authorization.

### P99-9 — Provider auth

- `AuthBroker` calls `modelRuntime.login(provider, type, interaction)`; Sign in
  with ChatGPT throws without `{ getDeviceId }`. Pass
  `() => settingsManager.getOrCreateDeviceId()` from the global settings owner.
- The ChatGPT flow listens on fixed `127.0.0.1:1455` like Codex legacy;
  confirm the fixed-port conflict handling serializes them.
- Provider list shows the `openai` provider with both API key and OAuth and
  the renamed Codex (legacy); usage support for `openai` OAuth is not claimed
  (`packages/gateway/src/providers/provider-usage.ts` supports only the Codex
  `wham` endpoint) until verified.
- Evidence: fake-credential wire capture of the authorization URL and token
  exchange; live sign-in is a P99-18 manual gate.

### P99-10 — Virtual models

- Global picker: `GlobalProviderResources` replays provider registrations only;
  replay virtual model registrations too, so global extensions' virtual models
  appear in `model.list`. Mark them virtual; their limits may be undefined.
- Context and compaction: `SessionContextWindowPolicy` looks up the selected
  model, which is virtual; use the physical limits model the SDK uses (latest
  response's physical model, else declared limits).
- Projection: each assistant row carries its physical `provider/model` and
  `thinkingLevel`; the session header shows selection and routed model; the
  `VIRTUAL_MODEL_STATE_ENTRY` custom entry stays hidden; usage and cost group
  by physical model.
- `packages/gateway/src/runtime/compaction-policy.ts` and the abort-aware
  stream wrapper must see the routed physical model and pass
  `onProviderStreamEvent` through.
- Evidence: a fixture router extension over two faux models, across resume,
  fork, retry and compaction.

### P99-11 — Theme and remote extension host

`packages/gateway/src/sessions/semantic-ui-broker.ts` explicitly initializes
Pi's process-global theme as `dark`: the Gateway has no terminal, so `system`
can remain grey/pending, and Pi exposes no public per-instance global theme
setter. This yields deterministic dark-palette markdown/select/settings helper
output and valid bounded RGB styles when parsed into remote frames. Global helper
colors differ from the host-owned 256-color RPC callback baseline; the user
confirmed this accepted delta on 2026-09-30 (request a root-exported per-instance
setter under P99-19). `theme.style()`, `theme.colors` and `theme.appearance` are
verified on the RPC baseline `Theme`; callback-injected rendering remains byte
identical. Manifest rows describe both boundaries.

### P99-11 · Done · 2026-09-30 · luna-worker

- Result: Process-global Pi helpers are pinned to `dark`, avoiding the terminal-dependent system theme in the terminal-less Gateway. The RPC callback keeps its independently owned 256-color baseline; remote markdown frames parse dark-palette truecolor to valid RGB styles.
- Evidence: Node 22.22.0 TypeScript check and `check:pi-sdk` passed; personal-info guard and `git diff --check` passed. Full `semantic-ui-broker.test.ts` passed 29/29 in 0.92 s; focused theme proof passed 1/1 in 0.44 s before the full file run; pre-fix capture showed the system helper frame diverged from the committed callback baseline (heading ANSI 3 vs 6 and code ANSI 5 vs 3). The test covers global markdown/select/settings helper stability under TERM/COLORFGBG/FORCE_COLOR changes, remote frame parsing, byte-identical callback baseline output, and baseline `style()`, `colors`, `appearance`. Final full Gateway Vitest run passed 2,308/2,310 tests across 212/214 files in 114.91 s; unrelated recent-model-usage ordering and logger-rotation timeout failures passed isolated reruns (3/3 in 1.52 s, 1/1 in 1.68 s).
- Changes: `semantic-ui-broker.ts`, its test, `compatibility-manifest.ts`, and this plan.
- Tasks added: none.
- Kept on purpose: no private global symbol or deep package import; Pi's public root API has no process-global per-instance setter. RPC callback theme remains session-independent.
- Deviations: Global helper output is dark-palette truecolor rather than the RPC callback's legacy ANSI-index palette. The user confirmed this accepted delta on 2026-09-30. P99-19 now includes an upstream request for a root-exported per-instance theme setter.
- For the next agent: P99-19 should file the per-instance setter request; P99-17 should run the full Gateway validation.

### P99-12 — Catalog, provider and classifier deltas

- Rerun `scripts/update-model-release-dates.mjs` for Claude Sonnet 5.5,
  GPT-6.1 Sol and new K3 entries; context-window regression for the new models.
- Kimi K3: upstream `maxTokens` grew from 131,072 to 1,048,576 and still uses
  `max_tokens`; `packages/gateway/src/providers/kimi-k3-policy.ts` keeps its
  completion cap. Re-qualify its payload normalization against 0.99.
- The new `typesafe` provider lists no chat models; decide how the provider
  list presents a classifier-only provider.
- Verify `models.json` validation accepts `type`-discriminated entries and that
  CortexKit's provider override still registers under the union
  `ProviderModelConfig`.
- Codemode `models.classify` with the session's `typesafe` credential: cost
  lands in the codemode result (fake-credential capture).

### P99-20 — Jev on Pi classifiers

Owning files: `packages/gateway/src/knowledge/jev-client.ts`,
`packages/gateway/src/knowledge/jev-extension.ts`,
`packages/gateway/src/knowledge/jev-assessment.ts`,
`packages/gateway/src/sessions/session-search-service.ts`,
`packages/gateway/src/integrations/connection-owner.ts` (`knowledge.jev`).

- Replace the fixed-host HTTP client with `ModelRuntime.classify()` on the
  `typesafe` provider, using the Gateway's administrative model runtime for
  Knowledge and session search, and the session runtime for the `jev` tool.
- Credential: the TypeSafe key becomes Pi's `typesafe` provider credential,
  configured through the existing provider settings. Remove the `knowledge.jev`
  connection definition and its Keychain credential path. The live store has no
  `knowledge.jev` instance; if another installation has one, the user re-enters
  the key once (no automatic secret copy).
- Keep Tron-owned policy: request bounds, the per-call `maxChargeCents`
  pre-dispatch ceiling (estimated from the catalog price), assessment
  rubric/profile versions, and the dispatch-certainty contract
  (`notSent`/`sent`/`uncertain`) that session search and assessments depend
  on. Map errors raised before `classify()` is called to `notSent`, and errors
  after it to `uncertain` unless the abort happened before dispatch.
- Model pinning: user chose Pi's catalog `typesafe/jev-latest` on 2026-09-30;
  Tron defines no model in `models.json`. TypeSafe model behavior and actual
  pricing may change without a Tron release. Keep Tron's qualified $0.042/M
  input and zero-output estimate as the only pricing authority for local
  pre-dispatch ceilings and recorded estimated costs; Pi's current catalog cost
  is zero and must not be used for those bounds.
- `jev` tool output changes to Pi's answers (`bool` probability; score without
  legend/probabilities); update its description. Knowledge assessment output and
  recorded usage keep their current shape.
- Evidence: fake-credential Pi wire capture (`noul` on the wire); assessment and
  session-search regressions; P99-22 nested Jev ceiling E2E; iOS provider
  settings continue to expose TypeSafe (UI acceptance remains P99-15).

### P99-13 — `bash` structured output

Tron replaces `bash` with the `DirectBashProcessOwner` definition in
`packages/gateway/src/sessions/direct-bash-process-owner.ts`; it spreads Pi's
definition, so it inherits `outputSchema`. Prove that codemode receives
`{ output, truncated, full_output_path?, exit_code, wall_time_seconds }` through
Tron's `BashOperations`, that process-tree ownership and abort still hold for
nested bash calls, and that empty output (`""` instead of `(no output)`)
renders correctly on iOS.

### P99-13 · Done · 2026-09-30 · luna-worker

- Result: Verified Pi's structured `bash` result reaches codemode through Tron's owned `DirectBashProcessOwner` operations. A codemode call observes output, truncation, full-output path, exit code and wall time for 1,100,000 bytes; subsequent calls verify empty output and exit code 7. A separate codemode abort E2E proves the Gateway stop path kills a detached descendant of nested bash.
- Evidence: Node 22.22.0 TypeScript check passed. Focused RuntimeRegistry E2Es passed 2/2 in 1.49 s (Vitest duration 0.50 s). The retained artifact `packages/gateway/test-results/pi-sdk-099-bash-structured-output.json` captures structured values and parent transcript. The `ToolDetailPresentationTests.commandAndExplicitEmptyOutput` iOS regression already verifies empty bash content stays absent rather than falling back to a placeholder; no iOS production change was needed. Final full Gateway Vitest: 2,315 passed, 2 failed across 214 files in 141.66 s; the resource-sensitive knowledge tagger (18/18, 2.23 s) and session-search-stall (2/2, 5.50 s) failures passed on isolated reruns. Logger rotation also failed under the prior full-suite load run, then passed isolated (16/16, 1.33 s). The separate initial full run exposed a duplicate test fixture mkdir, fixed before the final run. `git diff --check` and `scripts/personal-info-guard.sh` passed.
- Changes: added two faux-provider codemode RuntimeRegistry integration cases in `packages/gateway/src/sessions/runtime-registry.integration.test.ts` and updated this plan's change matrix, task status and handoff. No runtime, protocol, or iOS source changes; no wire changes.
- Tasks added: none.
- Kept on purpose: Pi's bash output schema and its process implementation remain authoritative; Tron only owns exact process-tree abort and delegates execution/result shaping to Pi. Empty output remains an empty value; no `"(no output)"` compatibility text is introduced.
- Deviations: none. The already-existing iOS empty-output presentation regression was inspected instead of duplicated or rewritten.
- For the next agent: the iOS test suite/build remains with P99-16/P99-17. Regenerate the retained JSON by running `node node_modules/vitest/vitest.mjs run src/sessions/runtime-registry.integration.test.ts -t 'structured bash output'` from `packages/gateway`.

### P99-14 — Installed package qualification

With disposable copies and fake credentials: `pi-subagents` (children load the
CLI built-ins and read the same `mcp.json`/`mcp-auth.json`; `--no-extensions`
children lose them; nested codemode calls to `subagent` are allowed by D-3,
so check concurrent child launches against the package's own limits),
`pi-web-access`, `pi-agent-browser-native` (git package: peers are no longer
auto-installed), `pi-goal`, and CortexKit (union model config, TranscriptContext
wire capture). Record per-package evidence; do not mutate the user's
installation.

### P99-15 — iOS settings

Use `.agents/skills/tron-ios/SKILL.md`.

- Replace the MCP surface of
  `packages/ios-app/Sources/UI/Settings/IntegrationsSettingsView.swift` with an
  MCP Servers screen on the P99-8 RPCs: global and trusted-project servers,
  state, tool counts, exposure, errors and stderr tail, add, remove,
  enable/disable, exposure change, sign in, sign out; bearer-token entry per
  D-2.
- Built-in extensions (codemode, tool search, MCP) in
  `ExtensionsSettingsView.swift` with `-builtin:` toggles; `defaultTools` and
  `codemode.mode` controls per D-5.
- Remove `McpToolSource`, `mcpToolCall`, the MCP instruction kind and the MCP
  connection setup form, with their tests (`IntegrationModelsTests`,
  `ExtensionsCatalogPresentationTests`, `SettingsRouteIdentityTests`, smoke UI
  test).

### P99-16 — iOS chat presentation

- Codemode card: script, output, nested calls with status and duration,
  classify cost; live children from P99-5 and reload from `nestedCalls`.
- Generic and MCP tool cards: `server/tool` titles for `mcp__server__tool`,
  argument summary like Pi's default renderer; `tool_search` card listing
  loaded tools; resource tools.
- Tool picker grouped by namespace with exposure.
- Routed model per assistant response and in the session header (D-7).
- Evidence: simulator screenshots of each card live and after reload, retained
  with the test run.

#### Design requirements for P99-15 and P99-16 (user direction, 2026-09-30)

The user asked that the new screens and chat surfaces look and behave like the
rest of the app. Treat these as acceptance criteria:

- Follow `packages/ios-app/docs/architecture.md` (Tron presentation boundary,
  settings typography and accent rules, tool chip and tool detail rules) and
  reuse existing components rather than drawing new ones:
  `TronPresentation.swift` semantic components, `tronGlassSurface`,
  `tronSettingsVisualTheme`, `tronManagedSheet`, `tronNavigationTitle`,
  `tronSettingsCaption`, `tronField`, `TronTypography` (for example
  `secondaryDescription`), `TronSettingsRow`, the shared `sheetSectionHeader`,
  and the static scroll surface for long lists.
- Settings (P99-15): MCP Servers stays in the cyan Tools & Extensions group and
  inherits that accent as its visual theme through nested sheets. Server rows
  follow the placement-based typography rule (reading family for left-aligned
  secondary copy, monospace only for right-aligned values). Settings groups
  use tinted Liquid Glass; long server/tool lists use the static scroll surface.
  Add/edit use the standard managed sheet with Tron fields; MCP sign-in reuses
  the provider OAuth sheet unchanged. Empty, error and loading states use the
  Tron glass-card placeholder typography, not system `ContentUnavailableView`.
  Destructive actions stay semantic red.
- Chat (P99-16): new tool kinds are ordinary tool chips using the existing chip
  and `ToolDetailSheet`/`ToolDetailPresentation` paths, with an SF Symbol and
  label per kind like the built-in tools (codemode, MCP `server/tool`,
  `tool_search`, MCP resources). Nested calls appear only inside the codemode
  chip's detail (and as a compact count/status on the chip), never as separate
  transcript rows. Monospace is for code, tool identifiers and durations only.
  Preserve chip motion, chat identity, scroll continuity and composer behavior.
- Evidence: hosted simulator captures at standard and an accessibility text
  size, light and dark, for each new screen and card, retained in the result
  bundle with paths named in the handoff.
- Tool chips and detail sheets (user direction, 2026-09-30): keep the existing
  progressive-disclosure pattern. The chip shows only what matters at a glance
  (kind icon, human title, one-line key argument or result summary, status,
  duration). The detail sheet foregrounds the readable semantic content first,
  exactly as built-in tools do today, and pushes everything else into the
  existing sub-sheets: the Technical details sub-sheet (execution metadata, then
  Request JSON and Result JSON opening the shared raw JSON sheet) and further
  standardized medium-first sub-sheets. Never dump raw JSON, full scripts or
  long outputs up front.
- Design it generically, not per server. One MCP presentation handles every MCP
  server and tool from data alone: title from `server/tool` (human label or MCP
  title when present), key arguments from the input schema's first required
  string fields, result from text content first, then images, resource links
  and `structuredContent` behind disclosure, and `isError` as the failed state.
  Server-specific or tool-specific branches are not allowed. Codemode is one
  presentation too: the chip shows the nested-call count and aggregate status;
  the detail foregrounds the script's output, then a compact list of nested
  calls (each with the same generic title/status/duration as a top-level chip,
  tappable into that call's own standard detail sub-sheet), attachments from
  `tronNested`, and classify cost; the script source sits behind its own
  sub-sheet. Unknown future tools fall back to the existing extension-tool
  presentation. Bound every preview (line/char limits with explicit omission
  markers) and handle missing, partial (`complete: false`) and failed data
  truthfully.
- Acceptance: hosted tests drive the generic MCP and codemode presentations
  from several differently shaped fixtures (text-only, image, structured-only,
  error, large, nested failure, truncated nested list) rather than one
  hand-picked server.

### P99-17 — Docs, observability, validation

- Docs: the SDK boundary map in `packages/gateway/README.md` (built-ins,
  nested calls, materialization, MCP authority), `packages/gateway/docs/mcp.md`,
  `packages/gateway/docs/connections.md`, `packages/ios-app/docs/architecture.md`
  and `packages/ios-app/docs/events.md`.
- Observability rows in `packages/gateway/docs/observability.md`: MCP startup
  problems (config errors, failed connections, needs-sign-in), MCP stdio
  process count per runtime, codemode script failures and timeouts, sign-in
  relay outcomes. Each row names its test.
- Rollback matrix (`npm run test:pi-sdk-rollback`, baseline 0.87.1): sessions
  written by 0.99 containing `codemode-store` entries, virtual-model state and
  `model_change` to a virtual model, `tool_search` loadout deltas,
  `nestedCalls`, and additive `details.tronNested` parent-result data must open
  under 0.87.1 without data loss; the rollback reader must ignore the unknown
  details key while preserving content and structured content. Extend
  `packages/gateway/test-fixtures/pi-sdk` fixtures accordingly.
- Full Gateway, Mac and iOS validation once; HTML export artifact compared with
  0.87.1 output; payload verifier; personal-info guard; documentation policy.
- Independent review of the candidate diff before P99-18.

### P99-18 — Integration and acceptance

Merge only with the user's approval. Manual gates, performed or reported by the
user: install the signed build (Gateway adoption is a user action); add an
OAuth MCP server and sign in from the iPhone; run a codemode-exposed MCP tool
from a session; Sign in with ChatGPT; select a virtual model if one is
installed. Then close the plan per `docs/plans/README.md`.

## Handoff log

### P99-14 · Done · 2026-09-30 · luna-worker

- Result: Qualified disposable package copies through Pi 0.99.1 `DefaultResourceLoader`; the original CortexKit install was copied read-only into a temporary directory. No user installation, credentials, Gateway state or tracked runtime dependency was changed. The five extension loads all register without `LoadExtensionsResult.errors` or warnings once their host/runtime dependencies are present.
- Evidence: npm packs in `/tmp/pi-sdk-099-qualification`: `pi-subagents@0.59.0` (2 tools, 17 commands, 12 handlers), `pi-web-access@0.22.0` (4 tools, 4 commands, 3 handlers), `@mocito/pi-goal@0.1.11` (3 tools, 1 command, 11 handlers), the Git `pi-agent-browser-native@0.8.2` package (8 tools, 7 handlers), and copied `@cortexkit/pi-anthropic-auth@1.23.1-tron.9` (9 commands, 2 handlers; Anthropic provider registration). Final isolated loader run: 5/5 package registrations, 0 errors, 0 warnings; the Git package install emits `EBADENGINE` because its declared Node engine is `>=24.21.0` while the candidate uses 22.22.0. A two-branch built-in loader check confirmed the normal `pi --mode json -p` launch includes Pi codemode/tool-search/MCP while `--no-extensions` removes all three. Subagent source confirms optional explicit extension lists trigger `--no-extensions`, and children inherit agent-dir environment; explicit MCP direct selections use a bounded `--mcp-config` while retaining agent-dir MCP auth. Parallel fanout defaults to 4; `maxActiveAsyncRunsPerSession` is configurable but unset means no active-run limit. CortexKit fake-key wire capture verified provider registration and the normalized system instruction and tool declaration were sent: CortexKit keeps its Claude Code bootstrap in Anthropic `system`, carries Pi's custom system instruction in the first user message, and transmits the tool schema. No real API request occurred; fetch was intercepted. The npm install warning and package engine were observed during the isolated install. Commands: `npm pack` (three registry packages plus Git package) and temporary dependency install, package/builtin loader harnesses, CortexKit wire harness; no repository test was added because this qualification depends on network-fetched tarballs and the user's local tarball. Final candidate validation: `npm run check:pi-sdk` passed; TypeScript check passed; full Gateway Vitest 2,312/2,317 passed in 116.96 s, with five load-sensitive failures (intake-enrichment ENOTEMPTY, logger rotation timeout, recent-model-usage ordering, session-search-stall performance threshold, and parallel runtime-registry fixture mkdir EEXIST); all five owning files passed individually, a combined 276 tests in 69.59 s. Documentation policy, personal-info guard, and `git diff --check` passed.
- Changes: this plan's P99-14 row, change-matrix dispositions and handoff only.
- Tasks added: P99-24 for the browser package's unsupported Node engine declaration.
- Kept on purpose: no reusable repo test; no package pin, runtime shim, or change to the user's installation. Package-specific config/auth semantics stay Pi-owned.
- Deviations: `pi-agent-browser-native@0.8.2` registered successfully but is not qualified for supported runtime operation under Tron Node 22.22.0; this remains open as P99-24. CortexKit's persisted installed version is a local tarball, so its copied installed package was loaded rather than repacked from npm. The wire evidence captures system instructions in both the provider-specific bootstrap and Pi's user-message transcript representation, rather than assuming the custom instruction occupies Anthropic's top-level `system` field.
- For the next agent: resolve P99-24 without changing the installed user package; P99-17 should retain the engine incompatibility as an open dependency qualification until an explicitly supported browser package/host runtime is established.

### P99-14 correction · Partial · 2026-09-30 · luna-worker

- Correction: the prior qualification loaded upstream `pi-agent-browser-native@0.8.2`; it did not load the user's installed fork. Treat its browser registration/engine conclusions as inapplicable to the installed version. Other P99-14 package results remain unchanged.
- Evidence: the read-only copy `/tmp/tron-p99-browser-fork/installed-fork` identifies version `0.4.1`, installed HEAD `1b5f11bb251843f5b7536eea9eea7b17f96ac970`, and Node `>=22.19.0`; user settings pin Git source to `d6cde09af8d7757bbfba5a4ffaf83381bb392683`. Browser registration under Pi 0.99.1 and fake-executable operation are not claimed here. The package-upgrade follow-up records the Node 24.21 runtime requirement, native engine change 0.33.2 → 0.38.1, Tron-only browser binding and pin drift.
- Changes: correction and matrix update only; user installation/settings remain untouched.
- Tasks added: P99-24 rewritten as package-upgrade follow-up; proposed node-runtime lifecycle plan may take over the runtime requirement.
- Kept on purpose: no user package upgrade or settings rewrite without an explicit supported package/runtime decision.
- Deviations: direct and nested trusted-browser E2E remains outstanding under P99-17.
- For the next agent: ensure P99-24 accounts for `agent_browser_code` trust in `browser-live-view-adapter.ts`, overlap with codemode/tool-search and that reinstalling the current settings pin drops the Tron-only browser-binding commit.

### Checkpoint · Paused · 2026-09-30 · orchestrator session

- Result: The user asked to pause after P99-20. Done on the candidate: P99-1 to P99-7, P99-9 to P99-13, P99-20, P99-22, P99-23 (37 commits on `feat/pi-sdk-099-upgrade`). P99-8 is partial: MCP admin RPCs (`mcp.list/add/remove/logout/update`, `mcp.token.set`) and the argv-free Keychain writer (`/usr/bin/security -i`) are committed; the session-bound MCP OAuth sign-in relay and its PKCE/dynamic-registration/refresh E2E are not. P99-8 and P99-14 claims are released to Ready; P99-14 was never started.
- Evidence: checkpoint on the candidate HEAD under Node 22.22.0: `tsc --noEmit` clean; `check:pi-sdk` coherent at 0.99.1; full Gateway Vitest 2,308/2,311 (214 files, 111 s wall), the three failures (intake enrichment, session-search stall, logger rotation) are the known load-sensitive tests and passed 21/21 when rerun together in isolation. No iOS build or test has run on this branch yet.
- Decisions recorded during the run: D-8 parent-result enrichment for nested display/browser data (orchestrator, within plan ownership rules); user confirmed the global-helper dark palette (P99-11); user chose `jev-latest` for Jev with Tron's own price for the ceiling (D-6 addendum). Supervisor rules given to workers for P99-8: MCP sign-in via `mcp.auth.start/cancel` reusing AuthBroker operations with a `{kind:"mcp", sessionId, server}` target, openUrl fail-closed without a Tron-started operation, pasted-redirect prompt routed to the same operation, cancellation on session teardown.
- Open questions for the user before P99-18: Jev paid-tagging consent. Removing the `knowledge.jev` connection removed its explicit `paidAccessApproved` switch and configurable monthly budget; P99-20 now treats a configured TypeSafe provider credential as consent and keeps a fixed 500-cent monthly cap. Confirm or ask for a separate opt-in and configurable cap.
- Evidence gaps carried to P99-17: trusted agent-browser receipt success for nested calls (P99-23); virtual-model resume/fork/retry/compaction lifecycle E2E (P99-10); codemode `models.classify` cost capture (P99-12); Mac payload staging and verification (P99-2).
- Remaining when resumed: finish P99-8 (OAuth relay + E2E + relay observability), P99-14, P99-15, P99-16, P99-17, P99-18.
- Process notes: workers run as `luna-worker` with fresh context, 3-hour child timeout, one task per child, sequentially on the single candidate worktree. Supervisor questions arrive while the orchestrator waits; answer them promptly or they time out.

### P99-2 · Done · 2026-09-29 · luna-worker

- Result: Pinned SDK 0.99.1 with the repository updater; checker now admits both new family packages at their nested shrinkwrap paths; rollback baseline is 0.87.1.
- Evidence: `npm run update:pi-sdk -- 0.99.1` verified all ten packages share gitHead `d86654abb8862e201933517d6f1fce9f88dd117f`, version 0.99.1 and Node `>=22.19.0`; `check:pi-sdk` passed (8 resolved entries, installed tree checked); `test:pi-sdk-scripts` passed 23/23 in 6.48 s; `npm audit signatures` passed (364 packages, 96 attestations); npm reported 3 audit vulnerabilities (2 moderate, 1 high). tsc has five API errors assigned to P99-3 (no fixes made): missing `mcp_servers_change`/`provider_stream_event`; six ExtensionAPI members; six ToolDefinition fields; `ExtensionContext` vs `ExtensionToolContext`; and string vs boolean at runtime-slot.ts:6798. `compare-pi-sdk-graph.mjs 9b52706db 35353e38d` returned `changed:true`. This compared the package graph in the P99-2 commit; this documentation-only amendment leaves those package files unchanged.
- Changes: `package.json`, `package-lock.json`, `pi-sdk-baseline.json`, `packages/gateway/scripts/check-pi-sdk.mjs`, `packages/gateway/scripts/check-pi-sdk.test.mjs`, and this plan.
- Tasks added: none.
- Kept on purpose: `pi-client` and `pi-protocol` remain in the checker cohort because 0.99.1 still publishes them, though they are no longer in the resolved lock graph.
- Deviations: payload staging skipped. Read `bundle-gateway.sh`: even `--skip-install` requires a prebuilt `dist/index.js` (absent); normal operation performs `npm ci` and `npm run build` and publishes into Mac app Resources. This violates the task's instruction not to install or activate via that script. `quickjs.wasm`, codemode worker and pi-mcp payload inclusion remain unverified.
- For the next agent: P99-3 resolved the five tsc errors. Run the bundle/payload verification only at an approved later stage and only under the repo's build safety policy; this task made no deployment or Gateway lifecycle calls.

### P99-1 · Done · 2026-09-29 · orchestrator session

- Result: npm `latest` is still 0.99.1 (`gitHead` d86654abb8862e201933517d6f1fce9f88dd117f, Node `>=22.19.0`). Plan activated and P99-1 claimed on `main`; candidate branch `feat/pi-sdk-099-upgrade` created in the sibling worktree `tron-pi-sdk-099` beside the main checkout, from the claim commit.
- Evidence: independent `npm ci` under Node 22.22.0 (nvm) in the candidate; `check:pi-sdk` coherent at 0.87.1; `tsc --noEmit` clean.
- Changes: plan metadata only.
- Deviations: Implementation is delegated to `luna-worker` subagents, one task per child, sequential on the single candidate worktree because most tasks share `runtime-slot.ts` and the protocol. Claims are committed on `main` per phase and cherry-picked onto the candidate so the plan copies stay aligned.
- For the next agent: use Node 22.22.0 from nvm for Vitest; the app-bundled Node cannot load Rolldown's native binding and `npx`/`timeout` are not on the default PATH.

### P99-3 · Done · 2026-09-29 · luna-worker

- Result: Completed P99-3. The manifest now classifies both added events, six extension API members, and six tool fields; subagent stop uses `createToolContext`; handled prompt dispositions settle through the no-agent path; thrown SDK rejections resolve prompt admission as rejected; queue rebuild removes and terminalizes handled items as completed; `prepareLoadout` runs inside extension owner attribution; `deviceId` is omitted from settings document projections.
- Evidence: Node 22.22.0 `tsc --noEmit` passed. Focused Vitest: 8 passed in 8.26s across owner attribution, settings projection and runtime registry. Full Gateway Vitest: 2,299 passed, 3 failed, 120.24s. Expected P99-4 failure: `rekeys the owning slot when a completed session is forked` now sees a persisted session file after the first user entry. Two unrelated resource-sensitive failures (knowledge tagger job settlement and logger rotation timeout) each passed their focused rerun (1/1, 0.55s and 1.42s). Focused queue-rebuild test passed 1/1 in 4.04s. `git diff --check` passed.
- Changes: `packages/gateway/src/extensions/compatibility-manifest.ts`, `packages/gateway/src/sessions/runtime-slot.ts`, `packages/gateway/src/extensions/owner-attribution.ts`, `packages/gateway/src/admin/settings-service.ts`, runtime-registry integration, owner-attribution and settings-service tests; this plan row, handoff and matrix.
- Tasks added: none.
- Kept on purpose: handled invocations use existing completed lifecycle and receipt format; no new public lifecycle schema was needed. Pi's return disposition is handled at the Gateway-owned queue boundary, with Pi's actual queue remaining authoritative for survivors.
- Deviations: Full suite had two unrelated failures under parallel load; both pass individually. The planned P99-4 persistence assertion remains untouched and is the third full-suite failure.
- For the next agent: P99-4 owns the expected fork-materialization behavior change and its test/doc updates. Consider rerunning the full suite at the final checkpoint; focused P99-3 coverage and type checking are green.

### P99-4 · Done · 2026-09-29 · luna-worker

- Result: Pi 0.99 materializes a new session at the first user or assistant message. Updated fork semantics, catalog parent identity, automation ownership wording, canonical receipt durability, notification and context-window wording. Added an integration case that appends the first prompt, tears down the owning RuntimeRegistry, reopens a new registry from disk, and verifies the canonical first invocation receipt and user message.
- Evidence: Node 22.22.0 TypeScript check passed. Focused fork and receipt integration tests: 2 passed in 6.36s; full `runtime-registry.integration.test.ts`: 246 passed in 57.93s. Full Gateway Vitest default-worker attempts: 2,301 passed with unrelated resource-sensitive failures in 143.97s, then 2,299 passed/4 unrelated timing or stress failures in 198.20s. Retried with `--maxWorkers=4`: 2,302 passed/1 unrelated request-span performance-threshold failure in 278.71s. Individual reruns passed: knowledge curation 1/1 in 1.42s and session-search stall 2/2 in 5.66s. The complete runtime-registry integration file passed 246/246 in 57.93s before the final lexical path-normalization refinement; both P99-4 cases passed afterward (2/2 in 6.36s).
- Changes: `packages/gateway/src/sessions/runtime-registry.integration.test.ts`, `runtime-registry.ts`, `runtime-slot.ts`, `providers/context-window-policy.ts`, `packages/gateway/README.md`; this plan row, handoff and change matrix.
- Tasks added: none.
- Kept on purpose: setup-only and pre-first-message failure receipts remain memory-only; Tron does not write Pi JSONL directly or create a second receipt journal. Automation ownership remains live-only until the first persisted message.
- Deviations: Full Gateway validation remains short of green after three suite attempts, each with unrelated timing/performance/resource-sensitive failures; changed-area TypeScript and integration validations pass. Fork catalog parent lookup needed lexical normalization of macOS `/var` and `/private/var` path aliases to keep persisted header paths authoritative without synchronous per-session filesystem reads.
- For the next agent: full Gateway suite should be repeated at the final cross-module checkpoint under lower host load. P99-4-specific test coverage is green; no user decision remains.

### P99-5 · Done · 2026-09-29 · luna-worker

- Result: Nested calls stay children of their model-issued parent in the live runtime and canonical transcript. Live child arguments are capped at 1 KiB and the list at 32; overflow is represented by byte count and/or `complete: false`. Canonical child summaries use the same bounds and Pi's completeness bit. Non-throwing `isError` children are failed, opaque `structuredContent` is omitted from generic live result frames, and iOS models decode optional live and canonical nested-call payloads. Pi's own session stats include usage from tool results.
- Evidence: Node 22.22.0 TypeScript check passed after the final dependency cleanup; `check:pi-sdk` reports coherent 0.99.1. Focused faux-provider codemode E2E plus projection test: 2/2 passed in 1.57 s; E2E retains `packages/gateway/test-results/pi-sdk-099-nested-calls.json`, showing one live codemode row with three children and the same canonical children after a cold runtime reload. The E2E verifies `read`, `bash`, a non-throwing failing nested tool, a direct non-throwing failing tool, and tool-result cost of $0.125. Final full Gateway Vitest: 2,302 passed, 3 failed in 110 s; focused reruns all passed: knowledge tagger 18/18 in 3 s, recent-model-usage 3/3 in 1 s, and session-search stall 2/2 in 5 s. `git diff --check` passed.
- Changes: `packages/gateway/src/protocol/types.ts`, `sessions/runtime-slot.ts`, `sessions/projection.ts`, projection and runtime-registry integration tests, Gateway README; iOS `SessionRuntimeModels.swift`, `TranscriptModels.swift`, `ToolExecutionStatePolicy.swift`; this plan's matrix, task row and handoff. No additional Pi family dependency is declared; the fixture imports `createCodemodeExtension` from the pinned `pi-coding-agent` root export.
- Tasks added: none.
- Kept on purpose: Pi's canonical `nestedCalls` is authoritative; no child JSONL/tool result, invocation receipt, segment, or extension-activity row is synthesized. The `complete` bit reports Pi or projection truncation. The structured payload remains out of the generic mobile contract. Pi's `getSessionStats()` already adds tool-result usage, confirmed from the pinned source and the faux-provider regression; Tron does not double-count it.
- Deviations: The fake codemode factory is registered only through the test fixture's project extension; production runtime/admin composition remains P99-6. One full-suite logger rotation timeout passed the required focused rerun. No iOS build/test was run; iOS received optional Codable model fields for P99-16 without view behavior.
- For the next agent: move `pi-codemode` from devDependency to runtime dependency when P99-6 composes the first-party factory. Nested IDs are not canonical independent results: the current workspace `tool_call` hook still applies handoff, but confirm how nested `subagent` stop routing gets the parent call ID. Browser/display receipts currently authorize exact canonical tool IDs, not nested result IDs; P99-6 must keep artifacts attached to the parent codemode card rather than creating orphan rows. Test all-tool nested concurrency and UI/desktop ownership at that phase. P99-16 should decode the new optional child fields and render children under the parent; no RPC or work-kind change was made here.

### P99-6 · Blocked · 2026-09-29 · luna-worker

- Result: Composed Pi's replaceable codemode, tool-search and MCP built-ins in live runtimes and session-free hooks/package discovery. The Gateway agent directory owns MCP logs; Pi's default OAuth credential store resolves through the Gateway-pinned agent-dir environment. MCP authorization URLs fail closed until P99-8 relay support. Tool exposure/namespace/annotations are projected and hidden tools are rejected by `setTools`. `defaultTools` (including `+`/`-` entries) and `codemode.mode`/`inlineBudget` now project and validate through settings. Synchronous nested subagent activity is associated with its codemode parent's running operation so its foreground stop route can find the owner.
- Evidence: Node 22.22.0 `tsc --noEmit` and `check:pi-sdk` passed. Focused changed-area runs passed 9 tests across four files (including session-free/live hook parity, settings, hook projection, and P99-5 codemode E2E). Isolated resource-sensitive reruns: knowledge tagger 18/18 in 2.23 s; logger rotation 16/16 in 1.31 s; intake enrichment 3/3 in 3.82 s. Final full Gateway run: 2,304 passed, 1 failed (130.37 s); `knowledge-intake-enrichment` failed with transient `ENOTEMPTY` cleanup under host load, then passed individually. `check:pi-sdk` reports coherent 0.99.1; `git diff --check` passed.
- Changes: `packages/gateway/src/extensions/pi-builtins.ts`, `sessions/runtime-slot.ts`, `admin/session-free-extensions.ts`, `admin/settings-service.ts` and tests, `sessions/hook-projection.ts` and tests, `admin/hook-resources.ts` and tests/integration test, `packages/gateway/docs/mcp.md`. No additional Pi-family dependency is declared. The P99-5 pointer to move `pi-codemode` to a direct runtime dependency is superseded: the pinned `pi-coding-agent` package bundles codemode and root-exports its factory; no extra family package is needed.
- Tasks added: P99-22 owns the missing broad codemode/MCP E2E qualification.
- Kept on purpose: the legacy ConnectionOwner MCP adapter and `@modelcontextprotocol/sdk` remain unchanged for P99-7; users must not configure the same server through both surfaces. Pi's built-in `loadConfig` is used rather than duplicating its server schema; the Gateway agent-dir environment and TrustService-owned `resolveProjectTrust` callbacks bind it to the approved authority. Project config remains unread unless that callback accepts trust.
- Deviations: P99-6 is Blocked because the required acceptance E2Es were not implemented or verified: stdio and streamable-HTTP MCP fixtures, codemode/direct/deferred exposures, resources and `list_changed`, crash/lazy reconnect and process-group cleanup, plus concurrent nested `ask_user`, `notify`, desktop input/capture, `display`/browser receipt attachment, `schedule` receipts, Jev charge ceiling and nested foreground subagent stop routing. The default Pi tool composition is present, but broad all-tool codemode reach must not be considered qualified until these behavioral boundaries pass. No MCP fixture process or Gateway lifecycle action was started. No iOS UI work was done; P99-15/P99-16 own it.
- For the next agent: complete P99-22 and verify nested child actions/receipts remain attached to the codemode parent card; test runtime Stop/drain aborts the worker. Keep the MCP admin surface/adapter removal to P99-7/P99-8. No `pi-codemode` direct dependency is needed. The full-suite failure reproduced as a focused-pass `ENOTEMPTY` timing/cleanup issue, not a functional assertion.

### P99-6 · Done · 2026-09-30 · luna-worker

- Result: P99-6 codemode reach qualification is complete using the retained P99-22 E2Es and P99-23 parent-only presentation persistence E2E. The new part 2c regression exercises Jev dispatch ceilings during actual concurrent nested HTTP requests, and a foreground subagent started through codemode receives the workspace handoff and is stopped via the Gateway's operation-fenced subagent stop path. Nested subagent process activity is now projected against its codemode parent operation without creating an independent receipt.
- Evidence: TypeScript check passed. The three focused cases across `codemode-nested-delegation.integration.test.ts` and `jev-extension.test.ts` passed in 1.39 s. Full Gateway Vitest passed 2,309/2,311 tests in 112.94 s; logger rotation (1/1 in 1.10 s) and session-catalog interval repair (1/1 in 0.46 s) failures passed isolated reruns. The integration test retains `packages/gateway/test-results/pi-sdk-099-nested-delegation.json` (gitignored). `git diff --check` and the personal-info guard passed.
- Changes: `packages/gateway/src/knowledge/jev-extension.ts`, `packages/gateway/src/sessions/runtime-slot.ts`, `packages/gateway/src/sessions/codemode-nested-delegation.integration.test.ts`, and this plan. Jev calls are parallel-safe because each invocation is stateless and independently enforces the estimated per-call ceiling before fake HTTP dispatch; nested foreground activity is transient and creates no child receipt.
- Tasks added: none.
- Kept on purpose: Jev remains on its current fakeable HTTP client until P99-20 replaces it with Pi classifiers. Stop routing remains fenced to the codemode parent's operation; test owner and child-session binding are fake extension boundaries, not claims about installing/running pi-subagents.
- Deviations: the full Gateway run had two timing/resource-sensitive failures, including logger rotation's 15-second timeout; both failed cases passed isolated reruns. No MCP admin/adapter or iOS work was added; P99-7/P99-8 and P99-15/P99-16 retain those owners. No Gateway lifecycle or external network action was invoked.
- For the next agent: P99-17 retains final validation, rollback/payload qualification, and the trusted-browser receipt/abort-stash follow-up identified by P99-23. P99-6's codemode reach qualification is unblocked; MCP adapter/admin migration remains P99-7/P99-8.

### P99-23 · Done · 2026-09-30 · luna-worker

- Result: The existing Tron display extension now observes Pi `tool_result` events, collects admitted nested display descriptors by parent call ID, reseals valid trusted browser receipts for the canonical parent ID, and enriches only the parent result's `details` with `tronNested`. The stash is bounded to 32 descriptors per parent and 16 KiB total, reports `complete: false` on overflow, and clears on parent completion, agent end/abort and runtime shutdown. Canonical display artifact reconciliation retains artifact IDs nested under the parent result; cold projection verifies browser receipts against the parent canonical ID. No content, structuredContent, child result, child receipt or transcript row is synthesized.
- Evidence: Node 22.22.0 `tsc -p tsconfig.json --noEmit` passed; `npm run check:pi-sdk` passed (8 resolved entries). Focused RuntimeRegistry faux-provider E2E passed 1/1 (Vitest 0.46 s, command wall 1.23 s) with a retained `packages/gateway/test-results/pi-sdk-099-nested-presentation.json`; it verifies one canonical parent only and the same bounded nested artifact descriptor live and after cold reload. Supporting display/native-capture/hook-registration tests passed 17/17 across 6 files. Final full Gateway Vitest: 2,308 passed/2 failed across 211/213 files in 109.24 s; logger rotation (16/16, 1.39 s) and session-search-stall (2/2, 5.13 s) passed required focused reruns. `git diff --check` and personal-info guard passed.
- Changes: `packages/gateway/src/display/nested-presentation-extension.ts`, `display/display-contract.ts`, `display/tron-display-extension.ts`, `display/tron-display-extension.test.ts`, `display/tron-native-capture-extension.test.ts`, `sessions/runtime-slot.ts`, `sessions/codemode-nested-presentation.integration.test.ts`; Gateway README; this task row, D-8 decision, rollback note, matrix and handoff.
- Tasks added: none.
- Kept on purpose: receipt validation remains strict and does not trust tool name or project-provided descriptors; Pi owns canonical parent JSONL and its content/structuredContent. Artifact payload bytes remain in the artifact store, not parent details.
- Deviations: The faux-provider test's project browser fixture is not a trusted `pi-agent-browser-native` owner and cannot produce a valid Gateway-sealed receipt; it verifies fail-closed behavior rather than claiming trusted browser receipt end-to-end coverage. Production parent resealing and canonical receipt admission are implemented at their owning boundaries but trusted-browser receipt success and explicit aborted-stash negative assertions remain unverified. The accepted D-8 seam adds no child rows or independent receipts. No Gateway lifecycle or real browser/network operation was invoked.
- For the next agent: P99-17 should add/retain a trusted-owner browser fixture if a safe test seam is available, verify parent receipt admission via `admitBrowserToolReference`, and assert aborted/teardown paths cannot enrich a subsequent parent result. The P99-17 rollback matrix must prove 0.87.1 ignores `details.tronNested`.

### P99-22 · Claimed · 2026-09-29 · luna-worker

- Result: Completed the MCP-fixture and codemode-lifecycle half of P99-22. P99-22 remains Claimed for its first-party tool concurrency/receipt qualification.
- Evidence: Node 22.22.0 TypeScript check passed; `npm run check:pi-sdk` reports coherent 0.99.1. Three focused RuntimeRegistry E2Es passed (3/3; Vitest 3.99 s, command wall 12.53 s): stdio and Streamable HTTP MCP with direct/codemode/deferred exposure, resource list/read, `tools/list_changed` addition and withdrawal, crash/lazy reconnect, session-shutdown process-group cleanup; untrusted/trusted project `mcp.json` plus process-group termination on capacity eviction; Stop against a sleeping QuickJS script and nested-tool loop plus drain waiting for active codemode. Repeatable artifacts: `packages/gateway/test-results/pi-sdk-099-mcp-fixtures.json`, `pi-sdk-099-mcp-project-trust.json`, and `pi-sdk-099-codemode-stop-drain.json` (gitignored). Final full Gateway run: 2304/2308 tests passed (207/211 files; 203.91 s wall); resource-sensitive knowledge curation, observation, Jev tagging and logger failures passed on focused reruns (tagger 18/18, logger 16/16). `git diff --check` passed.
- Changes: `packages/gateway/test-fixtures/pi-sdk/mcp-jsonrpc-fixture.mjs`, the three focused RuntimeRegistry integration cases in `packages/gateway/src/sessions/runtime-registry.integration.test.ts`, this matrix disposition and handoff. No runtime behavior or dependencies changed.
- Tasks added: none.
- Kept on purpose: hand-written JSON-RPC fixtures exercise the actual pinned stdio and Streamable HTTP transports without making `pi-mcp` a direct dependency. Fixture child processes are checked by PID both at session shutdown and capacity eviction; the MCP server process is group-killed for crash simulation to avoid leaving its own descendant behind.
- Deviations: The full-suite run had four unrelated timing/resource-sensitive failures; their focused reruns passed, although `knowledge-tagger` needed its own isolated run after failing in a multi-file run. No iOS work or Gateway lifecycle actions were performed. The test process table after completion contained no fixture server or child; an unrelated long-lived node helper observed during earlier work was left untouched.
- For the next agent: finish P99-22 part 2 before unblocking P99-6: concurrently exercise first-party nested `ask_user`, `notify` quotas, desktop input/capture serialization, `display`/browser receipt attachment, `schedule` receipts, Jev spend ceiling, and nested foreground-subagent stop/workspace handoff. Keep broad codemode reach unqualified until those boundaries pass. P99-7/P99-8 still own removal of the adapter and MCP administration/sign-in relay.

### P99-22 part 2a · Claimed · 2026-09-29 · luna-worker

- Result: Qualified nested interactive ask_user, notify and schedule behavior in a faux-provider RuntimeRegistry E2E. Two concurrent forms expose only one live semantic interaction at a time and both settle; Stop while a form is pending clears it without an orphan interaction. Nested notify uses the durable NotificationService admission: one notification queues under the session quota, the next is truthfully rate-limited, and the persisted inbox row is attributed to the owning session. Nested schedule creation uses GatewayScheduleToolOperations and the real durable CommandReceiptStore; replaying the exact nested tool-call ID returns its saved result without a second mutation.
- Evidence: Node 22.22.0 TypeScript check and `check:pi-sdk` passed. Focused integration test passed 1/1 in Vitest 0.44 s (command wall approximately 1.4 s). It retains `packages/gateway/test-results/pi-sdk-099-nested-interactive.json` with form bounds/cleanup, durable notification admission/session evidence and schedule source IDs. The case includes actual RuntimeRegistry/RuntimeSlot, Pi codemode, faux provider, NotificationGrantStore/NotificationService, GatewayScheduleToolOperations and CommandReceiptStore; desktop/push boundaries use a local fake relay. Full Gateway suite: 2,307 passed, 2 failed in 111.81 s; logger rotation and session-search stall timing-sensitive failures passed isolated reruns (1/1 in 1.23 s and 1/1 in 3.37 s). Personal-info guard and `git diff --check` passed.
- Changes: added `packages/gateway/src/sessions/codemode-nested-interactive.integration.test.ts`; updated this matrix and handoff. No runtime or protocol changes.
- Tasks added: none.
- Kept on purpose: the P99-22 row remains Claimed. P99-22 part 2a proves only ask_user, notify and schedule. Notification limits and receipts remain owned by NotificationService; schedule command IDs/receipts remain owned by GatewayScheduleToolOperations/CommandReceiptStore. The test uses actual persistent stores in temporary test directories.
- Deviations: The full Gateway suite had two unrelated timing-sensitive failures under suite load; each passed its isolated rerun. No behavior or scope deviations.
- For the next agent: P99-22 part 2b still owns desktop input/capture serialization, display/browser receipt attachment, Jev spend ceiling, and nested subagent handoff/foreground stop routing. Do not unblock P99-6 on this partial qualification.

### P99-22 part 2b · Claimed · 2026-09-30 · luna-worker

- Result: Added a faux-provider RuntimeRegistry E2E for concurrent nested computer and presentation tools. The Gateway projects every nested action under the single codemode parent live and after reopen; concurrent computer requests do not overlap, and the fake native client binds a selected view to the canonical session. The run also exposed that nested display/browser calls are summarized by Pi without their result presentation payloads, so their attachment/authorization is not qualified.
- Evidence: Node 22.22.0 TypeScript check passed. Focused E2E passed 1/1 in Vitest 0.46 s (command wall 2.61 s). It retains `packages/gateway/test-results/pi-sdk-099-nested-presentation.json` (gitignored), including the live/cold-reload snapshots and fake native session binding. The full Gateway suite passed 2,310/2,310 tests across 213 files in 117.79 s. The test intentionally does not claim display-artifact or browser-receipt attachment; Pi's parent result has only `{id,name,args,status,durationMs,error}` child summaries.
- Changes: added `packages/gateway/src/sessions/codemode-nested-presentation.integration.test.ts`; this matrix, P99-22 handoff and P99-23 task row. No production source changes.
- Tasks added: P99-23 to scope bounded nested presentation data under the parent result/projection without child rows or receipts.
- Kept on purpose: P99-22 remains Claimed. P99-22 part 2b proves desktop serialization and native session binding only; `display` artifact and browser receipt live/cold-reload attachment are not considered proven. No nested call becomes an independent canonical card.
- Deviations: The approved plan does not specify how presentation receipts absent from Pi's persisted nested summaries become durable under the parent. I requested a decision through the coordination channel twice; both requests timed out without a reply. I did not invent a new persistence or protocol contract. The test uses a fake Cua client boundary and fake NativeLiveClient; it makes no host automation or network calls.
- For the next agent: P99-23 must resolve the parent-only persistence seam and add its own E2E before P99-6 is unblocked. Do not claim display/browser receipt success from this test; do not add child rows or re-key a receipt to a nested child ID without an approved contract.

### P99-22 part 2c · Done · 2026-09-30 · luna-worker

- Result: Added a faux-provider RuntimeRegistry integration E2E for nested Jev and foreground subagent delegation. Four concurrent Jev calls execute through the real Tron tool; two exceed `maxChargeCents` and never reach fake HTTP, while two admitted calls overlap at HTTP. The nested subagent receives the Gateway workspace handoff from the `tool_call` hook. Its live process is attached to the codemode parent's operation and aborts through `RuntimeSlot.abortSubagentProcess`; no child canonical tool result or extension-activity receipt is created.
- Evidence: Node 22.22.0 TypeScript check passed. Focused test command passed 3/3 across the new integration test and Jev extension test in 1.39 s; the integration test retains `packages/gateway/test-results/pi-sdk-099-nested-delegation.json` (gitignored). Final full Gateway run passed 2,309/2,311 tests in 112.94 s; session-catalog interval repair passed its isolated rerun (1/1, 0.46 s) and logger rotation passed its isolated rerun (1/1, 1.10 s). `git diff --check` and personal-info guard passed.
- Changes: added `packages/gateway/src/sessions/codemode-nested-delegation.integration.test.ts`; changed `packages/gateway/src/knowledge/jev-extension.ts` to allow stateless per-call Jev parallelism under D-3; changed `packages/gateway/src/sessions/runtime-slot.ts` to observe nested extension process lifecycle and preserve foreground operation ownership without writing child receipts.
- Tasks added: none.
- Kept on purpose: all Jev calls retain their independent fixed-price pre-dispatch ceiling; the fixture uses fake HTTP and a fake subagent extension, with owner and child-session binding faked at the boundary. The test performs no external network or real child-process work.
- Deviations: the full Gateway suite had two timing/resource-sensitive failures; both passed isolated reruns. The production nested-activity fix was needed because nested event handling previously only projected live nested-call summaries and never admitted process ownership for foreground subagents.
- For the next agent: P99-17 retains final validation, rollback/payload qualification, and the trusted-browser receipt/abort-stash follow-up identified by P99-23. P99-6's codemode reach qualification is unblocked; MCP adapter/admin migration remains P99-7/P99-8.

### P99-7 · Done · 2026-09-30 · luna-worker

- Result: Removed Tron's standalone MCP adapter and its SDK dependency, all ConnectionOwner MCP transport/configuration/runtime-binding generality, MCP module-source and work-kind wire projections, adapter runtime wiring, and MCP instruction attribution. Pi's built-in MCP and `mcp.json` are the sole MCP client/configuration boundary.
- Evidence: Node 22.22.0 TypeScript check passed; `npm run check:pi-sdk` passed (8 resolved Pi entries). Focused integration validation passed 284/284 tests across 5 files in 63.92 s. Full Gateway Vitest passed 2,297/2,300 tests across 213 files in 141.22 s; the three unrelated failures (recent-model-usage ordering, session-search-stall timing threshold, and the P99-4 fork parent projection) all passed focused reruns, 3/3 in 7.92 s. `git diff --check` and `scripts/personal-info-guard.sh` passed.
- Changes: removed `mcp-adapter.ts` in `packages/gateway/src/integrations/` and its test; removed the direct `@modelcontextprotocol/sdk` dependency through npm uninstall (the package remains an optional peer in upstream Pi lock metadata); removed MCP types/methods, `modules.list.connections`, `mcp-tool-call`, and `tron-mcp-*` runtime wiring; removed the MCP instruction source; revised connections tool description and MCP/connections docs; removed legacy MCP RPC tests and updated work-kind/module tests. Persisted `implementation: "mcp"` or transport configuration now fails state validation with an instance-naming error directing the operator to Pi `mcp.json`. Updated this plan row, change matrix, and handoff.
- Tasks added: none.
- Kept on purpose: Pi's built-in `mcp`, `codemode`, and `tool-search`; Pi's `mcp.json` and OAuth credential authority; the MCP RPC/sign-in relay remains P99-8. No compatibility migration is kept because the inspected live connection store has no MCP instance.
- Deviations: The loader rejects old MCP instance state rather than migrating it, per the plan's no-compatibility rule. `npm uninstall` keeps the SDK package entry in the lockfile only as an optional peer of Pi, not as a Tron-declared dependency. Full Gateway validation had three unrelated failures; each passed its individual rerun.
- For the next agent: P99-15 must remove the old iOS MCP connection/source surface and account for these wire removals: `modules.list.connections`, the `mcp-tool-call` work kind, and the MCP instruction source; retain Pi built-in MCP extension settings and MCP tool presentation. P99-8 still owns the Gateway MCP administration and OAuth sign-in relay.

### Draft · Proposed · 2026-09-29 · planning session

- Result: Drafted from the 0.99.0/0.99.1 changelogs, a declaration diff of
  every changed 0.87.1 → 0.99.1 `.d.ts` in `pi-coding-agent`, `pi-ai`,
  `pi-agent-core` and `pi-tui`, the `pi-mcp`/`pi-codemode` packages and docs,
  and an audit of Tron's integration seams.
- Evidence: disposable probe worktree (removed) with 0.99.1 installed:
  `tsc --noEmit` 5 errors; Node 22.22.0 Vitest 2,197/2,198 passing in 85 s;
  `check-pi-sdk` rejecting `pi-mcp`/`pi-codemode`. Read-only checks of the
  live connection store, agent directory and installed packages.
- Changes: this file only; not committed.
- Kept on purpose: the K3 completion cap; Tron's bash process owner.
- For the next agent: the probe numbers are planning evidence, not candidate
  validation.

### Decisions · Proposed · 2026-09-29 · planning session

- Result: The user chose D-1 CLI plus Tron patch writer, D-2 Keychain plus
  `!command`, D-3 allow every tool from codemode, D-4 adding a server approves
  it, D-5 codemode/tool search only when MCP needs them, D-6 migrate Jev to Pi
  now, D-7 support virtual models. The plan was updated to match (P99-20 moved
  from Needs scoping to Ready). It was subsequently approved and activated; the
  approval and active-work claims are recorded in the P99-1 handoff.
- Changes: this file only.

### P99-8 · Claimed · 2026-09-30 · luna-worker

- Result: Implemented bounded MCP administration RPCs for explicit CLI status, add/remove/logout, receipt-backed `enabled`/`exposure` patching, and a Keychain credential-owner seam for static bearer tokens. P99-8 remains Claimed: the required session-bound OAuth callback relay through `createMcpExtension({ openUrl })`, end-to-end PKCE/dynamic-registration/refresh fixture, and related wire/event coverage are not implemented.
- Evidence: Node 22.22.0 TypeScript check passed. Focused `mcp-admin-service.test.ts` passed 4/4 (0.27 s Vitest); it exercised the real bundled `pi mcp list --json`, bounded startup diagnostic, fail-closed config patching/preservation, and injected credential owner. Full Gateway Vitest: 2,301 passed, 3 failed (112.29 s); logger rotation, event-loop histogram and recent-model-usage ordering all passed together on isolated rerun (41/41, 1.42 s). The earlier separate focused run passed 4/4 (0.27 s).
- Changes: `packages/gateway/src/admin/mcp-admin-service.ts` and test; `gateway-service.ts`; `gateway-main.ts`; Gateway README, MCP guide, observability catalog, and this plan.
- Tasks added: none.
- Kept on purpose: `mcp.list` is explicit, bounded to 1 MiB output/30 seconds, and registered as drain-aware RPC work. Mutations use the existing bounded command receipt owner; trusted project scope is canonicalized by TrustService. Token values are excluded from configuration/results/logs, and tests inject the credential owner.
- Deviations: No Gateway-mediated OAuth sign-in was added; `openUrl` remains fail-closed per P99-6. The D-2 Keychain implementation invokes macOS `security`; this host boundary was not invoked in tests. No sign-in-relay observability row or claim is made. Added wire methods/fields for P99-15: `mcp.list` (`scope`, `cwd`); `mcp.add` (`commandId`, `scope`, `cwd`, `server`, `transport`, `url` or `command`/`args`, optional `exposure`); `mcp.remove` and `mcp.logout` (`commandId`, scope, server); `mcp.update` (`commandId`, scope, server, `enabled` and/or `exposure`); `mcp.token.set` (`commandId`, scope, server, transient `token`). Results include `servers`, `reloadRequired`, and for patching `changed`. No OAuth sign-in wire RPC exists yet.
- For the next agent: finish relay ownership by binding an `openUrl` request to the selected session and authenticated iOS client, reuse AuthBroker's validated loopback capture/callback relay, preserve Pi's pasted redirect fallback, then add the local OAuth+MCP PKCE/dynamic-registration/token-refresh E2E and relay outcome observability row before setting P99-8 Done. Do not use the Mac browser.

### P99-8 continuation · Incomplete · 2026-09-30 · luna-worker

- Result: Removed the bearer token from the `security add-generic-password -w` argv path. `/usr/bin/security help add-generic-password` documents `-w` as an argv value or interactive prompt and offers no direct stdin option. Following supervisor correction, the credential owner now spawns `/usr/bin/security -i` and sends a quoted command line through stdin; quotes and backslashes are escaped, while newline/NUL tokens are rejected. No Swift toolchain or runtime compilation is needed. This keeps the token out of argv/environment while preserving the credential-owner seam and `!command` reader.
- Evidence: With Node 22.22.0, `tsc -p tsconfig.json --noEmit` passed and `mcp-admin-service.test.ts` passed 5/5 (Vitest 0.34 s), including quote/backslash/space escaping and newline/NUL rejection. Fake runner captures only `security -i` in argv and the command on stdin; the real Keychain write was intentionally not invoked. Commits: `2f9f9edb9`, `4076a755e` (superseded Swift implementation), and the interactive-security correction is recorded in the next commit.
- Changes: `packages/gateway/src/admin/mcp-admin-service.ts`, its focused test, and this plan entry.
- Tasks added: none.
- Kept on purpose: no token is passed as an argv parameter or environment variable. `security find-generic-password -w` remains the accepted read path. Static bearer access remains behind the injected credential owner.
- Deviations: This is not P99-8 completion. The session-bound AuthBroker/OAuth relay, pasted-redirect prompt ownership, local OAuth+MCP PKCE/dynamic-registration/token-refresh E2E, and relay-outcome observability are outstanding. The user-approved supervisor direction requires `mcp.auth.start`/`mcp.auth.cancel` and per-RuntimeSlot `openUrl` binding; no substitute OAuth flow was introduced. No full Gateway suite was run because the required OAuth feature and its owning E2E remain unimplemented.
- For the next agent: continue P99-8 before changing its row to Done; use the approved design in the coordination reply: start/cancel are session-bound, issue Pi's own MCP login command, route `openUrl` only for an active server operation, reuse AuthBroker callback capture/relay and event shapes, and cancel on teardown/eviction. Record wire shape for P99-15.

### P99-9 · Done · 2026-09-30 · luna-worker

- Result: AuthBroker supplies the global SettingsManager's stable device ID to every provider login, and serializes `openai` and `openai-codex` OAuth operations process-wide because both SDK listeners require callback port 1455. The provider catalog exposes OpenAI API key and OAuth methods and labels Codex as `OpenAI Codex (legacy)`; OpenAI OAuth is not usage-supported. The existing settings projection's P99-3 regression confirms `deviceId` remains redacted.
- Evidence: Node 22.22.0 `tsc -p tsconfig.json --noEmit` passed. Focused Vitest passed 36/36 across `auth-broker.test.ts`, `provider-usage-rpc.test.ts`, and `settings-service.test.ts` in 1.04 s. Final full Gateway run passed 2,306/2,307 in 118.50 s; the timing-sensitive session-search-stall case failed under suite load and passed on isolated rerun, 2/2 in 7.94 s. The AuthBroker integration uses fake fetch for the token exchange, captures the authorization URL's `ext_agent_host_id=urn:uuid:<stable-id>`, relays the provider callback through the broker, and verifies the authorization-code exchange. The serialization test proves Codex login does not enter Pi until the ChatGPT login settles. Existing settings regression asserts projected global settings omit `deviceId`.
- Changes: `packages/gateway/src/admin/auth-broker.ts`, its test, `gateway-main.ts`, `packages/gateway/src/transport/provider-usage-rpc.test.ts`, Gateway README, and this plan row/matrix/handoff.
- Tasks added: none.
- Kept on purpose: provider usage remains supported only for OpenAI Codex's existing `wham` adapter; `openai` OAuth is intentionally not claimed. Provider methods and labels remain sourced from Pi's provider catalog.
- Deviations: The auth integration uses Pi's actual OpenAI provider login with fake token-fetch responses and the real local callback listener on port 1455; no external network or real credential was used. No wire protocol changed.
- For the next agent: no P99-15 wire changes arise from P99-9. Live ChatGPT sign-in remains the P99-18 manual gate; provider catalog and usage-support disposition are covered by the focused regression.

### P99-10 · Done · 2026-09-30 · luna-worker

- Result: GlobalProviderResources now captures, replays and removes global virtual-model registrations alongside provider registrations. `model.list` adds the `virtual` marker. Context-window policy retains virtual selection identity but takes effective limits from `AgentSession.routedModel` when available; compaction policy likewise captures the latest routed physical model and thinking level. Assistant transcript rows preserve the physical provider/model already recorded by Pi and now project optional `thinkingLevel`. Pi's canonical virtual-state custom entry remains outside transcript rows; model usage/cost stays sourced from Pi's physical assistant responses.
- Evidence: Node 22.22.0 TypeScript check passed. Focused admin/context/compaction tests passed 37/37 in 1.03 s. The virtual routing case uses two faux catalog models, exercises user routing plus SDK retry/direct routing reasons, validates physical assistant identity/thinking level and hidden state, and retains `packages/gateway/test-results/pi-sdk-099-virtual-models.json`. `check:pi-sdk` and personal-info guard passed. Two final Gateway runs each passed 2,308/2,309 (110.92 s, logger rotation timeout; 116.66 s, session-search-stall timing assertion); logger rotation passed its isolated rerun 16/16 in 1.29 s and session-search-stall passed its isolated rerun 2/2 in 5.02 s.
- Changes: `packages/gateway/src/admin/global-provider-resources.ts` and its test, `providers/context-window-policy.ts` and test, `runtime/compaction-policy.ts`, `sessions/projection.ts`, `protocol/types.ts`, `transport/gateway-service.ts`, Gateway README, and this plan.
- Tasks added: none.
- Kept on purpose: model context preferences stay keyed to selected model identity; routed physical limits only bound effective capacity. Cost continues to derive from physical Pi assistant response usage; no second cost accumulator or state projection was added.
- Deviations: Evidence is narrower than the requested fixture-router lifecycle matrix: the faux-router proof exercises SDK `user`, `retry`, and `direct` routing and transcript projection, but does not yet drive cold resume, fork, actual automatic retry or compaction through the RuntimeRegistry. P99-17 must add that cross-path integration proof before overall plan close-out. No product or schema decision was needed.
- For the next agent: P99-15/P99-16 must consume the additive `model.list.virtual` boolean and assistant-row `thinkingLevel` / physical `provider` and `modelId`; these are the P99-10 wire additions. P99-17 owns the remaining resume/fork/retry/compaction router E2E and must verify usage/cost grouping by physical model. The retained artifact is gitignored and regenerated by `node node_modules/vitest/vitest.mjs run src/providers/context-window-policy.test.ts -t 'SDK-routed physical'` from `packages/gateway`.

### P99-12 · Done · 2026-09-30 · luna-worker

- Result: Refreshed the release-date snapshot from public models.dev data. Qualified Claude Sonnet 5.5 (1,000,000 context / 128,000 output) and GPT-6.1 Sol (272,000 / 128,000) against Pi's catalog. Kimi K3's new 1,048,576 context/output metadata does not raise Tron's 32,768-token request cap; payload normalization clamps `max_tokens` without renaming the provider parameter. TypeSafe's classifier-only provider stays visible in `provider.list` when configured (zero chat models) and does not appear in chat `model.list`. Pi's discriminated image/classifier models.json schema and CortexKit-style override validate; typed pi.dev catalog refresh asks for chat,image,classifier, persists all three to models-store.json and reloads its chat projection.
- Evidence: Node 22.22.0 `tsc -p tsconfig.json --noEmit` passed. Focused Vitest passed 40/40 across model-config, global-provider resources, Kimi policy, context-window and model-catalog files (1.08 s). Final Gateway suite: 2,313/2,315 passed (113.09 s); `recent-model-usage.integration.test.ts` and `session-search-stall.test.ts` passed isolated together, 5/5 (5.23 s), so both full-suite failures were timing-sensitive under host load. `scripts/update-model-release-dates.mjs` completed from public models.dev without credentials; `personal-info-guard.sh` passed.
- Changes: commit `ce7152130`; release-date JSON, Kimi policy and focused catalog/provider regressions. This plan update is committed separately. No wire protocol change.
- Tasks added: none.
- Kept on purpose: TypeSafe remains discoverable and credential-configurable in providers even though it has no chat models; image/classifier types remain SDK-owned and outside the chat picker. Pi's fixed model type union remains authoritative; image generation stays deferred to P99-21.
- Deviations: Did not make a separate model.list filter because Pi's `ModelRuntime.getModels()` is already a chat-only projection; the fake-fetch test verifies typed image/classifier records persist while both are excluded from the chat projection. Classifier request cost aggregation remains covered by the P99-5 tool-result usage boundary rather than a credentialed TypeSafe network request; tests use fake credentials/fetch only. Full-suite ordering and event-loop bounds produced the two timing-sensitive failures listed above, both passed on isolated rerun. No credential or real provider network call was used.
- For the next agent: no wire changes from P99-12. P99-20 owns the separate Jev migration; P99-17 should retain the documented isolated timing rerun evidence when recording final cross-module validation.

### P99-8 continuation · Done · 2026-09-30 · luna-worker

- Result: Added session-bound MCP auth start/cancel through the existing AuthBroker operation lifecycle. `mcp.auth.start` acquires the subscribed session slot and admits Pi's `/mcp login <server>` command through normal prompt admission; a narrow owner-admission adapter routes only the built-in MCP command's operation-scoped pasted-redirect input and notices into auth events/prompts. Per-slot `openUrl` fails closed unless its AsyncLocalStorage context names an active Tron MCP auth operation. Session closure retires its operation. Callback capture remains derived only from Pi's authorization URL and callback relay remains restricted to Pi's loopback listener.
- Evidence: Node 22.22.0 `tsc -p tsconfig.json --noEmit` passed. Final full Gateway Vitest passed 2,317/2,317 (215 files, 109.45 s wall). Focused pre-final run passed 40/40 across auth broker, MCP auth integration, adapter and MCP admin owners; the full suite includes the additional failed-relay case. Retained fixture artifact: `packages/gateway/test-results/mcp-auth-relay.json`, showing the local HTTP OAuth/MCP challenge, PKCE S256 verification, dynamic registration, callback relay, token persistence in temporary `mcp-auth.json`, refresh after expiry, and authorized MCP endpoint request. AuthBroker tests cover operation timeout, cancellation and session teardown; adapter test confirms ordinary command UI still falls through outside the auth operation.
- Changes: `packages/gateway/src/admin/auth-broker.ts`, `packages/gateway/src/admin/auth-broker.test.ts`, `packages/gateway/src/admin/mcp-auth.integration.test.ts`, `packages/gateway/src/extensions/extension-adapters.ts`, `packages/gateway/src/extensions/extension-adapters.test.ts`, `packages/gateway/src/extensions/owner-attribution.ts`, `packages/gateway/src/extensions/pi-builtins.ts`, `packages/gateway/src/sessions/runtime-slot.ts`, `packages/gateway/src/sessions/runtime-registry.ts`, `packages/gateway/src/transport/gateway-service.ts`, `packages/gateway/src/gateway-main.ts`, `packages/gateway/README.md`, `packages/gateway/docs/mcp.md`, `packages/gateway/docs/observability.md`, and this plan.
- Tasks added: none.
- Kept on purpose: AuthBroker's one-operation-per-owner/session/server recovery key, existing 15-minute timeout, prompt and callback validation, replay/tombstone handling and owner checks. Pi's OAuth/PKCE/dynamic-registration/token-refresh implementation remains the only OAuth implementation; no browser opener or parallel OAuth client was added.
- Deviations: The retained local fixture calls Pi's MCP OAuth implementation directly through the built-in's internal module and validates an HTTP MCP challenge/authorized endpoint; it does not launch the full iOS transport or a production Gateway runtime. No real network service, Keychain, browser, or live Gateway was used. `mcp.auth.start/cancel` wire additions are: `mcp.auth.start { sessionId, server, commandId } -> { operationId, recovered }`; `mcp.auth.cancel { operationId } -> { cancelled }`. Existing `auth.event`, `auth.prompt`, and `auth.completed` payloads carry target `{ kind: "mcp", sessionId, server }` for P99-15. Added observability events: `mcp.auth-url.routed`, `mcp.callback-relay.succeeded`, and `mcp.callback-relay.failed`, without authorization URLs or callback values.
- For the next agent: P99-15 should use the documented RPCs and target shape; P99-17 should review the local artifact and perform the final payload/documentation/personal-info gates. P99-18 retains live iPhone OAuth as a manual acceptance gate.

### P99-20 · Done · 2026-09-30 · luna-worker

- Result: Replaced the fixed-host Jev HTTP client with Pi `ModelRuntime.classify()` on TypeSafe's catalog `jev-latest` for Knowledge, session search and the first-party tool. Administrative Knowledge/search use the Gateway model runtime; the `jev` tool builds its adapter from each session runtime. The adapter retains input/response bounds, validates answers, maps wire `noul` to Pi bool probability, enforces the 64k-input/0.2688-cent `maxChargeCents` ceiling before dispatch, and preserves not-sent/sent/uncertain certainty. Assessment rubric/profile versions, recorded shape and usage remain Tron-owned. The Jev ConnectionOwner definition and connector Keychain lookup are removed; a persisted `knowledge.jev` instance is rejected with an instance-naming provider-setup error. The durable monthly tagging ledger remains under the TypeSafe provider identity.
- Evidence: Node 22.22.0 TypeScript check passed (3.10 s). Focused classifier/assessment/tagger/connector/connection/search/codemode run passed 107/108 across 10 files (7.00 s); the lone `ENOTEMPTY` cleanup failure in `knowledge-intake-enrichment` passed individually 1/1 in 0.50 s. Classifier/assessment/tool tests after the bounded-response addition passed 12/12 (0.77 s). Fake-fetch regression captures the actual Pi/TypeSafe request at `https://api.typesafe.ai/v1/systemone`, model `jev-latest`, wire question `noul`, and synthetic credential header; it writes `packages/gateway/test-results/pi-sdk-099-jev-classifier-wire.json` (gitignored). P99-22 nested codemode E2E still admits concurrent Jev calls and rejects both over-ceiling calls before fetch; its artifact records the admitted wire model. Final full Gateway suite: 2,309/2,311 passed across 214 files in 111.12 s. The resource-sensitive knowledge-curation case (1/1, 0.91 s) and recent-model-usage ordering case (1/1, 0.18 s) passed individually after the full run's timeout and ordering failure. `git diff --check` and personal-info guard passed.
- Changes: `jev-client.ts`/test; `jev-assessment.ts`/test; `jev-extension.ts`/test; Knowledge tagger/service/contracts, connector dispatch certification and documentation; ConnectionOwner Jev-definition removal/legacy-state rejection; session runtime and session-search integration tests; P99-22 nested Jev fixture; this plan's D-6 addendum, matrix, task row and handoff.
- Tasks added: none.
- Kept on purpose: request and response bounds, Tron-qualified input pricing (Pi catalog cost is zero and is never trusted for a ceiling), per-call caller-authorized limits, assessment rubric/profile versions, durable monthly tagging reservations, and dispatch certainty. No credential is copied from the old Keychain path. No session-search or assessment UI/wire protocol changed.
- Deviations: The user changed model choice to `jev-latest`; its behavior and TypeSafe actual pricing may change without a Tron release. No supervisor reply arrived to clarify whether the old per-connection `paidAccessApproved` consent should migrate. The implementation treats a configured TypeSafe provider credential as tagging eligibility, removes that per-connection approval switch, and retains a durable 500-cent default monthly cap; P99-18 should confirm this consent transition. `knowledge.tags.*` keeps its shared `connectionId` envelope field but accepts only provider identity `typesafe`; no new RPC schema was introduced. The tool output itself changes to Pi's bool/score answer shape, as D-6 accepts.
- For the next agent: P99-15 should verify the TypeSafe provider credential is visible in iOS settings and review Knowledge tag controls against the TypeSafe provider identity; no `knowledge.jev` connection or old Keychain credential should be recreated. P99-17 should rerun the full suite at its final checkpoint, retain the isolated timing rerun results above, and include `pi-sdk-099-jev-classifier-wire.json` in the artifact review.

### P99-15 · Done · 2026-09-30 · luna-worker

- Result: Replaced the connection-backed MCP settings route with Pi MCP administration over the global and trusted-project scopes. The screen lists state/tool counts/exposure/errors, supports stdio and HTTP add, bearer-token entry, update/remove/logout, and starts/cancels session-bound sign-in using the existing provider-auth presentation content. Extensions Settings now exposes scoped `-builtin:` toggles, `defaultTools` modifiers (`+codemode` and `+tool_search`), and codemode mode. Provider Settings keeps classifier-only TypeSafe key entry available even when absent from chat-provider rows. Removed MCP-only projection and drain enum cases, MCP instruction attribution, and the retired setup form.
- Evidence: `scripts/tron-ios-test build` passed (final pass, 155.9 s wall; separate candidate lane `p9915` because the shared default lane was owned by another worktree). `scripts/tron-ios-test run --only-testing TronMobileTests/ExtensionsCatalogPresentationTests` passed 3/3 (5.6 s); `scripts/tron-ios-test run --only-testing TronMobileTests/IntegrationModelsTests` passed 5/5 (5.7 s); `scripts/tron-ios-test run --only-testing TronMobileTests/SettingsRouteIdentityTests` passed 3/3 (4.5 s before the final UI additions). `git diff --check` passed.
- Changes: `packages/ios-app/Core/Models/GatewayConnectionModels.swift`, `packages/ios-app/Core/Models/IntegrationModels.swift`, `packages/ios-app/Core/Models/ResourceCatalogModels.swift`, `packages/ios-app/Sources/State/AppModel.swift`, `packages/ios-app/Sources/State/IntegrationsRPCClient.swift`, `packages/ios-app/Sources/UI/Chat/AgentInstructionsSheet.swift`, `packages/ios-app/Sources/UI/Settings/BuiltinExtensionsSettingsSection.swift`, `packages/ios-app/Sources/UI/Settings/ConnectionSettingsView.swift`, `packages/ios-app/Sources/UI/Settings/ExtensionsSettingsView.swift`, `packages/ios-app/Sources/UI/Settings/IntegrationsSettingsView.swift`, `packages/ios-app/Sources/UI/Settings/MCPAuthSheet.swift`, `packages/ios-app/Sources/UI/Settings/MCPServersSettingsView.swift`, `packages/ios-app/Sources/UI/Settings/ProviderSettingsView.swift`, `packages/ios-app/Sources/UI/Settings/SettingsView.swift`, `packages/ios-app/Tests/UI/ExtensionsCatalogPresentationTests.swift`, `packages/ios-app/Tests/UI/IntegrationModelsTests.swift`, `packages/ios-app/Tests/UI/SettingsRouteIdentityTests.swift`, and this plan.
- Tasks added: none.
- Kept on purpose: Pi `mcp.json` remains the sole MCP configuration authority; server mutations carry command IDs through the shared mutation executor; bearer values are transient RPC inputs and remain Mac-Keychain-owned.
- Deviations: Hosted standard/accessibility-size, light/dark simulator screenshots of the MCP and extension screens were not retained in the result bundle; final validation was build plus focused model/presentation suites, not a UI screenshot test. No product Gateway, external MCP server or real credentials were used.
- For the next agent: review MCP list-field decoding against the live Pi CLI only at user acceptance; P99-17 retains final screenshot/artifact and documentation-policy checkpoints. The approved design note was inserted verbatim after the P99-16 task details.

### P99-16 · Done · 2026-09-30 · luna-worker

- Result: Added Pi transcript response fields (`nestedCalls`, `details`, `usage`, and per-response `thinkingLevel`) to the iOS projection; tool details now present generic/MCP/resource/tool-search results, bounded arguments, nested codemode calls/status/duration, parent-owned display/browser attachments, classify cost, and bash's real empty output. Added namespace/exposure-aware session tool selection, virtual-model labels in model/session selection, and physical model attribution per assistant response.
- Evidence: `TRON_IOS_TEST_LANE=p9916 scripts/tron-ios-test build` passed. Focused `ToolDetailPresentationTests` + `SessionToolPickerTests` passed 36 tests across 2 suites (4.25 s runner wall, test execution 0.06 s). Required full `TronMobileTests` run executed 1,923 tests in 154 suites but failed 5 issues (including 1 known issue); failures listed `ChatViewScrollHarnessTests.coveredChatDefersComposerCatalog(managedSheet:changesCommands:)` twice and `ChatViewScrollHarnessTests.displacedRetainedResume()`. Focused follow-up of `ChatViewScrollHarnessTests` ran 72 tests and failed `displacedRetainedResume()` and `unifiedResponseAndNotificationSettlement()` (3 issues including 1 known issue); unrelated chat scroll/composer harness. Full result bundle: `~/Library/Developer/Tron/ios/test-runs/20260930T093746Z-run.nFMbnn`; focused rerun: `~/Library/Developer/Tron/ios/test-runs/20260930T094335Z-run.jVAQhf`; targeted bundle: `~/Library/Developer/Tron/ios/test-runs/20260930T093718Z-run.tfRjMX`.
- Changes: `packages/ios-app/Core/Models/ResourceCatalogModels.swift`, `packages/ios-app/Core/Models/TranscriptModels.swift`, `packages/ios-app/Sources/UI/Chat/ChatCompactPill.swift`, `ChatTranscriptPresentation.swift`, `ChatTranscriptProjectionKernel.swift`, `SessionContextSheet.swift`, `SessionSummaryCards.swift`, new `SessionToolPickerSheet.swift`, `ToolDetailPresentation.swift`, `ToolDetailSheet.swift`, `TranscriptRow.swift`, `packages/ios-app/Sources/UI/Onboarding/SetupComponents.swift`, `packages/ios-app/Tests/Gateway/ToolDetailPresentationTests.swift`, new `packages/ios-app/Tests/UI/SessionToolPickerTests.swift`, `packages/ios-app/docs/architecture.md`, and this plan.
- Tasks added: none.
- Kept on purpose: Pi's canonical nested calls/details/usage remain authoritative; children are not synthetic transcript rows. Parent-owned display descriptors route through existing session-bound display presentation. Physical model attribution and virtual model identity remain distinct.
- Deviations: Required standard/accessibility-size and light/dark live/reloaded simulator screenshots for each card were not captured or retained. Full-suite scroll-harness failures persist on focused rerun; no unrelated scroll/composer code was changed. P99-17 retains the final visual-evidence checkpoint.
- For the next agent: P99-17 must rerun the focused failed harness tests, investigate the full-suite failure signal, capture/retain the required live and post-reload cards at standard/accessibility text sizes and light/dark, complete final validation, and cite artifact paths in its handoff. The full and focused xcresult bundles above are preserved.

### P99-17 A · Partial · 2026-09-30 · luna-worker

- Result: Extended the rollback persistence probe and confirmed the 0.87.1 reader opens and reopens 0.99-written codemode, virtual-model, tool-search, nested-call and parent presentation entries without losing parent content or structured content. Staged and verified the Mac payload. Corrected P99-14's installed-browser-fork misidentification and rewrote P99-24 as the browser-package/runtime follow-up. P99-17 remains Claimed.
- Evidence: `node scripts/check-pi-sdk-rollback.mjs` passed 0.87.1 → 0.99.1 in 8.74 s; retained command output at `packages/gateway/test-results/pi-sdk-099-rollback.log` with timing at `packages/gateway/test-results/pi-sdk-099-rollback.time.txt`. Node 22.22.0 `tsc -p tsconfig.json` passed. `packages/mac-app/scripts/bundle-gateway.sh --skip-install` staged payload fingerprint `c8e19d2058818ae8a93609254e01a6718a16b50a2e920fd74c8d27861974147a`; `bundle-gateway.sh --verify-only`, `test-gateway-payload-verifier.sh`, and `check-pi-sdk.mjs --runtime-tree` passed. Verified 68 codemode-named files, `quickjs.wasm` and nested `pi-mcp` in the generated payload. It is ignored generated output, not committed.
- Changes: rollback probe and fixture README; plan matrix and correction/this handoff. Commit `4b1c1bcf3` contains the rollback fixture improvement.
- Tasks added: none. P99-24 is rewritten, not a new row.
- Kept on purpose: `details.tronNested` stays an additive unknown-details payload; 0.87.1 preserves it opaquely while continuing to read the parent's content and structured content. The installed browser fork was copied read-only; no live settings/package, Gateway, provider or browser was touched.
- Deviations: The browser fork was identified (0.4.1 + Tron-only commit `1b5f11bb251843f5b7536eea9eea7b17f96ac970`, while settings pin `d6cde09af8d7757bbfba5a4ffaf83381bb392683`) but direct/nested receipt admission against the actual fork and fake executable was not completed. Likewise outstanding: end-to-end MCP RPC -> `/mcp login` -> AuthBroker -> callback -> next-turn MCP call; typed `/mcp login` fail-closed proof; virtual lifecycle across resume/fork/retry/compaction; codemode `models.classify` cost/session totals; full Gateway/iOS/visual suite and HTML export comparison. No full Gateway run or iOS simulator run was done. The first `bundle-gateway.sh --skip-install --skip-download` attempt correctly failed because no staged Node runtime existed; the successful `--skip-install` run downloaded/staged it. Bundle script emitted npm audit reporting two high-severity advisories in the generated dependency audit; no remediation was attempted.
- For the next agent: finish the four Gateway E2Es above, then complete P99-17 full validation, visual artifacts, docs/observability and review. The proposed docs/plans/2026-09-30-node-runtime-lifecycle.md proposes taking ownership of the browser package's Node 24.21 requirement. Do not advance P99-17 until the remaining acceptance evidence is complete.

### P99-17 B · Done · 2026-09-30 · luna-worker

- Result: Triaged the three P99-16 `ChatViewScrollHarnessTests` failures against main and candidate. All three exact tests passed twice on both builds. The displaced-retained-resume watchdog failure reproduces only when the wider harness suite is selected, on both main and candidate, so it is pre-existing; no iOS code or tests were changed.
- Evidence: Built baseline `f26b098f5` in a disposable detached worktree and candidate `cc4452a3f` using their own `p9917b-base` and `p9917b-cand` lanes. The three-test exact selection passed 3/3 twice on each side (6/6 per side); test execution was 6.29 s and 7.30 s on baseline, and 5.77 s and 5.81 s on candidate. Retained result bundles: `~/Library/Developer/Tron/ios/test-runs/20260930T144601Z-run.A8nDiG/TestResults.xcresult`, `~/Library/Developer/Tron/ios/test-runs/20260930T144640Z-run.BZMd7n/TestResults.xcresult`, `~/Library/Developer/Tron/ios/test-runs/20260930T144453Z-run.2NCxUw/TestResults.xcresult`, and `~/Library/Developer/Tron/ios/test-runs/20260930T144525Z-run.RdEXka/TestResults.xcresult`. The broader harness-suite selector failed only `displacedRetainedResume()` by its 15-second watchdog in both baseline runs (99.82 s, 99.55 s) and both candidate runs (98.52 s, 100.07 s); the other two targeted tests passed in all four. Wider-suite result bundles: `~/Library/Developer/Tron/ios/test-runs/20260930T143421Z-run.jI7Z8V/TestResults.xcresult`, `~/Library/Developer/Tron/ios/test-runs/20260930T143641Z-run.QbscbU/TestResults.xcresult`, `~/Library/Developer/Tron/ios/test-runs/20260930T143951Z-run.am0FST/TestResults.xcresult`, and `~/Library/Developer/Tron/ios/test-runs/20260930T144203Z-run.2gxrTP/TestResults.xcresult`.
- Changes: This P99-17 B handoff entry only. No iOS source or tests changed. Disposable baseline worktree removed.
- Tasks added: none.
- Kept on purpose: `displacedRetainedResume()` and its watchdog/assertions remain untouched; exact isolated runs pass, while the full harness-suite-only watchdog expires reproducibly on both baseline and candidate.
- Deviations: The iOS runner's direct Swift Testing selectors accepted the three named tests with their complete XCTest identifiers; initial method-only selectors yielded zero tests and were discarded. Separate wider ChatView suite runs were also used to confirm the suite-load failure boundary, beyond the exact named-test runs.
- For the next agent: treat the `displacedRetainedResume()` broad-suite watchdog timeout as pre-existing; the exact three tests pass twice on candidate and baseline. No candidate-only scroll-harness regression was found.

### P99-17 C · Done · 2026-09-30 · luna-worker

- Result: Added hosted iOS visual fixtures for Pi MCP server/settings, MCP and codemode tool presentations, technical details, the namespace tool picker, and routed physical-model attribution. Captures cover 18 views in light/dark and standard/accessibility text (72 PNGs) with a generated index. Capture review found codemode script source incorrectly shown as primary inline content; it now opens from a dedicated source sub-sheet after readable output, nested calls, attachments, and cost.
- Evidence: `TRON_IOS_TEST_LANE=p9917c scripts/tron-ios-test build` passed. `TRON_IOS_TEST_LANE=p9917c scripts/tron-ios-test run --only-testing TronMobileTests/Pi099VisualEvidenceTests` passed 1/1, Swift Testing 6.95 s (runner 12.71 s); generated `packages/ios-app/build/p99-captures/index.json` and 72 images, ignored by git. `TRON_IOS_TEST_LANE=p9917c scripts/tron-ios-test run --only-testing TronMobileTests/ToolDetailPresentationTests` passed 35/35, Swift Testing 0.05 s. `scripts/personal-info-guard.sh`, documentation policy and `git diff --check` passed.
- Changes: `packages/ios-app/Tests/UI/Pi099VisualEvidenceTests.swift`, `packages/ios-app/Sources/UI/Chat/ToolDetailSheet.swift`, `packages/ios-app/docs/architecture.md`, and this handoff.
- Tasks added: none.
- Kept on purpose: the fixture test writes its PNGs/index only under ignored `packages/ios-app/build/p99-captures`; only source, test and owning documentation are committed. Hosted settings fixtures reuse Tron glass, typography, and accent components while keeping configuration/credentials fake.
- Deviations: fixture settings views reproduce realistic global/project MCP, extension/default-tool and TypeSafe states with shared Tron components; they do not instantiate the live `AppModel`-bound RPC screens. Visual review covered all 18 standard-light views and representative dark/accessibility captures, not every one of the 72 individual PNGs. No Gateway, provider or external MCP connection was used.
- For the next agent: regenerate the captures with the focused hosted-test command. Full cross-module P99-17 validation and independent diff review remain outside this Part C handoff.

### P99-17 D · Done · 2026-09-30 · luna-worker

- Result: Completed P99-17 close-out. Parts A-C and this final part qualify rollback compatibility, staged Mac payload, iOS baseline failures, hosted visual evidence, documentation, HTML export, and the final cross-module checks. P99-17 is Done; P99-18 stays Ready.
- Evidence: Out-of-process HTML export integration passed 1/1; `packages/gateway/test-results/pi-sdk-099-html-export.json` records a rendered HTML artifact whose hidden custom message retains `display: false`, uses Pi's `hook-message-hidden` renderer, and has its abandoned branch omitted. The full Gateway, Mac, and iOS validation evidence and command wall times are recorded below after final run. Rollback artifacts: `packages/gateway/test-results/pi-sdk-099-rollback.log` and `packages/gateway/test-results/pi-sdk-099-rollback.time.txt`. Staged payload fingerprint from Part A: `c8e19d2058818ae8a93609254e01a6718a16b50a2e920fd74c8d27861974147a`.
- Changes: Gateway SDK boundary map and MCP guide; replaced stale ConnectionOwner/Jev/MCP claims in Gateway connections and iOS architecture; documented MCP auth target in iOS events; added the hidden-message HTML export regression and retained artifact. Updated the HTML matrix disposition and marked P99-17 Done. No event, protocol, persistence, or UI behavior changed.
- Tasks added: none.
- Kept on purpose: Pi remains the sole MCP client/configuration owner and HTML renderer; Pi JSONL remains canonical. D-8 stays additive under parent `details.tronNested`; no synthetic child rows/receipts. P99-24 remains unscoped and no browser package or installed user state was changed.
- Deviations: trusted installed-browser-fork receipt success and aborted-stash enrichment negative coverage remain unresolved from Part A/P99-23; virtual-model full resume/fork/automatic-retry/compaction lifecycle coverage and codemode `models.classify` session-cost integration remain evidence gaps identified in Part A. The P99-16 broad-suite displaced-resume watchdog is pre-existing on baseline and candidate; exact selected tests passed twice on both. P99-18 must resolve the Jev consent transition and the P99-24/P99-19/P99-21 scope questions before integration/acceptance.
- For the next agent: artifacts from P99-17 Parts A-D are `packages/gateway/test-results/pi-sdk-099-rollback.log`, `packages/gateway/test-results/pi-sdk-099-rollback.time.txt`, `packages/gateway/test-results/pi-sdk-099-html-export.json`, `packages/gateway/test-results/pi-sdk-099-nested-presentation.json`, `packages/gateway/test-results/pi-sdk-099-jev-classifier-wire.json`, `packages/gateway/test-results/pi-sdk-099-virtual-models.json`, `packages/gateway/test-results/mcp-auth-relay.json`, `packages/ios-app/build/p99-captures/index.json` and its 72 PNGs; Part B result bundles are `~/Library/Developer/Tron/ios/test-runs/20260930T144601Z-run.A8nDiG/TestResults.xcresult`, `~/Library/Developer/Tron/ios/test-runs/20260930T144640Z-run.BZMd7n/TestResults.xcresult`, `~/Library/Developer/Tron/ios/test-runs/20260930T144453Z-run.2NCxUw/TestResults.xcresult`, `~/Library/Developer/Tron/ios/test-runs/20260930T144525Z-run.RdEXka/TestResults.xcresult`, `~/Library/Developer/Tron/ios/test-runs/20260930T143421Z-run.jI7Z8V/TestResults.xcresult`, `~/Library/Developer/Tron/ios/test-runs/20260930T143641Z-run.QbscbU/TestResults.xcresult`, `~/Library/Developer/Tron/ios/test-runs/20260930T143951Z-run.am0FST/TestResults.xcresult`, and `~/Library/Developer/Tron/ios/test-runs/20260930T144203Z-run.2gxrTP/TestResults.xcresult`. The payload is ignored generated output, verified by `bundle-gateway.sh --verify-only`, `test-gateway-payload-verifier.sh`, and the SDK runtime-tree checker. User decisions remain: Jev paid-tagging consent; P99-24 browser/runtime follow-up; P99-19 upstream MCP config/theme scoping; P99-21 image-generation scoping. P99-18 also owns live iPhone MCP OAuth/ChatGPT and actual signed-build adoption gates.

### P99-17 correction · Claimed · 2026-09-30 · luna-worker

- Correction: P99-17 D marked the row Done while these Gateway evidence gaps were open: MCP RPC-to-token-to-tool E2E and typed-command fail-closed proof; actual installed browser fork direct/nested receipt and abort-stash proof; virtual-model resume/fork/retry/compaction lifecycle; codemode classifier cost in session totals; and codemode execution observability plus MCP process-count limitation documentation. The row is Claimed until these are proven and final validation completes.

### P99-17 E · Partial · 2026-09-30 · luna-worker

- Result: Added the missing privacy-safe top-level codemode execution log event. It records outcome, duration, nested-call count, completeness and session ID, and excludes script, arguments and output. Updated the observability catalog to state that MCP stdio process count is not exposed by Pi's public runtime API (P99-22's process-group cleanup assertions are the lifecycle evidence), and added public per-session MCP status/process count to P99-19. P99-17 remains Claimed.
- Evidence: Node 22.22.0 TypeScript check passed. Focused RuntimeRegistry codemode integration passed 1/1 (Vitest 1.26 s); the retained artifact `packages/gateway/test-results/pi-sdk-099-nested-presentation.json` includes the log diagnostic and parent live/cold-reload evidence. Full Gateway Vitest passed 2,316/2,317 across 214/215 files in 109.57 s; `session-search-stall.test.ts` failed under suite load (event-loop stretch threshold), then passed isolated 2/2 in 4.93 s. The focused test validates the exact privacy-safe field set and fails if no diagnostic is emitted.
- Changes: `packages/gateway/src/sessions/runtime-slot.ts`, `runtime-registry.ts`, `gateway-main.ts`, `codemode-nested-presentation.integration.test.ts`, `packages/gateway/docs/observability.md`, and this plan. Commits: `9d8a16105` (reopen P99-17 and correction), `858e274fa` (observability implementation).
- Tasks added: none.
- Kept on purpose: P99-17 remains Claimed. No Gateway lifecycle action, live MCP connection, provider credential, actual browser or user installation was touched. The artifacts are ignored test output, not committed fixtures.
- Deviations: The other requested end-to-end gaps are still open: full RuntimeRegistry MCP RPC → Pi `/mcp login` → callback/token → next-turn tool call and typed `/mcp login` fail-closed; direct and nested receipts from the read-only installed browser fork with fake executable and aborted-stash proof; virtual model lifecycle through resume/fork/automatic retry/compaction; and `models.classify` cost in codemode result/session totals. The full-suite timing failure passed its isolated rerun. No visual/iOS/Mac validation was run in this Gateway-only part.
- For the next agent: complete each remaining Gateway integration with retained artifacts under `packages/gateway/test-results`, then repeat final TypeScript/full Gateway and cross-module gates before moving P99-17 beyond Claimed. Inspect whether Pi emits abort/timeout explicitly on codemode `tool_execution_end`; this implementation records those only when present in result details, otherwise the authoritative event status is completed/failed.

### P99-17 g1 · Done · 2026-09-30 · luna-worker

- Result: Proved MCP sign-in across the real Gateway RPC, RuntimeRegistry session, AuthBroker callback relay, Pi OAuth token store, and next-turn direct tool call; chat `/mcp login` without a Tron operation fails closed without relaying an auth URL or opening a browser.
- Evidence: Focused `mcp-auth-session.integration.test.ts` passed 2/2 tests in 2.04 s; retained artifact `packages/gateway/test-results/pi-sdk-099-mcp-signin-session.json` records RPC start, MCP auth target/URL, callback, successful completion, agent-directory token persistence, and successful direct tool result.
- Changes: Added the live session integration regression, corrected built-in MCP command adaptation to match Pi's synthetic `sourceInfo.path` (`builtin:mcp`) rather than its generic `source` (`builtin`), and documented the real-path evidence in `packages/gateway/docs/mcp.md`.
- Kept on purpose: Pi's MCP sign-in flow and token store remain authoritative; the no-operation case continues to reject browser opening.
- Deviations: None.

### P99-17 F · Partial · 2026-09-30 · luna-worker

- Result: Fixed codemode nested-call icon parity (per-tool kind), added an explicit disclosure chevron, changed the bounded omission note to plain language, and applied the attention/warning color to MCP sign-in-needed status while keeping failures red. Replaced hand-drawn MCP list/project, Extensions, TypeSafe-provider and tool-chip scenes with mounted production settings screens and `ToolCard` using a local fake Gateway transport. Invalid codemode `terminal.2` SF Symbol corrected to supported `terminal`. P99-17 remains Claimed.
- Evidence: Hosted iOS visual evidence passed 1/1 and ToolDetailPresentationTests passed 35/35 (36 tests total across 2 suites; 17.23 s test execution, 24.41 s runner wall). Full TronMobileTests ran 1,924 tests / 155 suites in 244.80 s and failed `ChatViewScrollHarnessTests.displacedRetainedResume()` and `unifiedResponseAndNotificationSettlement()`; P99-17 B established displaced-resume as a pre-existing wide-harness failure, while the latter load-run failure was not independently triaged here. Capture bundle `packages/ios-app/build/p99-captures/index.json` contains 64 PNGs; screenshots are ignored. All 16 standard-light captures were opened and reviewed; accessibility review was incomplete. `TRON_IOS_TEST_LANE=p9917f` owned the simulator lane.
- Changes: `packages/ios-app/Sources/UI/Chat/ToolDetailSheet.swift`, `ToolDetailPresentation.swift`, `packages/ios-app/Sources/UI/Settings/MCPServersSettingsView.swift`, `packages/ios-app/Tests/UI/Pi099VisualEvidenceTests.swift`, `packages/ios-app/docs/development.md`, and this plan. No protocol/persistence changes.
- Tasks added: none.
- Kept on purpose: MCP needs-sign-in uses the app semantic warning color; error states remain red. Real app components are hosted via disposable fixture Gateway/transport; no production Gateway, user credential, external MCP server, or provider network was used.
- Deviations: The MCP server-detail screen and add-server sheet were not captured; no dedicated server-detail screen exists in the current real settings surface and the capture did not drive the Add Server interaction. TypeSafe capture initially showed a loading state; after adding the fake `model.list` response, the final full-suite capture shows the TypeSafe entry. Some non-targeted picker/routed-model fixtures remain. The full requested all-accessibility review and per-capture screenshot verdict coverage remain incomplete. No iOS code required session scroll-harness changes.
- For the next agent: complete true add-sheet/detail capture through production UI (introduce a real detail surface only if separately approved), review all accessibility captures against the plan, and retain the final capture artifact. Rerun focused settings and full suite after those changes; do not count this handoff as P99-17 completion.

#### Capture review ledger
- `packages/ios-app/build/p99-captures/mcp-servers-global-light-std.png` — Pass: real MCP screen; connection green, sign-in amber, failure red, hierarchy clear.
- `packages/ios-app/build/p99-captures/mcp-servers-global-light-ax.png` — Review pending: capture exists; this variant was not visually inspected.
- `packages/ios-app/build/p99-captures/mcp-servers-global-dark-std.png` — Review pending: capture exists; this variant was not visually inspected.
- `packages/ios-app/build/p99-captures/mcp-servers-global-dark-ax.png` — Review pending: capture exists; this variant was not visually inspected.
- `packages/ios-app/build/p99-captures/mcp-servers-project-light-std.png` — Pass: real project MCP screen; project scope selector and server states are legible.
- `packages/ios-app/build/p99-captures/mcp-servers-project-light-ax.png` — Review pending: capture exists; this variant was not visually inspected.
- `packages/ios-app/build/p99-captures/mcp-servers-project-dark-std.png` — Review pending: capture exists; this variant was not visually inspected.
- `packages/ios-app/build/p99-captures/mcp-servers-project-dark-ax.png` — Review pending: capture exists; this variant was not visually inspected.
- `packages/ios-app/build/p99-captures/extensions-codemode-tools-light-std.png` — Pass: real Extensions screen; built-in/default-tool controls are visible; list continues by scrolling.
- `packages/ios-app/build/p99-captures/extensions-codemode-tools-light-ax.png` — Review pending: capture exists; this variant was not visually inspected.
- `packages/ios-app/build/p99-captures/extensions-codemode-tools-dark-std.png` — Review pending: capture exists; this variant was not visually inspected.
- `packages/ios-app/build/p99-captures/extensions-codemode-tools-dark-ax.png` — Review pending: capture exists; this variant was not visually inspected.
- `packages/ios-app/build/p99-captures/provider-typesafe-light-std.png` — Pass: real Providers screen exposes the classifier-only TypeSafe entry; 0 chat models is explicit.
- `packages/ios-app/build/p99-captures/provider-typesafe-light-ax.png` — Review pending: capture exists; this variant was not visually inspected.
- `packages/ios-app/build/p99-captures/provider-typesafe-dark-std.png` — Review pending: capture exists; this variant was not visually inspected.
- `packages/ios-app/build/p99-captures/provider-typesafe-dark-ax.png` — Review pending: capture exists; this variant was not visually inspected.
- `packages/ios-app/build/p99-captures/tool-codemode-light-std.png` — Pass: semantic codemode result, per-kind nested icons, titles, chevrons, readable note, attachments and cost.
- `packages/ios-app/build/p99-captures/tool-codemode-light-ax.png` — Review pending: capture exists; this variant was not visually inspected.
- `packages/ios-app/build/p99-captures/tool-codemode-dark-std.png` — Review pending: capture exists; this variant was not visually inspected.
- `packages/ios-app/build/p99-captures/tool-codemode-dark-ax.png` — Review pending: capture exists; this variant was not visually inspected.
- `packages/ios-app/build/p99-captures/tool-codemode-continuation-light-std.png` — Pass: continuation detail keeps semantic output before supporting sections.
- `packages/ios-app/build/p99-captures/tool-codemode-continuation-light-ax.png` — Review pending: capture exists; this variant was not visually inspected.
- `packages/ios-app/build/p99-captures/tool-codemode-continuation-dark-std.png` — Review pending: capture exists; this variant was not visually inspected.
- `packages/ios-app/build/p99-captures/tool-codemode-continuation-dark-ax.png` — Review pending: capture exists; this variant was not visually inspected.
- `packages/ios-app/build/p99-captures/tool-mcp-text-light-std.png` — Pass: query, result and detail summary are readable.
- `packages/ios-app/build/p99-captures/tool-mcp-text-light-ax.png` — Review pending: capture exists; this variant was not visually inspected.
- `packages/ios-app/build/p99-captures/tool-mcp-text-dark-std.png` — Review pending: capture exists; this variant was not visually inspected.
- `packages/ios-app/build/p99-captures/tool-mcp-text-dark-ax.png` — Review pending: capture exists; this variant was not visually inspected.
- `packages/ios-app/build/p99-captures/tool-mcp-image-light-std.png` — Pass: bounded image-result summary and item details are legible.
- `packages/ios-app/build/p99-captures/tool-mcp-image-light-ax.png` — Review pending: capture exists; this variant was not visually inspected.
- `packages/ios-app/build/p99-captures/tool-mcp-image-dark-std.png` — Review pending: capture exists; this variant was not visually inspected.
- `packages/ios-app/build/p99-captures/tool-mcp-image-dark-ax.png` — Review pending: capture exists; this variant was not visually inspected.
- `packages/ios-app/build/p99-captures/tool-mcp-structured-light-std.png` — Pass: structured result summary is legible without raw JSON dump.
- `packages/ios-app/build/p99-captures/tool-mcp-structured-light-ax.png` — Review pending: capture exists; this variant was not visually inspected.
- `packages/ios-app/build/p99-captures/tool-mcp-structured-dark-std.png` — Review pending: capture exists; this variant was not visually inspected.
- `packages/ios-app/build/p99-captures/tool-mcp-structured-dark-ax.png` — Review pending: capture exists; this variant was not visually inspected.
- `packages/ios-app/build/p99-captures/tool-mcp-error-light-std.png` — Pass: failed status and permission error use clear error hierarchy.
- `packages/ios-app/build/p99-captures/tool-mcp-error-light-ax.png` — Review pending: capture exists; this variant was not visually inspected.
- `packages/ios-app/build/p99-captures/tool-mcp-error-dark-std.png` — Review pending: capture exists; this variant was not visually inspected.
- `packages/ios-app/build/p99-captures/tool-mcp-error-dark-ax.png` — Review pending: capture exists; this variant was not visually inspected.
- `packages/ios-app/build/p99-captures/tool-search-light-std.png` — Pass: query and loaded-tools result wrap without horizontal clipping.
- `packages/ios-app/build/p99-captures/tool-search-light-ax.png` — Review pending: capture exists; this variant was not visually inspected.
- `packages/ios-app/build/p99-captures/tool-search-dark-std.png` — Review pending: capture exists; this variant was not visually inspected.
- `packages/ios-app/build/p99-captures/tool-search-dark-ax.png` — Review pending: capture exists; this variant was not visually inspected.
- `packages/ios-app/build/p99-captures/tool-read-mcp-resource-light-std.png` — Pass: resource URI, result and content count are legible.
- `packages/ios-app/build/p99-captures/tool-read-mcp-resource-light-ax.png` — Review pending: capture exists; this variant was not visually inspected.
- `packages/ios-app/build/p99-captures/tool-read-mcp-resource-dark-std.png` — Review pending: capture exists; this variant was not visually inspected.
- `packages/ios-app/build/p99-captures/tool-read-mcp-resource-dark-ax.png` — Review pending: capture exists; this variant was not visually inspected.
- `packages/ios-app/build/p99-captures/tool-technical-details-light-std.png` — Pass: execution metadata and separate Request/Result JSON disclosure hierarchy.
- `packages/ios-app/build/p99-captures/tool-technical-details-light-ax.png` — Review pending: capture exists; this variant was not visually inspected.
- `packages/ios-app/build/p99-captures/tool-technical-details-dark-std.png` — Review pending: capture exists; this variant was not visually inspected.
- `packages/ios-app/build/p99-captures/tool-technical-details-dark-ax.png` — Review pending: capture exists; this variant was not visually inspected.
- `packages/ios-app/build/p99-captures/tool-picker-light-std.png` — Reviewed: existing picker fixture is outside the requested replica replacements; not claimed as a real picker screen.
- `packages/ios-app/build/p99-captures/tool-picker-light-ax.png` — Review pending: capture exists; this variant was not visually inspected.
- `packages/ios-app/build/p99-captures/tool-picker-dark-std.png` — Review pending: capture exists; this variant was not visually inspected.
- `packages/ios-app/build/p99-captures/tool-picker-dark-ax.png` — Review pending: capture exists; this variant was not visually inspected.
- `packages/ios-app/build/p99-captures/tool-chips-light-std.png` — Pass: production ToolCard rows show kind icons, titles and capitalized Completed status.
- `packages/ios-app/build/p99-captures/tool-chips-light-ax.png` — Review pending: capture exists; this variant was not visually inspected.
- `packages/ios-app/build/p99-captures/tool-chips-dark-std.png` — Review pending: capture exists; this variant was not visually inspected.
- `packages/ios-app/build/p99-captures/tool-chips-dark-ax.png` — Review pending: capture exists; this variant was not visually inspected.
- `packages/ios-app/build/p99-captures/routed-physical-model-light-std.png` — Pass: standard/light reviewed; text and hierarchy remain readable.
- `packages/ios-app/build/p99-captures/routed-physical-model-light-ax.png` — Review pending: capture exists; this variant was not visually inspected.
- `packages/ios-app/build/p99-captures/routed-physical-model-dark-std.png` — Review pending: capture exists; this variant was not visually inspected.
- `packages/ios-app/build/p99-captures/routed-physical-model-dark-ax.png` — Review pending: capture exists; this variant was not visually inspected.
