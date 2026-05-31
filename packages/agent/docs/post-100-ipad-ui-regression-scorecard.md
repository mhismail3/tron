# Post-100 iPad UI Regression Scorecard

Status: future scorecard

Created: 2026-05-31

Initial score: **0/100**

Current score: **0/100**

This scorecard owns iPad-specific follow-up coverage that was explicitly moved
out of `post-100-operating-conditions-scorecard.md` when that plan closed with
iPhone-only simulator scope. It must run in a separate session/plan with real
iPad Simulator evidence and the same server/DB truth discipline used by the
closed post-100 scorecard.

## Scope

- Target only iPad layouts, split-view/sidebar behavior, detents, popovers,
  pointer/keyboard affordances, and wider-viewport visual/accessibility issues.
- Do not reopen iPhone-pass criteria unless an iPad bug proves a shared
  rendering/state-projection defect.
- Use Computer Use against the iPad Simulator for visible workflows.
- Record server DB truth for every action-bearing scenario: invocations, logs,
  sessions, worktrees, notifications, approvals, resources, queues, and leases.
- Preserve the same destructive-action confirmation policy: archive, delete,
  reset, unsubscribe, submit, and external-send clicks need action-time user
  confirmation.

## Scenario Ledger

| ID | Scenario | Raw Points | Status | Required Evidence |
|---|---|---:|---|---|
| IPD-0 | Harness and baseline | 5 | pending | iPad Simulator UDID/app bundle/server PID, `/health`, DB no-error classification, screenshot path, and focused iPad `xcodebuild` smoke. |
| IPD-1 | Dashboard/sidebar session cards | 12 | pending | Plain, forked, dirty, isolated, fork+dirty, processing, long-title/path, empty state, tap-open, archive context action, icon contrast, and sidebar preload after relaunch. |
| IPD-2 | Chat and engine parity | 12 | pending | Prompt send, streaming response, capability cards, approval pending/resolved sheets, reconnect/relaunch/deep-link parity, and DB event ordering. |
| IPD-3 | Input, attachments, voice notes | 8 | pending | Text send, queued prompt, stop, attachment add/remove, skills popup, voice-note available/unavailable/record/cancel/submit states on iPad. |
| IPD-4 | Notifications | 8 | pending | Bell count, list/detail, mark read, mark all read, session-scoped read, offline failure, badge clearing, and notification deep link in split view. |
| IPD-5 | Capability, approval, generated UI | 10 | pending | Detail sheets/popovers, approve/deny/double-tap, read-only terminal approvals, generated UI render/refresh/submit/stale action rejection. |
| IPD-6 | Source control and worktree | 10 | pending | Agent Control source-control card, dirty/diff rendering, commit/push/rebase/merge/pull/conflict resolver, disabled destructive actions, and DB policy truth. |
| IPD-7 | Settings, providers, pairing | 8 | pending | Settings grid/sidebar behavior, server unavailable/retry, pairing/onboarding from Settings, providers/OAuth status, model picker, protected branches, and profile/auth truth. |
| IPD-8 | Navigation, deep links, session tree | 8 | pending | Sidebar selection, back behavior, session/capability/event/notification deep links, load-earlier pagination, history/fork sheet, cold-start routing. |
| IPD-9 | Visual QA and accessibility | 12 | pending | Light/dark mode, large accessibility sizes, keyboard/pointer focus, no clipped controls, no overlapped text, and stable fixed-format UI dimensions. |
| IPD-10 | Closeout | 7 | pending | Score reaches 100/100 or every residual item is moved to a newer scorecard with evidence and explicit ownership. |

## Linked Source

The closed iPhone/mac operating scorecard is
`packages/agent/docs/post-100-operating-conditions-scorecard.md`. Its iPad
deferrals are no longer open loops there; they are tracked by the IPD rows
above.
