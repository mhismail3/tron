# Agent Briefing And Autonomy Cockpit Scorecard

Status: **complete**
Current score: **100/100**
Last updated: 2026-07-05

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

| ID | Check | Weight | Status | Evidence |
| --- | --- | ---: | --- | --- |
| ABAC-0 | Project-grouped dashboard backbone | 10 | passed | `SessionSidebar` still renders `SessionListWorkspaceGroup.groups(from:)` before session rows. |
| ABAC-1 | Read-only server projection boundary | 15 | passed | `agent_briefing::overview` calls `module_activity::overview`, fails closed without trusted scope, and does not create durable state. |
| ABAC-2 | Main dashboard progressive disclosure | 15 | passed | Dashboard consumes `AgentBriefingViewModel`/`AgentBriefingDashboardBand`, not Runtime Cockpit tabs or lifecycle action controls. |
| ABAC-3 | Session Briefing controls retained | 15 | passed | `ContextControlSheet` leads with a session briefing card and keeps model picker, compact/clear, context audit, and memory sections. |
| ABAC-4 | Evidence, redaction, and degraded states | 15 | passed | Briefing DTOs carry provider-safe evidence summaries; UI renders empty/degraded states without raw logs, commands, paths, grants, or secrets. |
| ABAC-5 | Focused tests and static guard coverage | 20 | passed | Rust `agent_briefing` tests, Swift briefing/session-list tests, CSD/CPE/DESI static gates, and simulator inspection cover the implemented slice. |
| ABAC-6 | Deferred scope remains explicit | 10 | passed | Autonomous controls, memory editing, approval queues, runtime execution control, and package promotion remain outside this slice. |

## Deferred Scope

No autonomous work controls, memory editing, notification inbox, approval queue,
runtime execution control, package lifecycle promotion, or broad dashboard
cockpit is included in this slice.
