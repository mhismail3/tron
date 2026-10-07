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
`mcp.json`; their values never enter RPC results. The command resolves the
complete `Bearer <token>` header value. This design has an accepted local-user
residual risk: any process running as the macOS user can invoke `/usr/bin/security`
to read a stored bearer token without a prompt. Keychain storage protects the
secret from files and projections, not from other processes running as that user.
Each loaded runtime maintains its own MCP connections, including one stdio server process per configured
active stdio server in that runtime; this is not a process shared across session
runtimes.

MCP setup, sign-in, and server management are not part of Tron's provider
connection store. Adding a server to the trusted configuration is the user
approval for its tools. A server configuration change is read on runtime load;
existing sessions may need reload or a new session to pick it up.

## Accepted boundary changes

Pi 0.99.2 normalizes generated MCP tool identifiers by replacing hyphens in
server names with underscores (`mcp__my-server__tool` becomes
`mcp__my_server__tool`). Tron adopts Pi's spelling as a one-time cutover; there
is no translation shim because the maintainer verified this host has no
persisted hyphenated tool selection or MCP configuration to migrate.

Pi 1.0.0 stores OAuth credentials by server name and URL rather than URL alone.
On rollback from 1.0.4 to 0.99.1, a migrated sign-in is not found and that MCP
server needs authorization again. This is the accepted one-way rollback delta,
recorded as the exact MCP-auth entry in `pi-sdk-baseline.json`.

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
The explicit admin status command accepts Pi's valid JSON output for CLI exit
codes 0 and 1 (the latter reports unhealthy servers) and projects a bounded
wire shape: at most 128 servers, each with `name`, `state`, `scope`, `enabled`,
`exposure`, `transport`, at most 128 tool names, and an optional bounded `error`.
Each string is capped at 256 characters (except `state`, capped at 64); `error`
is stripped of control bytes and capped at 2,048 characters. Filesystem `source`
paths are not exposed. Top-level `errors` is a count, not a copy of Pi diagnostic
objects. The captured pinned CLI payload fixture and startup/config behavior are
covered by `src/admin/mcp-admin-service.test.ts`, which proves the `!command`
header reference through Pi's own CLI against a loopback server that records the
`Authorization` it receives; sign-in relay outcomes and callback safety are
covered by `src/admin/auth-broker.test.ts`, and the local OAuth fixture in
`src/admin/mcp-auth-session.integration.test.ts` drives Pi's own PKCE S256
challenge, dynamic client registration, loopback callback relay, token
persistence and refresh through the Gateway's `mcp.auth.start` operation. That
fixture serves the resource-metadata URL named by `WWW-Authenticate` and not the
well-known root, and asserts the challenge path was fetched while the root was
not: the request log is the proof, because Pi's discovery falls back to the
server origin and would otherwise still sign in. The MCP CLI is located through
the `bin.pi` the package declares rather than a guessed layout. Those tests reach
Pi only through its public exports, so they describe the supported boundary
instead of one installed layout. The sequential rollback matrix
(`packages/gateway/scripts/check-pi-sdk-rollback.mjs`) seeds and rereads
`mcp.json` and `mcp-auth.json` through each runtime's own `pi mcp list`
resolution, so an SDK change that rewrites either store in a way the previous
runtime cannot read is reported before an upgrade lands.

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
The built-in command is identified by Pi's synthetic `builtin:mcp` source path;
its source category is only `builtin`. The RuntimeRegistry integration proves
RPC-to-token-to-direct-tool sign-in, while a chat `/mcp login` without an active
Tron operation fails closed: no auth URL is relayed and no browser opens.
Outside a Tron operation, MCP `openUrl` fails closed and never launches a Mac
browser. Relay outcomes are recorded without URLs, callback queries, codes or
tokens.

The connection loader rejects a persisted MCP instance with an error naming
the instance and directing configuration to Pi's `mcp.json`. The current live
connection store was inspected for this task and contains no MCP instance; no
compatibility migration or dual authority is retained.
