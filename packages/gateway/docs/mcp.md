# MCP servers

## Authority and runtime

Pi's built-in MCP extension is the sole MCP client and `mcp.json` is the sole
configuration authority. Global servers are configured in the Gateway's Pi
agent directory; project-level `.pi/mcp.json` is read only when Tron's project
trust decision admits it. Session runtimes and session-free extension discovery compose Pi's built-in
`mcp`, `codemode`, and `tool-search` factories from the same Gateway-owned list.
MCP logs remain under the Pi agent directory; OAuth credentials are managed by
Pi's built-in credential store. Static bearer tokens entered through Tron are
stored by the Mac Keychain owner, with only a `!command` lookup reference in
`mcp.json`; their values never enter RPC results. Each loaded runtime maintains
its own MCP connections, including one stdio server process per configured
active stdio server in that runtime; this is not a process shared across session
runtimes.

MCP setup, sign-in, and server management are not part of Tron's provider
connection store. Adding a server to the trusted configuration is the user
approval for its tools. A server configuration change is read on runtime load;
existing sessions may need reload or a new session to pick it up.

## Accepted boundary changes

Pi MCP replaces Tron's retired adapter. The following differences are
intentional: stdio servers inherit the Gateway environment; HTTP follows normal
fetch redirect behavior and may contact OAuth authorization servers; Pi applies
its message and model-text truncation bounds (with full text in a temporary
file); tools default to codemode exposure rather than direct declaration; and
multiple loaded runtimes can each launch their own stdio server. Codemode can
call every direct Tron tool, including interactive and paid tools; each Tron
tool owns its existing limits and nested-call behavior.

Pi supports stdio and streamable HTTP, OAuth/PKCE, dynamic client registration,
refresh, server instructions, resources, progress, logging, structured results,
and per-tool exposure. MCP uses Pi's `mcp.json` and `mcp-auth.json` for server and OAuth configuration;
Tron does not maintain a second server schema. Runtime fixture coverage for
stdio/HTTP exposure, resource reads, `list_changed`, lazy reconnect, and process
group cleanup lives in `src/sessions/runtime-registry.integration.test.ts`.
The explicit admin status command's bounded startup/config diagnostics are
covered by `src/admin/mcp-admin-service.test.ts`; sign-in relay outcomes and
callback safety are covered by `src/admin/auth-broker.test.ts` and the local
OAuth fixture in `src/admin/mcp-auth.integration.test.ts`.

## Sign-in relay

`mcp.auth.start` accepts `{ sessionId, server, commandId }` and executes Pi's own
`/mcp login <server>` command through the session's regular prompt admission.
`mcp.auth.cancel` accepts `{ operationId }`. Auth operations belong to the
authenticated device and target `{ kind: "mcp", sessionId, server }`; auth
resume replays the latest event or pasted-redirect prompt, and the shared
15-minute timeout/cancel/tombstone rules apply. Session close and runtime
teardown cancel operations for that session.

The per-session `openUrl` hook is bound to the active Tron-started operation.
Pi's authorization URL is delivered as the existing `auth.event` shape, with a
callback capture derived exclusively from its provider-authored loopback
`redirect_uri`. A callback submitted by the phone is relayed only to that
loopback listener; Tron does not select or accept a client-supplied destination.
The adapter routes Pi's pasted-redirect `ctx.ui.input` to the same auth prompt.
Outside a Tron operation, MCP `openUrl` fails closed and never launches a Mac
browser. Relay outcomes are recorded without URLs, callback queries, codes or
tokens.

The connection loader rejects a persisted MCP instance with an error naming
the instance and directing configuration to Pi's `mcp.json`. The current live
connection store was inspected for this task and contains no MCP instance; no
compatibility migration or dual authority is retained.
