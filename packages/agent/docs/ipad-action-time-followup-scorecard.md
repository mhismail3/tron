# iPad Action-Time Follow-up Scorecard

Created: 2026-06-02

Initial score: **0/100**

Current score: **0/100**

Status: **active successor for confirmation-gated iPad action flows**

This scorecard owns the residual manual iPad flows that were deliberately not
executed during the completed Post-Scorecard Gap Hardening Campaign because
they require action-time confirmation, mutate user/session/source-control state,
touch microphone capture, or depend on a live generated-UI surface. The parent
campaign closed the non-mutating layout, projection, sheet, deep-link,
state-machine, deterministic, and read-only evidence in
`post-scorecard-gap-hardening-scorecard.md` and
`post-100-ipad-ui-regression-scorecard.md`.

## Scope

- Execute only the confirmation-gated iPad actions transferred from IPD closeout:
  archive, approval decisions, generated-UI submit/refresh, source-control
  mutations, fork execution, and dedicated Voice Note sheet record/cancel/submit.
- Finish the remaining broad pointer/hardware-keyboard traversal pass that was
  not specific to canonical sheet sizing.
- Use iPad Simulator evidence unless the user explicitly requests physical-device
  proof.
- Preserve action-time confirmation: do not archive, approve, deny, submit,
  refresh, commit, push, pull, rebase, merge, fork, resolve conflicts, record
  microphone audio, or externally send without explicit user confirmation at the
  moment of the action.

Out of scope:

- Canonical iPad sheet sizing/styling standardization. That is closed by the
  parent campaign with source guards and iPad visual evidence.
- Token accounting, provider canaries, Agent Control fast-load, and Source
  Control compact-card projection. Those are closed by the parent campaign.
- Production deployment and pull request creation.

## Evidence Contract

Every passed row must record the iPad target UDID, bundle id, server PID or
health proof, exact UI action sequence, screenshots before and after the action,
DB or engine invocation rows proving the mutation, and whether the user gave
action-time confirmation. Approval, source-control, generated-UI, and fork rows
must also prove idempotency or stale/double-tap behavior when the row requires
it. Voice Note rows must record microphone permission state and avoid saving
real user audio unless the user explicitly confirms it.

## Scenario Ledger

| ID | Scenario | Points | Status | Required Evidence |
|---|---|---:|---|---|
| ATF-0 | Harness and confirmation protocol | 10 | pending | iPad target, bundle id, server health, DB path, screenshot path, and written confirmation protocol for mutating clicks. |
| ATF-1 | Sidebar archive execution | 10 | pending | User-confirmed archive action from iPad sidebar, session archived in DB, row disappears or moves consistently, and unarchive/repair path if needed. |
| ATF-2 | Approval decision flows | 15 | pending | Pending approval sheet on iPad, approve, deny, double-tap/idempotency, resolved read-only state, and `approval::resolve`/child invocation DB proof. |
| ATF-3 | Generated UI submit/refresh/stale rejection | 15 | pending | Live generated-UI surface on iPad, user-confirmed submit and refresh, stale action rejection, `ui::submit_action`/`ui::refresh_surface` DB proof, and no client-authored action policy. |
| ATF-4 | Source-control mutations and conflict resolver | 20 | pending | User-confirmed commit, push/pull/rebase/merge where safe, disabled destructive cases, conflict resolver proof, and worktree/git DB truth for each action. |
| ATF-5 | History fork execution | 10 | pending | User-confirmed fork from iPad History, new session route selected, fork metadata in DB, and source event/session preserved. |
| ATF-6 | Dedicated Voice Note sheet record/cancel/submit | 10 | pending | Voice Note sheet open, unavailable/available states, record, cancel, submit/save path, microphone permission proof, and voice-note/transcription DB or resource evidence. |
| ATF-7 | Remaining pointer and hardware-keyboard traversal | 5 | pending | iPad pointer hover and keyboard traversal across dashboard, sheets, settings pages, Engine Console, Agent Control, and source-control controls without clipped or overlapping UI. |
| ATF-8 | Closeout | 5 | pending | Score reaches 100/100, parent scorecards remain closed, successor evidence is linked, focused tests pass, ledger updated, and no PR is created unless explicitly requested. |

## Transferred Residuals

| Parent Row | Residual | Successor Row | Transfer Reason |
|---|---|---|---|
| IPD-1 | Archive context action execution | ATF-1 | Archive is destructive session state and needs action-time confirmation. |
| IPD-2/IPD-5 | Pending approval approve/deny/double-tap | ATF-2 | Approval decisions execute or deny server-owned authority records and need action-time confirmation. |
| IPD-3 | Dedicated Voice Note sheet record/cancel/submit | ATF-6 | The flow touches microphone capture and can persist audio/transcription resources. |
| IPD-5 | Generated UI submit, refresh, and stale action rejection | ATF-3 | Submit/refresh can invoke canonical capabilities through server-owned generated actions. |
| IPD-6 | Commit, push, pull, rebase, merge, and conflict resolver | ATF-4 | Source-control actions mutate worktrees or remotes and need explicit confirmation. |
| IPD-8 | Fork execution from History | ATF-5 | Fork creates a session immediately from the tapped control. |
| IPD-9 | Remaining broad pointer/hardware-keyboard traversal | ATF-7 | The parent campaign closed prompt, Agent, Agent Control, Engine Console, light/dark, and Dynamic Type evidence; a broader traversal pass remains useful but is no longer part of sheet hardening. |

## Inherited Evidence

The parent iPad scorecard records non-mutating and deterministic proof for these
areas before transfer: archive action discoverability, resolved approval
read-only details, generated-UI inspect/validate, source-control cards and
disabled gating, fork control discoverability and existing fork selection,
voice-note recorder/audio contract tests, prompt and attachment flows,
deep-link/cold-start routing, and pointer/keyboard fixes for the dashboard,
Agent Control, Agent settings, and Engine Console.
