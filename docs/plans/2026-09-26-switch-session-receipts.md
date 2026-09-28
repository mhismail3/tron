# Switch-session invocation receipts

- **Started:** 2026-09-26
- **Status:** Active
- **Last updated:** 2026-09-27, S-2 claimed
- **Goal:** A session reached through an extension command's `ctx.switchSession`, `ctx.newSession` or `ctx.fork` opens and projects normally, and the command's invocation receipts belong to exactly one session.

## Goal and constraints

Task R-5 of the session archive plan found this defect. The user decided to
track it separately. It predates the archive work.

- Canonical JSONL stays canonical. There is no second receipt journal and no
  compatibility reader for already-split receipts unless the user approves one.
- Receipt ownership across an identity change is decided: the user chose
  S-1 option 1 on 2026-09-27. A command's receipts stay in the session where
  it started, and it is settled there at Pi's handoff boundary.

## Context

Measured 2026-09-26:

- **Split receipts.** The `/switch` command writes its `start` receipt into the
  originating session's file. Its `transition` receipt goes into the
  switched-to session's file, stamped with that session's ID.
- **Open fails.** Invocation receipts are filtered by session ID, so the
  switched-to session has a continuation receipt with no start receipt.
  `session.open` then fails with
  `internal: invocation receipt has no start receipt`.
- **No snapshot published.** The switch also changes the live identity without
  publishing a snapshot.
- **Not archive state.** It reproduces with a target that has no archive or
  attention records.
- **Owning code:**
  - `invocation-receipts.ts` and `projection.ts` in `packages/gateway/src/sessions/`;
  - the `preserve` rebind in `packages/gateway/src/sessions/runtime-slot.ts`.
- **Existing test.** The archive plan's R-5 case in
  `packages/gateway/src/transport/session-archive.integration.test.ts` already
  drives a real `ctx.switchSession`.

## Tasks

| ID | Status | Scope | Depends on | Owner |
| --- | --- | --- | --- | --- |
| S-1 | Done | Options for receipt ownership across a `preserve` rebind: stamp continuations with the origin session, settle the invocation before the switch, or re-key receipts. Present them to the user | none | session 01a0e513, 2026-09-27 |
| S-2 | Claimed | Implement S-1 option 1 (settle the command in the origin at Pi's handoff boundary) for every command-driven identity change (`switchSession`, `newSession`, `fork`), settle the command's work and marker, and deliver the identity change to clients subscribed to the origin, with real end-to-end tests that open both sessions | S-1 || session 01a0e513, 2026-09-27 |

## Findings

### S-1 findings

Reproduced 2026-09-27 against the real Gateway with the archive suite's
fixture and temporary instrumentation (not committed).

- **One root cause.** Every receipt write stamps `this.id` and appends through
  `this.sessionManager` at write time, and both follow the rebind. The command's
  `start` lands in the origin. The `accepted` transition, written after Pi
  admits the command (by which point the handler has already switched), lands
  in the target with the target's ID.
- **The cascade.** The `publishSnapshot()` that follows the `accepted` write
  rebuilds the target projection and throws `invocation receipt has no start
  receipt`. That aborts the rest of admission, so no terminal receipt is ever
  written (the source holds only `start`, the target only `accepted`), no
  snapshot is published, and `finishCommand` never runs.
- **Durable damage.** The target stays unopenable after a restart. After a
  restart, the origin's crash recovery reports the successful command as
  `outcomeUnknown`.
- **Leaked ownership.** The slot keeps `pendingExtensionCommand` and one
  unsettled `extension-command-prompt-ui` work handle under the origin's ID,
  plus the origin's runtime marker. The work handle is reported as an active
  administrative drain blocker; whether it stalls a drain-aware restart was
  inferred, not run.
- **Not preserve-specific.** An extension command calling `ctx.newSession()`
  reproduces the identical failure. `fork` uses the same `commandActions` path.
- **Clients are stranded.** After the rebind, the slot broadcasts under the
  target's ID, so a client subscribed to the origin receives neither the
  snapshot nor any diagnostic.
- **Exposure.** No installed package or extension calls `switchSession`,
  `newSession` or `fork`. A scan of all 3,477 canonical session files found no
  orphan continuation receipts, so no compatibility reader is needed.
- **Pi's boundary.** Pi's `teardownCurrent` runs `session_before_switch`
  (cancellable) first, then calls `beforeSessionInvalidate` while the outgoing
  session is still valid, then disposes it. Post-replacement work is meant to
  use the `withSession` replacement context; the old `ctx` is stale.

**Options for receipt ownership** (presented to the user; option 1 chosen):

1. **Settle in the origin at the handoff (recommended).** At Pi's
   `beforeSessionInvalidate` boundary, write the command's terminal
   `completed` receipt into the origin with the origin's ID, then retire the
   invocation: clear `pendingExtensionCommand`, settle its work, clear the
   origin marker. Nothing for that invocation is written to the target. Every
   receipt lives in one file, no second writer or schema change is needed, and
   it matches Pi's model. Costs: handler code that runs after the switch is no
   longer attributed to the command, and its errors surface as extension
   errors on the new session. If runtime creation fails after that boundary,
   the origin already records `completed` while the command fails.
2. **Stamp continuations with the origin.** Capture the origin ID at `start`
   and keep writing receipts through the live manager. The target's filtered
   projection ignores them, so it opens, and the terminal reflects the
   handler's true end. Costs: the origin's own file never gets the terminal (it
   still shows `outcomeUnknown` after recovery), the target carries hidden
   foreign records permanently, and receipts for one session are split across
   two files.
3. **Re-key to the target.** At the switch, write a fresh `start` for the
   invocation into the target and continue there. The target transcript shows
   the command that led to it. Costs: it invents a start in a session where the
   command was never submitted, and the origin still needs its own terminal, so
   it is option 1 plus a copy. One invocation ID then has two starts across
   sessions. It is the most complex option. Rewriting existing receipts is ruled
   out by canonical JSONL.

Independent of the choice, S-2 must cover `newSession` and `fork`, settle the
leaked work and marker, and deliver the identity change to origin subscribers.
The R-5 case in `packages/gateway/src/transport/session-archive.integration.test.ts`
names this defect in a comment and should become the regression that opens both
sessions.

## Handoff log

### S-1 · Done · 2026-09-27 · session 01a0e513

- Result: Traced the failure to identity-following receipt writes, with a
  snapshot throw that aborts command settlement. Found the same defect in
  `newSession`. Recorded three ownership options with a recommendation.
- Evidence: Real-Gateway reproductions with temporary instrumentation for
  `switchSession` and `newSession`. They observed the file contents, the thrown
  `publishSnapshot`, the leaked work fact and marker, and open failures before
  and after restart. Read-only scan of 3,477 session files found no orphans.
- Changes: this plan update only.
- Tasks added: none. S-2 is widened to every command-driven identity change.
- Kept on purpose: no code change. The ownership choice belongs to the user.
- Deviations: the plan scoped the defect to the `preserve` rebind; it is
  identity-wide. "No snapshot published" is a consequence of the same throw
  plus origin-scoped subscriptions, not a separate omission.
- For the next agent: wait for the user's option. Keep the plan's rule that no
  compatibility reader is added; none is needed.
