# Work plans

This folder holds work that spans more than one agent session. A plan is a
living record of the work: any agent can pick it up, and every agent that works
on it updates it with what was done, what came up and what is left. Work one
agent can finish in one session needs no plan; it ships with a clear commit
message. Investigation findings are answered in chat, not written here.

The folder contains only:

- **Proposed and active plans**, one file each, named `YYYY-MM-DD-<slug>.md`.
- [HISTORY.md](HISTORY.md), one short entry per finished or abandoned plan.
- This README, the only copy of the template and protocol.

Plans never describe current behavior. The code and the owning docs do (see
Documentation ownership in `AGENTS.md`).

## Naming

`YYYY-MM-DD-<slug>.md`

- The date is the day the plan started. It never changes, so files sort
  chronologically.
- The slug is two to five lowercase words joined by hyphens, naming the outcome
  (`2026-09-23-observability-foundation.md`), not the activity.

## Template

Every plan uses these sections in this order. Sections marked optional may be
left out; the others are required.

````markdown
# <Title>

- **Started:** YYYY-MM-DD
- **Status:** Proposed | Active | Paused (reason)
- **Last updated:** YYYY-MM-DD, <task ID>
- **Goal:** <one sentence>

## Goal and constraints

<The outcome, why it matters, and the rules that override an agent's own
judgment for this plan. Lead with what must not change.>

## Context (optional)

<Current state and evidence an agent needs before starting: measurements, maps,
incidents. Dated, because it goes stale.>

## Plan rules (optional)

<Plan-specific definitions, bars and templates, such as what counts as a finding
or how a task type is carried out.>

## Tasks

| ID | Status | Scope | Depends on | Owner |
| --- | --- | --- | --- | --- |
| <ID> | Ready | <one line> | <IDs or none> | <session, date> |

## Task details (optional)

### <ID> — <title>

<Owning files, acceptance criteria, focused tests, rollout notes.>

## Findings (optional)

### <task ID> findings

<Lists too long for the task table. Remove a findings block once every task it
produced is Done.>

## Handoff log

### <task ID> · <Done | Blocked> · YYYY-MM-DD · <session>

- Result: <one or two sentences>
- Evidence: <tests run with pass counts and wall times; manual checks; negative controls>
- Changes: <commit, or "none">
- Tasks added: <IDs>
- Kept on purpose: <what was examined and deliberately kept, with the reason>
- Deviations: <where the work differed from the plan, and why>
- For the next agent: <next steps, traps, open questions for the user>
````

**Plan statuses**

- **Proposed:** drafted and awaiting the user's approval. The drafting agent
  writes the file, gives the user its path and does not commit it. Its tasks
  cannot be claimed.
- **Active:** approved and committed; tasks can be claimed. Approval is the
  commit that sets this status.
- **Paused:** approved, but no task may be claimed until the reason is resolved.

A rejected proposal is deleted without a history entry.

**Task statuses:** Ready, Needs scoping, Claimed, Blocked, Done. Rows are kept in
priority order. Task IDs are never reused.

**Paths to files that do not exist yet:** `scripts/check-documentation-policy.py`
verifies every repository path written in backticks. Name a future file by
its directory and bare file name, for example "new `gateway-main.ts` in
`packages/gateway/src/`". A plan's paths stay checked, so renames and deletions
elsewhere surface as a failing check.

## Protocol

1. **Pick a task.** In an Active plan, take the first Ready row whose
   dependencies are all Done, unless the user assigned you one.
2. **Claim it on `main`.** Set Status to Claimed and Owner to your session name
   and the date. Commit only that change directly to `main` with the message
   `plan(<slug>): claim <ID>`. If the commit conflicts, another agent claimed
   first: pull and pick again. Claim one task at a time.
3. **Work on a branch.** Do the task in its own worktree and branch.
4. **Update the plan in the same commit as the work.** The row's status, the
   handoff entry, any new task rows and any findings block ship with the change
   they describe. A plan on `main` therefore always matches the code on `main`.
5. **Record what really happened.** Deviations, surprises and things you kept
   on purpose matter more than restating the plan.
6. **Grow the plan.** Add every task you discover as a row in priority order,
   with its parent and dependencies. Anything outside your task's scope becomes
   a row, not an unplanned change.

**Shared-editing rules**

- Never rewrite another agent's handoff entry or a Done row. Correct it with a
  new entry that names the one it corrects.
- A Claimed row with no handoff after 48 hours is stale. Reset it to Ready and
  say so in a handoff entry.
- If a plan rule is wrong, do not work around it silently. Propose the change
  in a handoff entry for the user.

**Stalled plans:** a plan with no handoff for 30 days is reviewed with the user.
It is either resumed, re-scoped or closed as abandoned.

## Closing a plan

In one commit:

1. Every task row is Done, or dropped with its reason in a handoff entry.
2. Lasting knowledge moves to the docs that own it: contracts, invariants,
   rules and the reasons behind decisions go to package docs, READMEs or
   `AGENTS.md`.
3. Append an entry to [HISTORY.md](HISTORY.md).
4. Delete the plan file. Its full text stays in git history, and the history
   entry names the commit that deleted it.
