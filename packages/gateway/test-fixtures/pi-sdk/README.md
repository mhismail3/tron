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
  key), `mcp.json` (a hyphenated stdio server exposed directly and a hyphenated
  OAuth-protected HTTP server exposed as deferred, so tool search has something
  to load), `mcp-auth.json` (Pi's OAuth credential store, keyed the way the
  recording SDK keys it), and `sessions/` — the canonical sessions under Pi's own
  file names.
- `corpus/manifest.json` — the Tron-level observation of that corpus reopened
  from a staged copy: the transcript projection, the resolved active tools with
  their exposures per session, the resolved model, the MCP servers' tool names
  and each saved provider key's status.

The recorded session covers every shape this layer claims, and both the recorder
and the test assert that from the JSONL rather than from this list:

| Shape | Where it lives |
|---|---|
| session header, `model_change`, thinking-level change | the session's own setup entries |
| Tron invocation receipts | `custom` entries with `customType: "tron.chat-invocation.v1"` |
| the per-chat tool selection | the first system message's `toolsAdded` |
| a user image | the first user message's image content block |
| a direct hyphenated MCP tool call | a `toolResult` naming `mcp__corpus_mcp__echo` |
| codemode nested calls | the `codemode` `toolResult`'s `nestedCalls` (a successful call) |
| a tool-search loadout delta | the `tool_search` result's `details.loaded`, and the later system message that declares the loaded tool |
| the searched tool called afterwards | a `toolResult` naming `mcp__corpus_oauth__echo` |
| `context_edit`, compaction | their own canonical entries |
| a sibling branch | two entries sharing one parent |

`src/sessions/pi-persisted-state-corpus.integration.test.ts` reopens the corpus
with the **installed** SDK and compares it against the manifest. For a differential
reopen of a prior corpus outside the worktree, set
`TRON_PI_PERSISTED_STATE_CORPUS_DIR` to that corpus directory; the same assertions
then compare its recorded manifest with the current SDK's observations.

Absolute host paths, the Node installation, the fixture paths, the live MCP port
and the extension owner ids (a sha256 of an extension's source and resolved path)
are stored as tokens; staging rebinds the environment values to the machine
running the test. Nothing else is rewritten — the session files keep Pi's own
names and header ids — and the corpus contains no personal data: only synthetic
keys, synthetic tool output and synthetic images.

Regenerate with `npm run record:pi-corpus` in `packages/gateway`, using the
**outgoing** SDK *before* an upgrade, so the upgrade is then tested against state
the previous SDK actually wrote. See `packages/gateway/README.md`, "Pi SDK
maintenance". Regenerating rewrites Pi's generated entry ids, timestamps and
tool-call ids, so a regeneration diff is total by construction; the test result,
not the diff, is what reports an SDK delta.

## Legacy session formats

`v1.jsonl` (the implicit parent chain and `firstKeptEntryIndex`) and `v2.jsonl`
(explicit tree ids and the legacy `hookMessage` role) are hand-authored, minimal
pre-v3 sessions. `src/sessions/pi-session-compatibility.test.ts` asserts Pi still
migrates both to the current format with the same model context. The corpus
cannot cover this: the Gateway only writes the current format, so nothing else
would notice an SDK that stopped reading an old user's session.

## Rollback probe

The rollback probe (`packages/gateway/scripts/pi-session-compatibility-probe.mjs`,
driven by `packages/gateway/scripts/check-pi-sdk-rollback.mjs`) writes and rereads
0.99-only payloads through Pi's public `SessionManager` APIs: `codemode-store`,
virtual-model state and `model_change`, tool-search loadout deltas, canonical
`nestedCalls`, and parent `details.tronNested`. It checks that both 0.99.1 and the
0.87.1 reader preserve the JSONL entries, parent result content and structured
content through read/append/reopen cycles. Files are isolated in disposable
directories; they are not a Tron session format.

## Shared fixtures

`mcp-jsonrpc-fixture.mjs` is the stdio/HTTP MCP JSON-RPC server the Gateway
integration tests and the corpus recorder configure; `computer-use-image.ts`
provides synthetic PNG bytes. `test-support/mcp-oauth-fixture.mjs` is the
OAuth-protected streamable-HTTP MCP server the corpus's `corpus-oauth` server
points at; it is a standalone process because the corpus's `mcp.json` names a
command Pi spawns.
