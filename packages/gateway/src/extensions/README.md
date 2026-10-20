# gateway/extensions

## Purpose

How Pi extensions run inside the Gateway: Pi's built-in extension composition, Tron's
first-party module list, the compatibility inventory of Pi's extension API, extension
ownership attribution, semantic forms and the remote extension UI host.

## Owns

`pi-builtins.ts`, `tron-modules.ts` (`TRON_MODULES`), `compatibility-manifest.ts`,
`owner-attribution.ts`, `managed-producer.ts`, `extension-adapters.ts`,
`semantic-form.ts`, the `tron-ask-user` extension and `host/` (remote extension host,
component registry, presentation store, terminal sanitizer).

## Contract

- **Pi built-ins.** `RuntimeSlot` composes Pi's `codemode`, `tool-search` and `mcp`
  extension factories (`piBuiltinExtensions`) for session runtimes, and session-free
  hook/package loads use the same composition; the SDK does not load them itself.
  Scoped `-builtin:<name>` settings enable each. MCP can activate codemode or
  tool-search for its exposure even when neither is a `defaultTools` entry. Pi's MCP
  extension is the only MCP client ([MCP](../../docs/mcp.md)).
- **`modules.list`** reports Tron's built-in modules for Settings without a session:
  one row per `TRON_MODULES` entry (name, purpose, tool and command names), the same
  definition `RuntimeSlot` registers, so the list cannot disagree with a session.
  `tron-invocation-settlement` comes first and has no tools or commands.
- **Session-free inventory** (served by admin's package and hook services with this
  composition): `hooks.list` (`hooks.v1`) returns the hook fields `session.resources`
  returns for one scope. No `cwd` is the global scope against an untrusted home;
  a `cwd` loads project extensions only while the canonical trust decision is true,
  re-read during the load. It never starts a session or replays provider
  registrations, serializes on one mutex as drain-aware admin work, and is bounded
  to 256 KiB (an extension-module load cannot be cancelled, so no deadline is
  claimed). `packages.list` adds per package what it `provides` (skills, prompts,
  themes, subagents, tools, commands; at most 256 per kind, partial results with one
  `providesDiagnostic`) and `nodeRequirement {range, runtime, status}` from
  `engines.node`, judged against the running Node: a warning, never a refusal.
- **Compatibility inventory.** `compatibility-manifest.ts` classifies every Pi
  extension API member at compile time
  ([Pi SDK maintenance](../../docs/pi-sdk-maintenance.md#candidate-review)).
- Extension void presentation callbacks are transactional best effort: malformed or
  over-budget updates are rejected, never an uncaught exit.

## Invariants

- One definition (`TRON_MODULES`) feeds both registration and `modules.list`.
- Project extension code loads only under a true canonical trust decision.
- Reserved tool names (`subagent`, `notify`) belong to their build-bound owners.

## Entry points

`piBuiltinExtensions`, `TRON_MODULES`, the remote host in `host/`.

## Signals

None of its own; extension artifact and discovery records are rows of
[gateway/run](../sessions/README.md#signals).

## Verify

```bash
scripts/tron verify --module gateway/extensions
scripts/tron test gateway src/sessions/tron-modules.integration.test.ts \
  src/admin/package-node-requirement.integration.test.ts
```

## Not here

- Extension activity and history: [delegated-activity.md](../../docs/delegated-activity.md).
- Package install and trust: [admin](../admin/README.md).
- Managed `pi-subagents`: [Pi SDK maintenance](../../docs/pi-sdk-maintenance.md#tron-owned-pi-subagents-build).
