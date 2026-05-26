# Product-Shell Reachability Map

Last verified: 2026-05-26 on `next/modular-capability-engine`.

This document is the proof artifact for the remaining fixed iOS/product-shell
surfaces. A surface stays only when it has a live entrypoint, runtime caller,
server dependency, test coverage, or current operator role. Deletion requires
proof that no caller, route, test, or durable contract remains.

## Decisions

| Surface | Entrypoint and Navigation | Client/DTO Dependency | Server/Event Dependency | Tests | Current Role | Decision |
|---|---|---|---|---|---|---|
| AgentControl sheets/cards | `ChatView` opens `SheetCoordinator.showAgentControl()` from `AgentControlPill`; `ChatSheetContent` renders `AgentControlView` | `ChatViewModel` context/model/git state, `SkillStore`, source-control callbacks | Session context, model/settings, skills, git/worktree status, capability/event state; generated `agent_control.session.v1` surfaces expose server-owned session/catalog/control summaries and a stored source-control handoff action | `ChatSheetTests`, `SheetCoordinatorTests`, `TurnGroupingTests`, source-control tests, Rust `generated_ui` AgentControl surface tests | Compact chat harness inspection and source-control launch point | keep thin shell over generated server-owned control projection; delete only after generated UX covers current chat harness role |
| SourceChanges sheets | `AgentControlView`/`SourceControlCardView` opens source-control sub-sheets; `ChatSheetModifier` submits deferred source-change prompts | SourceChanges views, `GitWorkflowState`, `WorktreeStatusCache`, worktree DTOs | `worktree::*`, git workflow capabilities/events, source-control status metadata; generated `source_control.session.v1` surfaces expose bounded git/worktree invocation truth and stored canonical source-control actions | `SourceChangesSheetTests`, `GitActionRunnerTests`, settings parity for conflict-resolution gate, Rust `generated_ui` source-control surface tests | User-reviewed git/source-control workflows still need bespoke interaction | keep thin shell over generated server-owned source-control review; remove fixed mutation controls only after generated UX matches conflict/deferred-prompt workflows |
| Subagent sheets/plugins | `ChatView`/message chips open `subagentDetail` and `subagentResultsList`; `ChatViewModel+SubagentEvents` updates state from plugins | `SubagentState`, `SubagentTypes`, `Subagent*Plugin`, subagent views | `agent::spawn_subagent`, `agent::subagent_status`, `agent::subagent_result`, session event reconstruction; completed results are now deterministic `agent_result:subagent:*` resources and generated `subagent.lineage.v1` surfaces are available | `subagent_lineage`, `SubagentStateTests`, `SubagentTypesTests`, `SubagentChipVariantTests`, event dispatch/reconstruction tests | Chat harness visibility into child-agent execution and pending results | keep thin shell over server-owned lineage truth; delete only after generated lineage UX replaces chat-specific pending/result navigation |
| notification inbox/detail views | Bell button and notification deep links open `NotificationListSheet` / `NotificationInboxDetailSheet` | `NotificationStore`, `NotificationClient`, notification DTOs, APNs/deep-link router, generated UI DTOs | `notifications::send/list/mark_read/mark_all_read`, APNs/device registration, engine stream refresh; durable inbox truth is now `notification` resources with read `decision` refs and delivery `evidence`; generated `notifications.inbox.v1` surfaces are available for server-authored inbox actions | `notification_resources`, `NotificationClientTests`, `NotificationInboxFilterTests`, `NotificationPillTests`, `PushNotificationServiceTests`, deep-link tests | Operator alert inbox and APNs target for background work | keep thin shell over resource-backed truth; fixed Swift shell remains only for APNs/deep-link ergonomics until generated UI can preserve navigation quality |
| Prompt Library sheets/state | Input attachment menu opens `PromptLibrarySheet`; Settings can clear prompt history | `PromptLibraryClient`, prompt DTOs, `PromptLibraryState`, prompt settings, generated UI DTOs | `prompt_library::*` capabilities; durable history/snippets are now `artifact` resources; management surfaces are `ui_surface` resources authored with `targetType = resource_collection` | `prompt_library_resources` and `generated_ui` Rust tests; Swift source guards cover generated management, fixed-management removal, schema-scoped generated action submission, public `engine::invoke -> ui::submit_action` transport, confirmation dialogs, restrained Tron-native renderer components, and selection-only composer insertion | Quick prompt snippets/history insertion into the unsent local draft composer; management is generated UI | complete with gated local composer insertion |
| display stream views | `ChatView` renders active display stream overlay/sheet and stop control | `DisplayStreamState`, `DisplayClient`, display stream views | Display stream events and `display::*`/capability stream output paths | `DisplayStreamStateTests`, `DisplayClientTests` | Live visual stream/preview for running capabilities | defer with reason; current stream frames are ephemeral projections, not durable resource state |
| voice recording affordances | `ContentView` and `SessionSidebar` open `VoiceNotesRecordingSheet` through `FloatingVoiceNotesButton` | `VoiceNotesRecorder`, `VoiceNotesRecordingSheet`, media DTOs | `voice_notes::save` plus `transcription` capability; durable note output is `artifact` + `materialized_file` | `VoiceNotesRecorderTests`, Rust `domain_outputs` tests | Chat-adjacent audio capture to durable resource-backed notes | keep thin shell; fixed list view remains removed |

## Product-Shell Replacement Readiness

Every remaining fixed iOS shell has an explicit decision. Prompt Library is
complete because the only fixed shell left is an accepted local editing boundary:
selecting text into an unsent composer draft is not durable engine truth. Other
surfaces still have active entrypoints, runtime dependencies, or missing
generated/resource replacements, so their phase decision remains `defer with
proof` or `keep thin shell` until a safe convert to generated UI replacement is
complete.

| Surface | Replacement candidate | Blocking gap | Deletion risk | Next prerequisite | Phase decision |
|---|---|---|---|---|---|
| AgentControl sheets/cards | Generated `agent_control.session.v1` surfaces over server-owned session/catalog/control summaries and source-control entry actions | The generated surface exists, but the fixed sheet still carries chat-specific model/skill navigation and sheet placement ergonomics | Medium: immediate deletion would remove a compact chat harness even though server-owned projection truth now exists | Route more AgentControl sections through generated surfaces, then remove fixed controls with absence gates | keep thin shell over generated server-owned projection |
| SourceChanges sheets | Generated `source_control.session.v1` review forms with stored canonical `git::*` / `worktree::*` actions | Generated UI covers status/diff/conflict/action review, but fixed sheets still carry bespoke conflict-resolution and deferred-source-prompt UX | Medium: deleting now could weaken review quality for conflict/deferred-prompt flows | Replace the highest-risk fixed mutation controls with generated actions after side-by-side UX verification | keep thin shell over generated server-owned source-control review |
| Subagent sheets/plugins | Generated `subagent.lineage.v1` resource-collection surfaces over deterministic `agent_result:subagent:*` resources and spawn invocation rows | Server-owned completed-result truth exists, but chat-specific pending/result chips and local navigation still provide current UX around active child work | Medium: removing fixed sheets now would reduce child-agent progress and result discovery even though completed truth is server-owned | Replace fixed pending/result navigation with generated lineage views once the generated UX covers the current chat role end-to-end | keep thin shell over server-owned lineage truth |
| notification inbox/detail views | Resource-backed notification/evidence surfaces plus generated read/ack actions | Server truth and generated inbox actions are converted; APNs deep-link navigation and session-opening ergonomics still rely on the fixed Swift shell | Medium: deleting the shell now would remove operator navigation even though durable truth is server-owned | Replace the fixed detail/navigation affordance only after generated UI has an accepted local navigation bridge or server-authored equivalent | keep thin shell over resource-backed truth |
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
| `prompt_library` | History and snippets are `artifact:prompt-history:*` and `artifact:prompt-snippet:*` resources. Fresh modular-engine-v4 databases do not create retired prompt-library tables. Prompt management uses generated `ui_surface` resource-collection surfaces; the fixed sheet is only a selection-only local composer insertion affordance. | Complete with gated local composer insertion; no fixed create/edit/delete/clear management path remains. |
| `voice_notes` | Saved notes produce `artifact` and `materialized_file` refs; list/delete use resource truth. | Converted; no file-scan compatibility reader. |
| `memory retain` | Retained journal, core memory, and argument outputs are now `artifact` resources with linked `materialized_file` projections; context assembly appends retained rule/argument artifacts from resource truth. | Converted in capability-backed-truth Phase 1 of the capability-backed-truth migration; keep static gates so the picker/product shell work cannot reintroduce hidden memory file truth. |
| `notifications` | Delivery facts are resource-backed notification records with linked `evidence`; read and mark-all-read state is `decision` truth; fresh modular-engine-v4 databases no longer create `notification_read_state`; generated `notifications.inbox.v1` surfaces expose stored read actions. | Converted in capability-backed-truth Phase 2. Keep fixed iOS inbox/detail only as a thin APNs/deep-link navigation shell until generated UI can preserve that local navigation affordance. |
| `subagent` | Completed child-agent output is deterministic `agent_result:subagent:*` resource truth; `agent::subagent_status` and `agent::subagent_result` reconstruct completed output from resources after matching resource id, session scope, and lineage metadata; generated `subagent.lineage.v1` surfaces expose bounded lineage and stored canonical actions while omitting malformed or cross-session rows. | Converted in capability-backed-truth Phase 3 for completed result truth. Keep fixed chat sheets as thin pending/result navigation affordances until generated lineage UX fully replaces them. |
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
