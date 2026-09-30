# MCP servers

## Authority and runtime

Pi's built-in MCP extension is the sole MCP client and `mcp.json` is the sole
configuration authority. Global servers are configured in the Gateway's Pi
agent directory; project-level `.pi/mcp.json` is read only when Tron's project
trust decision admits it. Session runtimes use Pi's built-in `mcp`,
`codemode`, and `tool-search` extensions. MCP logs remain under the Pi agent directory; OAuth credentials are managed by
Pi's built-in credential store. Static bearer tokens entered through Tron are
stored by the Mac Keychain owner, with only a `!command` lookup reference in
`mcp.json`; their values never enter RPC results.

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
Tron does not maintain a second server schema.

## Sign-in relay

Gateway-mediated OAuth sign-in relay is not yet implemented. The MCP
`openUrl` callback currently fails closed rather than opening a browser on the
Mac. Pi's pasted-redirect fallback remains available where supported.

The connection loader rejects a persisted MCP instance with an error naming
the instance and directing configuration to Pi's `mcp.json`. The current live
connection store was inspected for this task and contains no MCP instance; no
compatibility migration or dual authority is retained.
