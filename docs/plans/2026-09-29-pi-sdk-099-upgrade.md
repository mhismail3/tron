# Pi SDK 0.99 integration and built-in MCP adoption

- **Started:** 2026-09-29
- **Status:** Active
- **Last updated:** 2026-09-29, P99-3
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
| `packages/gateway/src/integrations/mcp-adapter.ts` (303 lines) + test (222) | Official `@modelcontextprotocol/sdk` 1.25.2 client, HTTP endpoint lock, stdio env allowlist, bounded discovery (128 tools), `mcp_<instance>_<tool>` names, per-connection call lane, unknown-outcome reporting |
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
  confidence and score, which Pi returns.
- **D-7 Virtual models: support them.** Selectable in the iOS picker, routed
  physical model shown per response, limits and cost from the physical model.

### Accepted deltas

Adopting Pi's MCP accepts these changes from the adapter's contract: stdio
servers inherit the Gateway environment; HTTP transports follow normal fetch
redirects and reach OAuth authorization servers; results use Pi's bounds and
temp-file truncation; tools default to codemode exposure instead of direct
declaration; a server listed in `mcp.json` needs no separate write approval
several loaded runtimes each run their own stdio server process. Codemode
scripts may call every `direct` tool, including interactive, paid and
subagent tools (D-3). Each accepted delta is documented in `packages/gateway/docs/mcp.md`.

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
| Built-in `codemode`, `tool_search`, MCP extensions (stdio/HTTP, OAuth, `mcp.json`, `registerMcpServer`, `/mcp`, `pi mcp …`) | **Adopt**; delete Tron's adapter and ConnectionOwner MCP generality | P99-6, P99-7, P99-8 |
| Tool API: `exposure`, `namespace`, `annotations`, `outputSchema`/`structuredContent`, `isError` results, `prepareLoadout`, `ctx.executeTool` with `parentToolCallId` and bounded `nestedCalls` | **Adapt**: P99-3 classifies the new API and attributes `prepareLoadout`; nested-call projection, exposure/namespace projections and nested-tool safety remain | P99-3, P99-5, P99-6 |
| Warning when an extension replaces a built-in | **Adapt**: project `LoadExtensionsResult.warnings` in extension/package lists | P99-6 |
| Virtual models (`registerVirtualModel`, routed model, per-physical-model cost, router state entry) | **Adapt** per D-7 | P99-10, P99-15 |
| Sign in with ChatGPT on `openai`; `deviceId` in global settings | **Adapt**: pass `getDeviceId` to `ModelRuntime.login`; redact `deviceId` from settings projection; fixed port 1455 shared with Codex legacy | P99-9 |
| `system` theme default; `#rgb`/`oklch()`/`okhsl()`; `theme.style()`, `theme.colors`, `theme.appearance`; revised dark/light | **Verify/adapt** Tron's RPC baseline theme and process-global helpers | P99-11 |
| Classifier models (`ModelRuntime.classify`, TypeSafe `jev-latest`, inherited Jev on OpenRouter/Cloudflare/Vercel/OpenCode Zen) | **Adopt**: migrate Tron's Jev to `ModelRuntime.classify()` (D-6); codemode `models.classify` inherited | P99-12, P99-20 |
| llama.cpp classifier; llama.cpp context-window fix | **Not applicable**: Tron does not load the llama.cpp built-in (factory not root-exported) | — |
| `fullscreenWheelScrollLines` setting | **Not applicable** (TUI only); not added to the settings projection | — |
| Per-input disposition for `prompt`/`steer`/`follow_up`; `steer()`/`followUp()` return `"handled" \| "queued"` | **Adapt**: handled prompts settle without an agent turn; SDK rejections settle admission through the thrown error; handled items during queue rebuild get completed receipts and are removed from the queued projection | P99-3 |
| `ModelRuntime` image generation and typed model accessors; discriminated extension model lists | **Inherit** (chat reads unchanged); image generation deferred to P99-21 | P99-12, P99-21 |
| pi.dev catalog `types=chat,image,classifier` | **Inherit**; verify refresh and `models-store.json` reload | P99-12 |
| `mcp_servers_change`, `provider_stream_event` | **Classify** `pi-runtime`; no Tron consumer | P99-3 |
| HTML export show/hide toggle for `display: false` messages | **Inherit** through the out-of-process `--export`; verify artifact | P99-17 |
| Claude Sonnet 5.5 (0.99.0); GPT-6.1 Sol and Codex default (0.99.1); Kimi K3 defaults for Fireworks/Together/OpenCode Go | **Inherit**; refresh release-date snapshot; context-window regression | P99-12 |
| Built-in section in `pi config`; `-builtin:<name>` in `extensions`; SDK `builtin: true` | **Adapt**: compose Tron built-ins with `builtin: true`, surface toggles on iOS | P99-6, P99-15 |
| `defaultTools` `+name`/`-name` entries | **Adapt**: settings projection and patch (D-5) | P99-6 |
| codemode `models.classify` cost added to tool result usage; `ctx.executeTool` usage added to the calling result | **Verify** session cost totals include tool-result usage | P99-5 |
| TypeScript 7 / ES2024 build; `tsx` replaced by Node type stripping | **Adapt**: P99-3 resolves its five candidate API integration errors; Node 22.22.0 is the validation runtime | P99-2, P99-3 |
| Startup header/banner and `[Themes]` changes; light/dark detection order; `TERM=*-direct` | **Not applicable** (TUI only) | — |
| OpenAI Codex provider renamed "OpenAI Codex (legacy)" | **Inherit**; iOS shows provider names from the Gateway | P99-9 |
| `builtin:<name>` naming in errors, diagnostics and source info | **Adapt**: agent-instructions and extension diagnostics map `builtin:` sources | P99-6 |
| `--no-extensions` also disables built-ins | **Qualify** `pi-subagents` children that pass `--no-extensions` | P99-14 |
| Tool calls without a renderer show arguments; MCP titled `server/tool` | **Adapt** iOS generic tool card for MCP titles | P99-16 |
| `bash`/`powershell` structured results up to 1 MiB with `truncated`/`full_output_path`; empty output `""` instead of `(no output)` | **Verify/adapt** Tron's bash wrapper and output projection | P99-13 |
| Managed git packages no longer auto-install Pi peers; warning for host modules in `dependencies` | **Qualify** `pi-agent-browser-native` (git); project warnings | P99-14 |
| New sessions persisted at the first user message (#10000) | **Adapted**: forks materialize with retained user entries; catalog parent identity comes from normalized canonical header paths; pre-message receipts persist with the first user message, proven by teardown/reopen integration | P99-4 |
| RpcClient listener fix; X11 clipboard; Finder paste; Kitty images; cursor after exit; `/settings` input; autocomplete fixes; pinned `-e` git refs | **Not applicable** (Tron uses the SDK, not RpcClient or the TUI) | — |
| Provider fixes: Vercel 1-hour cache pricing, `samplingParams`, Mistral GLM and reasoning, OpenAI Fast pricing, OpenCode qwen thinking replay, Responses without `output_index`, OAuth error redirects and busy callback port, Copilot Opus levels | **Inherit**; covered by provider/catalog regressions where Tron owns a seam | P99-12 |
| Footer/bash/`sanitizeBinaryOutput` CPU reductions | **Inherit** | — |
| Family graph: `pi-mcp`, `pi-codemode`, `quickjs-wasi` | **Adapt**: checker admits the new packages at the observed nested `pi-coding-agent` paths; helper tests lock down placement. Payload verification deferred because the bundler performs `npm ci` and publishes generated resources. | P99-2 |

## Tasks

| ID | Status | Scope | Depends on | Owner |
| --- | --- | --- | --- | --- |
| P99-1 | Done | Verify npm latest, activate plan, claim, create isolated candidate worktree | none | orchestrator session, 2026-09-29 |
| P99-2 | Done | Pin 0.99.1 with the helper; admit `pi-mcp`/`pi-codemode` in the SDK checker; rollback baseline 0.87.1; payload verification | P99-1 | luna-worker, 2026-09-29 |
| P99-3 | Done | SDK API adaptations: manifest, tool context, prompt/steer/follow-up dispositions, attribution of `prepareLoadout`, `deviceId` redaction | P99-2 | luna-worker, 2026-09-29 |
| P99-4 | Done | Session materialization at first user message (#10000): tests, ownership, durability docs | P99-2 | luna-worker, 2026-09-29 |
| P99-5 | Ready | Nested tool calls, `isError` and structured results through live and canonical projections and protocol | P99-3 | Unassigned |
| P99-6 | Ready | Compose Pi built-ins (codemode, tool search, MCP) in sessions and admin loads; codemode reach policy; `defaultTools` | P99-3, P99-5 | Unassigned |
| P99-7 | Ready | Delete Tron's MCP adapter, `@modelcontextprotocol/sdk`, ConnectionOwner MCP generality and protocol fields | P99-6 | Unassigned |
| P99-8 | Ready | Gateway MCP administration RPCs and OAuth sign-in relay | P99-6 | Unassigned |
| P99-9 | Ready | Provider auth: Sign in with ChatGPT, device ID, Codex legacy, usage disposition | P99-3 | Unassigned |
| P99-10 | Ready | Virtual models on the Gateway (D-7) | P99-3 | Unassigned |
| P99-11 | Ready | Theme default and remote extension host rendering | P99-3 | Unassigned |
| P99-12 | Ready | Catalog, provider and classifier deltas; release dates; K3 policy | P99-2 | Unassigned |
| P99-13 | Ready | `bash` structured output and empty-output change | P99-3 | Unassigned |
| P99-14 | Ready | Qualify installed packages and subagent children against 0.99 | P99-6 | Unassigned |
| P99-15 | Ready | iOS settings: MCP Servers screen, built-in toggles, default tools; remove old MCP UI and models | P99-7, P99-8 | Unassigned |
| P99-16 | Ready | iOS chat: codemode, nested calls, MCP and tool-search cards, routed model display | P99-5, P99-10 | Unassigned |
| P99-17 | Ready | Docs, observability, full validation, E2E artifacts, rollback matrix, payload | P99-2 … P99-16, P99-20 | Unassigned |
| P99-18 | Ready | Integration to `main` (user approval), manual acceptance gates, close-out | P99-17 | Unassigned |
| P99-20 | Ready | Migrate Tron's Jev client, tool, assessments and session-search ranking to `ModelRuntime.classify()` (D-6) | P99-12 | Unassigned |
| P99-19 | Needs scoping | Upstream requests: root-export MCP config helpers (retires the D-1 patch writer); structured per-session MCP status (user authorizes filing) | P99-8 | Unassigned |
| P99-21 | Needs scoping | Image generation through `ModelRuntime.generateImages()` as a Tron capability | P99-12 | Unassigned |

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

`packages/gateway/src/sessions/semantic-ui-broker.ts` calls
`initTheme(undefined, false)`, which now selects the `system` theme (grey until
terminal colors arrive, and the Gateway has no terminal). Pin the process-global
theme to the previous effective baseline, then compare captured remote-widget
frames and markdown helper output before and after; any color change is a
behavior-delta stop. Confirm `theme.style()`, `theme.colors` and
`theme.appearance` work on the RPC baseline `Theme`, and update the theme rows
in the manifest.

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
- Model pinning: Tron pins `jev-1.13.0` with qualified pricing. If Pi's catalog
  offers only `jev-latest`, decide with the user whether to accept it or define
  the pinned model in `models.json`.
- `jev` tool output changes to Pi's answers (`bool` probability; score without
  legend/probabilities); update its description. Knowledge assessment output and
  recorded usage keep their current shape.
- Evidence: fake-credential wire capture that the request matches the current
  client's (`noul` on the wire); assessment and session-search regressions;
  iOS provider settings show TypeSafe.

### P99-13 — `bash` structured output

Tron replaces `bash` with the `DirectBashProcessOwner` definition in
`packages/gateway/src/sessions/direct-bash-process-owner.ts`; it spreads Pi's
definition, so it inherits `outputSchema`. Prove that codemode receives
`{ output, truncated, full_output_path?, exit_code, wall_time_seconds }` through
Tron's `BashOperations`, that process-tree ownership and abort still hold for
nested bash calls, and that empty output (`""` instead of `(no output)`)
renders correctly on iOS.

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
  `model_change` to a virtual model, `tool_search` loadout deltas and
  `nestedCalls` must open under 0.87.1 without data loss; extend
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
  from Needs scoping to Ready) and stays Proposed and uncommitted for the
  user's review.
- Changes: this file only.
