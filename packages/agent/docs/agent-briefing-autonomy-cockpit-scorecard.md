# Agent Briefing And Autonomy Cockpit Scorecard

Status: implementation candidate
Last updated: 2026-07-01

## Scope

This slice adds the first Agent Briefing surface without inheriting the Runtime
Cockpit as a primary dashboard. The dashboard keeps project-grouped sessions and
adds one high-signal briefing band. The full sheet presents narrative sections
with drill-down evidence. Session context/model controls are reframed as Session
Briefing.

## Backend Boundary

`agent_briefing::overview` is intentionally a narrow read-only projection. It
does not own durable state and does not create autonomy behavior. It delegates
to `module_activity::overview` for accepted server-owned activity truth, then
reshapes those already-redacted facts into UI sections so dashboard and full
sheet share identical scope, redaction, empty/degraded state, and evidence
semantics.

The projection remains justified as the minimum server-owned primitive because
the product slice needs one consistent scoped briefing DTO across multiple app
surfaces. Keeping section shaping only in iOS would duplicate scope/redaction
policy and make future non-iOS clients invent their own narrative semantics.

## Acceptance Checks

| Check | Status | Evidence |
| --- | --- | --- |
| Project-grouped sessions preserved | passed | `SessionSidebar` still renders `SessionListWorkspaceGroup.groups(from:)` before session rows. |
| Main dashboard stays thin | passed | Dashboard consumes `AgentBriefingViewModel`/`AgentBriefingDashboardBand`, not Runtime Cockpit tabs or lifecycle action controls. |
| Server truth is scoped | passed | `agent_briefing::overview` calls `module_activity::overview`, which fails closed without trusted session/workspace causal context. |
| No autonomy behavior | passed | Rust projection has no resource creation, compact/clear, schedule, install, launch, or mutation path; tests assert policy flags. |
| Session Briefing keeps controls | passed | `ContextControlSheet` now leads with a session briefing card and retains model picker plus compact/clear/context audit sections. |
| Runtime Cockpit remains diagnostics | passed | Existing `AgentCockpitSheet` remains mounted from Servers -> Diagnostics only. |

## Deferred Scope

No autonomous work controls, memory editing, notification inbox, approval queue,
runtime execution control, package lifecycle promotion, or broad dashboard
cockpit is included in this slice.
