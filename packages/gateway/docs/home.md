# Tron Home

Tron Home is an opt-in persistent conversation, one per Gateway installation:
`~/.tron` and `~/.tron-dev` each own their own Home. This document owns what
Home does today. It is deliberately narrow: Home is *designatable* and has a
curated runtime, and until the memory, task and request-policy slices land it
appears to clients as an ordinary session. Ordinary sessions are unaffected by
every rule here.

## The record

`<tronHome>/gateway/home/home.json`, written 0600 and published atomically and
durably (temp file, rename, fsync of the file and its directory), holds one
record per installation:

| field | meaning |
| --- | --- |
| `version` | `1`; any other version is not this build's record |
| `homeId` | Stable identity of this installation's Home, generated once |
| `sessionId` | The session that is Home; designation is keyed by this id |
| `generation` | Advances on every profile change (designate, re-enable, disable) |
| `policyRevision` | The curated-profile revision the record was written against |
| `enabled` | Whether Home is currently designated |
| `model` | The fixed physical model Home runs on |
| `createdAt` / `updatedAt` | ISO-8601 instants |

A corrupt, unreadable, or unknown-version record is **preserved and reported as
unavailable** (`home.status` returns `available: false` with a `reason`) and
`home.designate` refuses with a conflict. It is never overwritten or migrated:
an unrecognized record is not evidence that the user has no Home.

## The neutral working directory

`<tronHome>/gateway/home/workspace` is created 0700 on the first designation and
kept empty; nothing else ever writes there. Designation records an explicit
**untrusted** decision for it through `TrustService`, so `requireResolved` never
blocks on an undecided directory and no project resource can load from it. The
runtime profile's `noExtensions`/`noSkills`/`noPromptTemplates`/`noContextFiles`
is the second, independent guard.

## The curated runtime profile

The profile is decided at runtime creation, once per runtime, from the Home
owner's current answer for that session id. A new Home's *first* runtime is
already the Home profile: `RuntimeRegistry.create(cwd, "home")` carries the
profile explicitly, because the record cannot name a session that does not exist
yet.

| | Home | Ordinary |
| --- | --- | --- |
| Extensions | `tron-context-window`, `tron-compaction-policy`, `tron-ask-user`, `tron-display`, `tron-notify`, `tron-home` | every Tron module plus Pi built-ins (codemode, tool-search, MCP) |
| Discovery | `noExtensions`, `noSkills`, `noPromptTemplates`, `noContextFiles` | agent directory and trusted project resources |
| Executable tool allowlist | `ask_user`, `display`, `notify` | the SDK defaults plus Tron's direct bash tool |
| Compaction | disabled per session | canonical policy |
| Model | fixed physical model | any, including virtual routing |
| Cache warming | zero requests | unchanged |

`tron-home` is a first-party module loaded only for Home. It contributes Home's
operating context and is the single answer to the SDK's per-session
`cache_warming_decision`. It is not in `modules.list`, which reports what every
session registers.

The cache-warming exclusion is the mechanism, not a setting: the SDK's warmer
calls the model runtime directly (outside every request wrapper), its decision
listener fails open when a handler throws, and the last handler wins. So Home's
handler returns `{ action: "stop" }` unconditionally and cannot throw, and the
curated profile guarantees no other extension can answer `warm`. The
integration suite proves both halves: Home reports `stopped by extension` and
sends zero warm requests, while an ordinary session in the same Gateway and on
the same model does warm.

MCP is excluded structurally — no MCP extension is loaded for Home — rather than
by omission from the allowlist, because from SDK 1.0.0 an allowlist that names no
`mcp__*` tool keeps MCP tools registered.

Compaction is disabled through the constructor option of the existing
`CompactionOperationPolicy`, which reapplies the per-session overlay from
canonical settings at every idle admission; ordinary sessions and global
settings are untouched. `session.compact` is refused for Home at admission with a
typed conflict, rather than late by the SDK.

The model is resolved once, at designation: the model named in the request, or
this Gateway's default for new sessions. A virtual (routed) model is refused,
because routing runs on the canonical transcript, which the Home profile does
not own. `session.setModel` refuses a virtual model for a Home session too, and
the model is recorded in the record.

## RPCs and capability

`home.v1` is advertised in `hello`/`system.info` when the Gateway has a Home
owner.

- `home.status` is a read with no inference: `{ available, reason?, enabled,
  homeId?, sessionId?, generation?, model?, live }`. `live` reports whether the
  session currently holds a live runtime.
- `home.designate` is a mutation with a command-id receipt. With no record it
  creates the working directory and trust decision, creates a **new** session
  whose first runtime is the Home profile, applies the model, writes the record,
  and returns `{ homeId, sessionId, generation }`. An enabled record is
  idempotent. A disabled record re-enables the same session with
  `generation + 1`.
- `home.disable` is a mutation. It sets `enabled: false` with `generation + 1`;
  the session stays an ordinary session afterwards.

A profile change must take effect before the session's next prompt, so the live
runtime is retired through the registry's idle-eviction path. If the session is
not idle the mutation is refused with a retryable `busy` error and nothing
changes.

## Fork

Designation is keyed by session id, so forking the Home session yields an
ordinary session: it registers the ordinary extensions and tools, uses the
canonical compaction budget, and is not cache-warming excluded. Pi replays the
canonical transcript's declared tool loadout, so the fork starts with the Home
tool set *active* until it is changed — the same per-chat loadout behavior every
session has (`runtime-tool-loadout.integration.test.ts`).

## Diagnostics

The Gateway log carries one record per designation lifecycle outcome:
`home.designated`, `home.enabled`, `home.disabled` (info), and
`home.unavailable`, `home.refused` (warning). `home.status` is the bounded
runtime projection. See [observability.md](observability.md).

## Not built yet

Home has no memory projection, no request-local context seam, no task
coordination, no wake inbox, no iOS surface of its own, and no scheduled or
background work. It is one conversation with a curated runtime. Those are
separately approved slices of the same epic, and none of them changes the rules
above without updating this document.
