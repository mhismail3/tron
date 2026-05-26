# Product-Shell Reachability Map

Last verified: 2026-05-25 on `next/modular-capability-engine`.

This document is the proof artifact for the remaining fixed iOS/product-shell
surfaces. A surface stays only when it has a live entrypoint, runtime caller,
server dependency, test coverage, or current operator role. Deletion requires
proof that no caller, route, test, or durable contract remains.

## Decisions

| Surface | Entrypoint and Navigation | Client/DTO Dependency | Server/Event Dependency | Tests | Current Role | Decision |
|---|---|---|---|---|---|---|
| AgentControl sheets/cards | `ChatView` opens `SheetCoordinator.showAgentControl()` from `AgentControlPill`; `ChatSheetContent` renders `AgentControlView` | `ChatViewModel` context/model/git state, `SkillStore`, source-control callbacks | Session context, model/settings, skills, git/worktree status, capability/event state | `ChatSheetTests`, `SheetCoordinatorTests`, `TurnGroupingTests`, source-control tests | Compact chat harness inspection and source-control launch point | keep thin shell; convert to generated UI after chat context/source-control projections exist |
| SourceChanges sheets | `AgentControlView`/`SourceControlCardView` opens source-control sub-sheets; `ChatSheetModifier` submits deferred source-change prompts | SourceChanges views, `GitWorkflowState`, `WorktreeStatusCache`, worktree DTOs | `worktree::*`, git workflow capabilities/events, source-control status metadata | `SourceChangesSheetTests`, `GitActionRunnerTests`, settings parity for conflict-resolution gate | User-reviewed git/source-control workflows still need bespoke interaction | keep thin shell; convert to generated UI only after generated forms can cover git workflows |
| Subagent sheets/plugins | `ChatView`/message chips open `subagentDetail` and `subagentResultsList`; `ChatViewModel+SubagentEvents` updates state from plugins | `SubagentState`, `SubagentTypes`, `Subagent*Plugin`, subagent views | `agent::spawn_subagent`, `agent::subagent_status`, `agent::subagent_result`, session event reconstruction | `SubagentStateTests`, `SubagentTypesTests`, `SubagentChipVariantTests`, event dispatch/reconstruction tests | Chat harness visibility into child-agent execution and pending results | defer with reason; replace with invocation/resource lineage before deleting fixed sheets |
| notification inbox/detail views | Bell button and notification deep links open `NotificationListSheet` / `NotificationInboxDetailSheet` | `NotificationStore`, `NotificationClient`, notification DTOs, APNs/deep-link router | `notifications::send/list/mark_read/mark_all_read`, APNs/device registration, engine stream refresh | `NotificationClientTests`, `NotificationInboxFilterTests`, `NotificationPillTests`, `PushNotificationServiceTests`, deep-link tests | Operator alert inbox and APNs target for background work | keep thin shell; convert inbox state to resources only after notification delivery semantics are specified |
| Prompt Library sheets/state | Input attachment menu opens `PromptLibrarySheet`; Settings can clear prompt history | `PromptLibraryClient`, prompt DTOs, `PromptLibraryState`, prompt settings, generated UI DTOs | `prompt_library::*` capabilities; durable history/snippets are now `artifact` resources; management surfaces are `ui_surface` resources authored with `targetType = resource_collection` | `prompt_library_resources` and `generated_ui` Rust tests; Swift source guards cover generated management, fixed-management removal, schema-scoped generated action submission, public `engine::invoke -> ui::submit_action` transport, confirmation dialogs, restrained Tron-native renderer components, and selection-only composer insertion | Quick prompt snippets/history insertion into the unsent local draft composer; management is generated UI | complete with gated local composer insertion |
| display stream views | `ChatView` renders active display stream overlay/sheet and stop control | `DisplayStreamState`, `DisplayClient`, display stream views | Display stream events and `display::*`/capability stream output paths | `DisplayStreamStateTests`, `DisplayClientTests` | Live visual stream/preview for running capabilities | defer with reason; current stream frames are ephemeral projections, not durable resource state |
| voice recording affordances | `ContentView` and `SessionSidebar` open `VoiceNotesRecordingSheet` through `FloatingVoiceNotesButton` | `VoiceNotesRecorder`, `VoiceNotesRecordingSheet`, media DTOs | `voice_notes::save` plus `transcription` capability; durable note output is `artifact` + `materialized_file` | `VoiceNotesRecorderTests`, Rust `domain_outputs` tests | Chat-adjacent audio capture to durable resource-backed notes | keep thin shell; fixed list view remains removed |

## Product-Shell Replacement Readiness

Every remaining fixed iOS shell has an explicit decision. Prompt Library is
complete because the only fixed shell left is an accepted local editing boundary:
selecting text into an unsent composer draft is not durable engine truth. Other
surfaces still have active entrypoints, runtime dependencies, or missing
generated/resource replacements, so their phase decision remains `defer with
proof`.

| Surface | Replacement candidate | Blocking gap | Deletion risk | Next prerequisite | Phase decision |
|---|---|---|---|---|---|
| AgentControl sheets/cards | Generated goal/session/control inspection surfaces over `control::inspect`, goal resources, and source-control refs | Chat context, model selection, skill state, and source-control launch affordances are not yet represented as one generated surface with equivalent ergonomics | High: removal would hide active chat/source-control controls | Build server-authored generated surfaces for chat context, active model/settings, skill visibility, and source-control entry actions | defer with proof |
| SourceChanges sheets | Generated git/worktree review forms with stored canonical actions | Generated UI does not yet cover conflict review, deferred source-change prompt submission, and user-reviewed git workflow branching | High: removal would weaken user review of source-control mutations | Define generated git/worktree review surfaces with resource-backed diff summaries, conflict state, and canonical action submissions | defer with proof |
| Subagent sheets/plugins | Invocation/resource lineage surfaces for child workers and `agent_result` resources | Chat still renders pending child execution and result chips from event/plugin state; no full generated replacement for the pending/result UX exists | High: removal would obscure child-agent progress and result discovery | Replace pending/result plugin state with child invocation/resource lineage projections and generated detail/list surfaces | defer with proof |
| notification inbox/detail views | Resource-backed notification/evidence surfaces plus generated read/ack actions | Notification delivery, read receipts, APNs deep-link semantics, and inbox grouping remain event/read-state based | High: removal would remove the operator alert inbox | Specify notification delivery/read-resource contract, then build generated inbox/detail surfaces over that truth | defer with proof |
| Prompt Library sheets/state | Generated `artifact:prompt-snippet:*` and `artifact:prompt-history:*` collection management surfaces plus selection-only `onSelect(text)` picker | Composer insertion is intentionally local draft editing; no durable engine state exists until the user sends the prompt | Low: deleting the picker would remove useful local draft insertion without reducing server-owned state | Keep the picker selection-only; static gates forbid fixed management and local generated-action construction; generated management must stay restrained, Tron-native, confirmation-backed, schema-scoped, and covered through the public `engine::invoke` action transport path | complete with gated local composer insertion |
| display stream views | Stream/control generated surface for live display sessions | Live frames are ephemeral renderer data and do not have a generated UI streaming component or materialized display-state contract | Medium: removal would hide active visual stream previews | Define display stream projection semantics and generated stop/inspect surface, or intentionally keep the fixed stream renderer | defer with proof |
| voice recording affordances | Generated `voice_notes` resource list/detail surfaces after recording completes | Microphone capture is a local hardware affordance that cannot be wholly generated by the server; only saved-note inspection is replaceable | Medium: deletion would remove capture, not just listing | Keep recording affordance; replace only post-save list/inspect flows with generated/resource views when ready | defer with proof |

## Absence Proof

The following fixed product-shell surfaces remain deleted and protected by
static gates:

- fixed Automations dashboard and `NavigationMode.automations`;
- fixed Voice Notes list/deep-link route and `NavigationMode.voiceNotes`;
- unused `SafariView` browser wrapper.

## Deferred Domain Output Decisions

| Domain | Current durable/output state | Decision |
|---|---|---|
| `prompt_library` | History and snippets are `artifact:prompt-history:*` and `artifact:prompt-snippet:*` resources. Fresh modular-engine-v3 databases do not create retired prompt-library tables. Prompt management uses generated `ui_surface` resource-collection surfaces; the fixed sheet is only a selection-only local composer insertion affordance. | Complete with gated local composer insertion; no fixed create/edit/delete/clear management path remains. |
| `voice_notes` | Saved notes produce `artifact` and `materialized_file` refs; list/delete use resource truth. | Converted; no file-scan compatibility reader. |
| `memory retain` | Retained journal, core memory, and argument outputs are now `artifact` resources with linked `materialized_file` projections; context assembly appends retained rule/argument artifacts from resource truth. | Converted in capability-backed-truth Phase 1 of the capability-backed-truth migration; keep static gates so the picker/product shell work cannot reintroduce hidden memory file truth. |
| `notifications` | APNs/inbox read state still uses notification event/read-state tables and iOS notification views. | Defer with reason; convert only after notification delivery, read receipts, and APNs operator UX have a resource-backed contract. |
| `display` | Display frames are stream/projection data for active sessions. | Keep as ephemeral capability output; materialize only if display captures become durable artifacts. |
| `browser` | Browser status and event DTOs support local browser/computer-use flows. | Keep as capability module; remove only with route/DTO/event proof. |
| `device` | Device token registration and APNs bundle routing remain runtime infrastructure. | Keep distribution/support state; do not collapse into generated UI until pairing/notification flows are redesigned. |
| `transcription` | Audio-to-text is a reusable capability used by voice notes; transcripts become durable only through caller-owned resources. | Keep as capability module; audit any future direct retained transcript output. |

## Next Removal Bar

Before removing any remaining surface, a future cleanup pass must show:

1. no Swift navigation/sheet entrypoint;
2. no DTO/client dependency;
3. no server capability/event dependency;
4. no current test or documented operator role;
5. a generated UI/control/resource replacement when the surface still exposes
   useful operator behavior.
