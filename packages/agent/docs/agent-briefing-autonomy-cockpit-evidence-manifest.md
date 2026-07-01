# Agent Briefing And Autonomy Cockpit Evidence Manifest

Status: implementation candidate
Last updated: 2026-07-01

## Implementation Evidence

| Area | Evidence |
| --- | --- |
| Backend projection | `packages/agent/src/domains/agent_briefing/` adds `agent_briefing::overview`, a pure-read projection over `module_activity::overview`. |
| Dashboard UI | `packages/ios-app/Sources/UI/Chat/Shell/SessionSidebar.swift` mounts `AgentBriefingDashboardBand` above existing workspace groups. |
| Full briefing sheet | `packages/ios-app/Sources/UI/AgentBriefing/AgentBriefingViews.swift` renders sections, evidence drill-down, empty states, and degraded state. |
| Session Briefing | `packages/ios-app/Sources/UI/Chat/Sheets/ContextControlSheet.swift` reframes the context/model pill sheet as Session Briefing while retaining model picker, context breakdown, compact, clear, memory status, and action audit. |
| Diagnostics retained | `packages/ios-app/Sources/UI/Settings/Pages/ConnectionSettingsPage.swift` still owns `AgentCockpitSheet` under Runtime Cockpit diagnostics. |

## Validation Evidence

| Command | Result |
| --- | --- |
| `cargo fmt --manifest-path packages/agent/Cargo.toml --all -- --check` | passed |
| `cargo test --manifest-path packages/agent/Cargo.toml agent_briefing --no-default-features` | passed |
| `cd packages/ios-app && xcodegen generate` | passed |
| `xcodebuild test -scheme Tron -destination 'platform=iOS Simulator,name=iPhone 17 Pro' ...` focused Agent Briefing/session-list selectors | passed |

Simulator screenshots and remaining static guard results are recorded in the
final implementation status after device validation completes.
