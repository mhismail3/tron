# Switch-session invocation receipts

- **Started:** 2026-09-26
- **Status:** Active
- **Last updated:** 2026-09-27, S-1 claimed
- **Goal:** A session reached through an extension's `ctx.switchSession` opens and projects normally, and the switching command's invocation receipts belong to exactly one session.

## Goal and constraints

Task R-5 of the session archive plan found this defect. The user decided to
track it separately. It predates the archive work.

- Canonical JSONL stays canonical. There is no second receipt journal and no
  compatibility reader for already-split receipts unless the user approves one.
- Choosing who owns receipts across an identity change is an architecture
  decision. Present the options to the user before implementing.

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
| S-1 | Claimed | Options for receipt ownership across a `preserve` rebind: stamp continuations with the origin session, settle the invocation before the switch, or re-key receipts. Present them to the user | none | session 01a0e513, 2026-09-27 |
| S-2 | Needs scoping | Implement the chosen option and publish a snapshot on the identity change, with a real `switchSession` end-to-end test that opens the target | S-1 | |

## Handoff log

(No entries yet.)
