# Pi session fixtures

## Persisted-state upgrade corpus (`corpus/`)

`corpus/` is the committed persisted-state corpus for the Pi SDK upgrade
boundary (epic #468, layer L1). It is **generated**, never hand-authored: the
recorder drives the real Gateway — `RuntimeRegistry` with the faux provider,
Pi's own MCP fixture servers, Tron's `SettingsService`, `AuthBroker` and
`GatewayService` — under the **installed** Pi SDK and writes the state Tron and
Pi actually persist.

- `corpus/agent/` — a canonical Pi agent directory: `settings.json` (default
  provider/model, enabled models, thinking budgets, default tools, scoped
  built-in extension settings, compaction), `auth.json` (a synthetic provider
  key), `mcp.json` (a hyphenated stdio server and a hyphenated OAuth-protected
  HTTP server), `mcp-auth.json` (Pi's OAuth credential store, keyed the way the
  recording SDK keys it), and `sessions/` — the canonical sessions, covering tool
  calls (including a hyphenated MCP server's tools), codemode nested calls,
  tool-search loadout deltas, a per-chat tool selection, images, `context_edit`,
  compaction, `model_change`, thinking-level changes and a sibling branch.
- `corpus/manifest.json` — the Tron-level observation of that corpus reopened
  from a staged copy: the transcript projection, the resolved active and
  available tools per session, the resolved model, the MCP servers' tool names
  and each saved provider key's status.

`src/sessions/pi-persisted-state-corpus.integration.test.ts` reopens the corpus
with the **installed** SDK and compares it against the manifest.

Absolute host paths, the Node installation, the fixture paths and the live MCP
port are stored as `«corpus-…»` tokens; staging rebinds them to the machine
running the test. Nothing else is rewritten, and the corpus contains no personal
data — only synthetic keys, synthetic tool output and synthetic images.

Regenerate with `npm run record:pi-corpus` in `packages/gateway`, using the
**outgoing** SDK *before* an upgrade, so the upgrade is then tested against state
the previous SDK actually wrote. See `packages/gateway/README.md`, "Pi SDK
maintenance". Regenerating rewrites Pi's generated entry ids, timestamps and
tool-call ids, so a regeneration diff is total by construction; the test result,
not the diff, is what reports an SDK delta.

## Rollback probe

The rollback probe (`packages/gateway/scripts/pi-session-compatibility-probe.mjs`,
driven by `packages/gateway/scripts/check-pi-sdk-rollback.mjs`) writes and rereads 0.99-only payloads through
Pi's public `SessionManager` APIs: `codemode-store`, virtual-model state and
`model_change`, tool-search loadout deltas, canonical `nestedCalls`, and parent
`details.tronNested`. It checks that both 0.99 and the 0.87.1 reader preserve the
JSONL entries, parent result content and structured content through
read/append/reopen cycles. Files are isolated in disposable directories; they are
not a Tron session format.

## Shared fixtures

`mcp-jsonrpc-fixture.mjs` is the stdio/HTTP MCP JSON-RPC server the Gateway
integration tests and the corpus recorder configure; `computer-use-image.ts`
provides synthetic PNG bytes. `test-support/mcp-oauth-fixture.mjs` is the
OAuth-protected streamable-HTTP MCP server the corpus's `corpus-oauth` server
points at.
