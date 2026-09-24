# Agent-home reference inventory

This inventory is the repository owner record for the Stable agent-home cutover.
It classifies path-bearing `.pi` references by owner; it is not a raw grep dump.
The preflight command is read-only and uses the schemas of the Pi SDK pinned in
`packages/gateway/package.json` and of the runtime-installed `pi-subagents`
package (not a repository dependency).

## Classification

| Class | Repository paths and contract |
| --- | --- |
| Agent-home source | `packages/gateway/src/config.ts` and Gateway bootstrap pass the resolved `agentDir`; `agents/**/*.md`, `settings.json` subagent overrides, and `extensions/subagent/config.json` are cutover inputs. Preflight parses their supported path fields and rejects stale absolute or missing executable references without rewriting bytes. |
| Project-owned | `<project>/.pi/settings.json`, `.pi/agents`, `.pi/skills`, and `.pi/subagents` are project resources/artifacts. They are discovered only from the project cwd and are not part of the user agent-home move. |
| External owner | `pi-agent-browser-native` retains `~/.pi/config/pi-agent-browser-native/config.json`; browser profiles, cookies, Keychain data, and provider credentials remain external capability stores. Agent-home staging does not relocate or rewrite them. The operator-run Mac reinstall/cutover workflow separately backs up the default browser config; it never copies browser profiles/cookies or reads Keychain stores. |
| Migration/history | `~/.pi/agent` examples in cutover docs and old paths in canonical JSONL/session history are historical records. Canonical bytes, logs, archives, and session text are never rewritten by preflight or staging. Derived metadata with stale paths requires explicit owner handling. |
| Package identity | `bin.pi`, `node_modules/.bin/pi`, and pinned Pi package names identify the SDK/payload and are not home references. The SDK version is pinned in `packages/gateway/package.json`; `pi-subagents` is installed at runtime in the agent home. |

## Fixed cutover gap

Preflight now inspects discovered `agents/**/*.md` definitions using Pi
frontmatter semantics: relative extension paths resolve from the definition
file, child-only extensions are kept child-scoped, and `skillPath` resolves
from the definition file. It also checks package-manifest agent directories, supported
`subagents.defaultExtensions` and agent overrides, plus the subagent extension
config's path-bearing fields.
Absolute/home-expanded paths are reported as relocation-sensitive; external
references require an owner decision; relative executable extension paths must
exist in the source home. Diagnostics contain field locations but not values.
The check is bounded by file size, definition count, traversal depth, and the
existing preflight entry limit. It neither expands arbitrary globs nor scans
agent prompt bodies for `.pi` text.

## Coverage exclusions

The repository sweep does not certify live `~/.tron`, `~/.pi`, credentials,
Keychain/browser profiles, private workspace state, generated `dist` output, or
unvendored package implementation. Those remain capability-owned operator
checks. It also does not rewrite historical JSONL or derived sidecars, remove
retired packages from a live install, or activate/restart a Gateway. Operators
must resolve reported external/relocation-sensitive references and independently
prove writer quiescence, backup, package provenance, and fresh/background child
launch before manual cutover.
