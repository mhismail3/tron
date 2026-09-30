# MCP servers

## Authority and runtime

Pi's built-in MCP extension is the sole MCP client and `mcp.json` is the sole
configuration authority. Global servers are configured in the Gateway's Pi
agent directory; project-level `.pi/mcp.json` is read only when Tron's project
trust decision admits it. Session runtimes use Pi's built-in `mcp`,
`codemode`, and `tool-search` extensions. MCP logs and OAuth credentials remain
under the Pi agent directory; provider credentials are resolved through Pi's
credential mechanisms rather than Tron's ConnectionOwner or mobile projection.

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
and per-tool exposure. MCP uses Pi's `mcp.json` and `mcp-auth.json`; Tron does
not maintain a second server schema or MCP credential store.

## Sign-in relay

Gateway-mediated OAuth sign-in is pending P99-8. Until that work lands, the
Gateway's MCP `openUrl` callback fails closed rather than opening a browser on
the Mac. Pi's pasted-redirect fallback remains available where supported.

The connection loader rejects a persisted MCP instance with an error naming
the instance and directing configuration to Pi's `mcp.json`. The current live
connection store was inspected for this task and contains no MCP instance; no
compatibility migration or dual authority is retained.
