# MCP adapter

Tron owns MCP client connections on the Mac Gateway. The adapter uses the
pinned `@modelcontextprotocol/sdk` `1.25.2` package and pins negotiation to the `2025-11-25` protocol revision.
Older revisions are rejected rather than silently changing the feature
contract. It currently
exposes **tools only** through the existing Pi runtime extension registration
boundary. Resources, prompts, elicitation, sampling, tasks, completions, and
MCP Apps are unsupported and are not advertised or used as an authority.

## Connection and authentication

An MCP connection is a normal ConnectionOwner instance. HTTP setup stores an
explicit endpoint and local stdio setup stores an executable, arguments, and
optional working directory. Setup completes with an opaque credential
reference; the credential value is read only by the Mac credential owner. HTTP
credentials are sent as a bearer header. Stdio credentials are supplied only
as `TRON_MCP_TOKEN` to the explicitly trusted child. Token refresh and OAuth
consent are not implemented; setup must not claim OAuth support.

HTTP endpoints are HTTP(S), contain no embedded credentials or fragments, do
not follow redirects, and cannot make requests outside the configured endpoint
origin/path. Stdio uses direct `spawn` arguments (no shell), the SDK's safe
environment allowlist plus explicitly configured variables, bounded stderr,
and exact transport shutdown. A trusted executable is not a sandbox.

## Discovery and calls

Tool discovery is bounded to 128 tools. Names are prefixed with the connection
instance (`mcp_<instance>_<server-tool>`) and collisions fail admission rather
than replacing provenance. Schemas, descriptions, progress, content, and
results are bounded and treated as untrusted. A changed server tool list is
not silently granted to an already loaded runtime; an explicit runtime reload
rediscovers and admits the candidate set.

Every accepted call is tracked by `GatewayWorkRegistry`, carries the exact
session/runtime host fence, and passes cancellation/deadline to the SDK.
Cancellation does not prove rollback. If a non-read-only call can no longer
prove whether the remote request landed, Tron reports an unknown outcome and
does not replay it automatically. Resource content is not turned into a
second read capability.

Tests use isolated HTTP and stdio fixtures. They do not validate a real private
server, OAuth provider, live credential, or Gateway activation.
