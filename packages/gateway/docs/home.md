# Tron Home

Tron Home is an opt-in persistent conversation, one per Gateway installation:
`~/.tron` and `~/.tron-dev` each own their own Home. This document owns what
Home does today: its designation record, its curated runtime, its memory, and the
request seam that sends each activation the memory's view instead of the
canonical transcript. Tasks, the wake inbox and Home's own client surface are
later slices. Ordinary sessions are unaffected by every rule here.

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
| `policyRevision` | The curated-profile revision in force; a re-enable writes this build's |
| `enabled` | Whether Home is currently designated |
| `model` | The model applied at the last designation, updated when the Home session's model changes |
| `createdAt` / `updatedAt` | ISO-8601 instants |

The file is read with the Gateway's owner-only JSON boundary: a missing file
means no designation, while a **malformed, empty, symlinked, oversized or
group/world-readable** one is **preserved and reported as unavailable**
(`home.status` returns `available: false` with a `reason`) and `home.designate`
refuses with a conflict. Only `version` gates admission, so a record written
against a newer `policyRevision` is still read, preserved and re-enabled. A
record is never overwritten or migrated: an unusable one is not evidence that
the user has no Home.

## The neutral working directory

`<tronHome>/gateway/home/workspace` is created 0700 on the first designation and
kept empty; nothing else ever writes there. Designation records an explicit
**untrusted** decision for it through `TrustService`, so `requireResolved` never
blocks on an undecided directory and no project resource can load from it. The
runtime profile's `noExtensions`/`noSkills`/`noPromptTemplates`/`noContextFiles`
is the second, independent guard.

## The curated runtime profile

The profile is decided at runtime creation, once per runtime, from the Home
owner's answer for that session id: `home` when the enabled record names it,
`ordinary` when a disabled record names it, and `unnamed` when the record names
another session. A new Home's *first* runtime is already the Home profile:
`RuntimeRegistry.create(cwd, "home")` carries an explicit creation profile,
which applies only to that session and only while the record does not name it —
so a fork or a reset, which produce a new session id, is never Home.

| | Home | Ordinary |
| --- | --- | --- |
| Extensions | `tron-context-window`, `tron-compaction-policy`, `tron-ask-user`, `tron-display`, `tron-notify`, `tron-home` | every Tron module plus Pi built-ins (codemode, tool-search, MCP) |
| Discovery | `noExtensions`, `noSkills`, `noPromptTemplates`, `noContextFiles` | agent directory and trusted project resources |
| System prompt | the agent directory's `SYSTEM.md` and `APPEND_SYSTEM.md` are dropped through `systemPromptOverride`/`appendSystemPromptOverride` | loaded |
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

The model is resolved at designation: the model named in the request, or — only
for a fresh session — this Gateway's default for new sessions. Re-enabling a
disabled Home resolves the request's model, else the one the record was last
designated with, and applies it to the live session through the normal
`session.setModel` path when the live model differs. A virtual (routed) model is
refused at every one of those points, because routing runs on the canonical
transcript, which the Home profile does not own. `session.setModel` refuses a
virtual model for a Home session too, and any model applied to the *enabled* Home
is written back to the record, which is the single source of truth for the model
a re-enable restores. A model applied while Home is disabled is an ordinary
session's change and does not touch the record.

## RPCs and capability

`home.v1` is advertised in `hello`/`system.info` when the Gateway has a Home
owner.

- `home.status` is a read with no inference: `{ available, reason?, enabled,
  homeId?, sessionId?, generation?, model?, live, sessionPresent }`. `live`
  reports whether the session currently holds a live runtime; `sessionPresent`
  reports whether it exists at all — live, or still a canonical session in the
  catalog. A Gateway whose first catalog cut has not completed reports
  `sessionPresent: true`, because an unread catalog cannot prove absence.
- `home.designate` is a mutation with a command-id receipt. With no record it
  creates the working directory and trust decision, creates a **new** session
  whose first runtime is the Home profile, applies the model, writes the record,
  and returns `{ homeId, sessionId, generation }`. An enabled record whose
  session still exists is idempotent. A disabled record re-enables the same
  session with `generation + 1`. A record whose session is **gone** (a session
  that was never written, or was deleted) is kept and given a fresh session with
  `generation + 1`, whether it was enabled or disabled: the record is the only
  evidence of the designation, and the dangling id must not be re-enabled.
- `home.disable` is a mutation. It sets `enabled: false` with `generation + 1`;
  the session stays an ordinary session afterwards. A record whose session is
  gone is only marked disabled.

A profile change must take effect before the session's next prompt, so the live
runtime is **replaced in place** inside the slot's own serialized lane: the idle
check, the durable record write and the rebuild are one critical section, and
prompt admission uses the same lane. The session identity, its subscribers, its
presentation and its (possibly never-persisted) in-memory session manager all
survive. If the session is not idle the mutation is refused with a retryable
`busy` error and nothing changes. A session with no live runtime needs no
rebuild: the next runtime creation reads the record.

## Fork and disable both keep the transcript's tool loadout

Designation is keyed by session id, so forking the Home session yields an
ordinary session: it registers the ordinary extensions and tools, uses the
canonical compaction budget, and is not cache-warming excluded.

A profile change does not rewrite the chat's tool loadout, because Pi replays
the *declared* loadout from the canonical transcript at every runtime creation.
So both a fork of Home and a disabled Home start with the Home tool set
**active** while the ordinary tools are merely registered, exactly as every
other session keeps the loadout its chat declared
(`runtime-tool-loadout.integration.test.ts`). The user restores the ordinary
tools with `session.setTools`, which is the same control every session has; the
integration suite asserts the active set across a disable and that `setTools`
restores it.

## Diagnostics

The Gateway log carries one record per designation lifecycle outcome:
`home.designated`, `home.enabled`, `home.disabled` (info), and
`home.unavailable`, `home.refused` (warning). It also carries one
`home.activation` record per activation (the effective size of the request and how
long it waited for its view), a `home.activation-refused` record for every refusal
with its reason, and the memory's own `episodic.*` records. `home.status` and
`home.context` are the bounded projections. See
[observability.md](observability.md).

## Activations

An **activation** is one admitted input and everything it triggers: its tool loop,
the SDK's retries and continuations, and any steering or follow-up that joins the
same run. It opens at Tron's prompt admission, where the session's canonical leaf
is captured immediately before the input reaches Pi (so the input's own entry, and
every later steering entry, is inside the activation), it is renamed when Tron
transfers the run's owning operation to a dequeued follow-up, and it closes when
Tron settles the operation that owns it.

Every provider request of an activation carries exactly three things:

1. the session's system messages, as they stood before the activation's start,
2. ONE memory view, frozen at the activation's first request (see below), and
3. the activation's own messages, from its start entry onward.

Prior activations are never re-sent, and the memory view is never persisted: a
canonical transcript of the whole conversation stays the only durable history, and
Home's continuity comes from the view. That view is a `custom` message the seam
inserts; `newMessages`, `message_end` and the session JSONL never carry it.

Three wrappers enforce it, all fail-closed (no activation, no provider request,
and the refusal is a canonical assistant error entry the user can read):

| wrapper | where | what it does |
| --- | --- | --- |
| `prepareRequest` | outermost | cuts the request into system messages + memory view + the activation's own messages |
| `transformContext` | outermost | refuses unless the activation's non-system messages survived the SDK's context stages unchanged, then records the single-use digest expectation |
| `streamFunction` | innermost | refuses unless the outgoing request carries the activation nonce exactly once with the recorded digest |

Only a runtime whose profile is Home's gets them. A fork of the Home session is a
different session id, hence an ordinary session with no seam and no activation.

## Memory and readiness

Home owns ONE `EpisodicMemory` ([episodic-memory.md](episodic-memory.md)) over the
Home session's canonical entries, outside the session's runtime so an idle
eviction, a reload or a profile change cannot lose it. The runtime only reports
that canonical entries changed (persisted messages, custom entries, navigation);
the memory re-reads the log after its cursor and builds its tree in the background
under its own bounds.

There are **no defaults** (decision D4). The record's optional `memory` field holds
the model and the token budget: `home.configureMemory` (a command-id-receipted
mutation, `{ model, tokenBudget }`, refusing a virtual or unregistered model and a
budget outside `1…100000000`) writes it, and its result is the same bounded memory
projection `home.status` carries as `memory`. Reconfiguring with the same values
changes nothing and never resets spend; a raised budget resumes a memory that
stopped with `budget-exhausted`, and only the nodes it has not built cost
anything, because the tree is durable. Token spend is persisted with the memory's
state, so a Gateway restart never hands the budget back.

A Home whose memory is unconfigured, blocked, or unable to place the activation's
start entry refuses every activation with a readable reason and makes zero
provider requests. `home.context` is the bounded read for the other side of that:
for Home's current or last activation it returns the activation's start entry id,
whether it is still open, the frozen view's line and byte counts, the effective
token estimate the request was measured at, the model's window, and the last
refusal reason and detail — never a message body and never the view text.

An activation waits for the memory before it sends anything (the recipe's "wait,
don't cut"): the wait covers the lines the view will carry, so an unbuilt line is
never sent, and it is abortable, so the user's Stop cancels it and leaves their
message in the log unanswered. Later steps of the same activation reuse the frozen
text byte-for-byte.

## Not built yet

Home has no task coordination, no wake inbox, no iOS surface of its own, and no
scheduled or background work. It is one conversation whose turns run on its
memory. Those are separately approved slices of the same epic, and none of them
changes the rules above without updating this document.
