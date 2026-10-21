# Chat

## Purpose

The session shell, Sessions dashboard, chat route (transcript, composer, tool and context details),
Manage Session, Home's chat and sheets, New Session, session history and subagent activity.

## Owns

- Shell and dashboard: `SessionShellView` (`SessionShellProfileRouteOwner`), session rows and
  swipe actions, `ArchivedSessionsSection`, `SessionTitleSearch`, `HomePinnedRow`.
- Chat route: `ChatView` (composition and lifecycle root), `ChatRoutes`, `ChatTranscriptSheetRoutes`,
  `ChatSessionPresentation`, `ChatTranscriptScrollView`, `ChatTranscriptOrientation`,
  `ChatScrollCoordinator`, `ChatComposerView`, `ChatTranscriptPresentationStore`,
  `ChatTranscriptProjectionKernel`, `ChatCommittedLedger`, `TranscriptRow`, `TronMarkdownView`.
- Details: `ToolDetailSheet` and tool presentations, `ToolChangesSheet`, extension interaction,
  form and widget sheets, `SessionProcessSheets`, attachment previews and camera capture.
- Manage Session and Home: `SessionModelConfigurationCard`, `WorkspaceInspectorSheet`,
  `AgentInstructionsSheet`, `SessionTreeSheet`, `HomeManageSheet` and the `Home*Sheet(s)` files.
- `NewSessionSheet`, `NewSessionConfigurationOwner` (`NewSessionCreationOwner`), `ProjectSettingsSheet`.

## Contract

- **Authority.** Canonical truth is Gateway/Pi; `SessionPresentationStore` owns the mounted
  authority, `AppModel` is its façade, and `ChatTranscriptPresentationStore` owns only immutable,
  disposable rendering. `ChatView.body` never constructs the timeline. The mounted route supplies
  an immutable session ID to every prompt, mutation, extension response, terminal operation and
  secondary read; dashboard rows never become a subscription fallback.
- **Dashboard.** Rows are profile-qualified and only user sessions (subagent backing sessions
  stay hidden). Active rows first, held by `activeSince`; settled rows by `updatedAt`. Ten per
  workspace by default (Settings › App Customizations › **Chats per project**, 1–100). Swipes:
  Archive/Unarchive (gray, `session-archive.v1`), Rename (emerald), Mark Read/Unread (gray), Delete
  (red, no destructive role); every one confirms through the shared sheet and nothing is staged
  locally. **Archived (N)** appears after every workspace only for a non-zero count, reads
  `archived: "only"` pages per server, and scrolls the list only for the user's own expansion.
  Search filters titles locally (`SessionTitleSearch`); content search is Home's `session_search`.
- **Opening.** Every new presentation synchronizes a fresh bounded latest page behind an opaque
  surface with a centered pulse; cached or paged prefixes are never its baseline. One optional
  exact backward page fills a sparse tail. After one covered display frame the transcript reveals,
  and readiness (send, paging, interaction, extension routes) waits for a current first-ready frame.
  The composer stays mounted throughout. An interrupted open waits in `waitingForConnection`; a
  retained transcript shows `ChatRecoveryStatusLine` in the title's place after a two-second grace
  (#878), at once for credential or Gateway rejections.
- **Projection.** One deterministic `ChatTranscriptProjectionKernel` turns canonical entries into
  raw atoms and assembles joins, groups and semantic maps globally; there is no second projector.
  Work is serialized off the MainActor, coalesced to the newest source, and installed at a display
  frame while the last complete commit stays visible. Only canonical rows enter
  `ChatCommittedLedger`; streaming and runtime rows stay in `ChatLiveRegion`. Message presentation
  IDs come from the Gateway and are never rewritten; duplicate IDs fail closed into one fresh
  synchronization. `TranscriptRowPresentationPolicy` decides whether a row exists. Markdown and
  thinking are prepared off-main under one LRU (4 MiB, 512 Markdown, 4,096 thinking segments).
- **Viewport.** `ChatTranscriptOrientation` puts the newest row at the content origin.
  `ChatViewportMode` is `.pinned` (the native bottom size-change anchor owns growth, with zero app
  writes) or `.anchored` (top retention, target-free). Only explicit intent changes mode.
  `ChatScrollCoordinator` owns the bounded commands: catch-up, semantic restore (within one point,
  one-second deadline) and prepend (eight-second deadline); every `ChatLayoutTransaction` ends
  settled or abandoned. A detached reader keeps one frozen installed commit until it returns.
  UIKit owns keyboard motion and the composer's single first responder; the composer is the
  ScrollView's sole bottom safe-area inset. Exactly one scroll owns the status-bar gesture.
- **Spatial roles.** User prompts right-anchored (≤ 364 points, emerald glass), agent prose and
  tools left, system events centered. Entrances follow the role once per semantic identity;
  existing rows never animate stack-wide. An outgoing prompt installs at full natural size and
  only fades and rises 20 points over 280 ms, keeping its physical row through canonical
  replacement. Streaming text reveals newly admitted words by opacity only (220 ms fade).
- **Composer.** Drafting works during opening and active turns; only submission waits. Send
  replaces Stop when a draft exists; `acceptsQueuedPrompts` alone allows steering (the send
  menu picks steer or follow-up). Stop is preemptive and fenced by the operation ID. Queue cards
  (≤ 364 points) open an editor; long-press reorders or clears. `/` completes commands and
  prompts, `@` skills only (`skill-prompt.v1`). Picker secondary copy uses
  `TronTypography.settingsRowSubtext`, matching Manage Home rows; quote annotations (#899) compose `<annotation>`
  blocks into the sent text; Save hands the keyboard straight to the composer input (#1597). Camera, photo and file attachments stage locally (10 items, 25 MiB);
  `CameraModel` drives one `AVCaptureSession` (#937). The context ring opens Manage Session.
- **Tools.** Calls and results join by `toolCallId` into one chip; consecutive calls with equal
  nonempty segments form one run chip whose aggregate sheet lists bounded summary rows. Every
  chip opens a top-anchored detail sheet presented above the rows by `ChatTranscriptSheetRoutes`,
  starting at medium per fresh presentation. Edits show one verified diff inline, otherwise a
  Changes sheet; `ToolDiffCountChip` counts belong to that diff. Codemode shows Script, Result
  and Calls; Home's tools use `HomeToolDetailPresentation`; [display artifacts](../../../docs/display-artifacts.md)
  owns display. Technical details hold JSON. `TaskToolDetailPresentation` shows catalog rows/counts,
  status, paged reports and receipts; unknown shapes stay generic. Reports/messages use `PromptTextPreview` and the full reader; absent fields are not inferred.
- **Thinking and context.** Thinking shows at most four measured lines, opening the full trace on
  tap. Compaction, branch, configuration and extension status share one notification-pill language;
  command pills never show arguments. `custom_message` is right-aligned context; worker results
  read **Worker · task title**; subagent messages use the seafoam **Subagent** chip.
- **Haptics.** Live events only, through `TronHaptics`; `ChatLiveHapticLedger` tells live from restored.
- **Extension interactions.** The mounted route is the sole sheet owner and presents pending
  interactions only after the first ready frame. Forms (one to four questions) keep a device-local
  draft; swipe-down preserves it and only Cancel resolves. Retained extension state is reachable
  only through the one **Activity** sheet.
- **Subagents.** The composer's activity orb reflects admitted process rows only. Activity lists
  running, retained and recent work; Manage Session › Subagent History pages terminal receipts.
  A child transcript is a read-only `ReadOnlySubagentSessionStore` lease whose only mutation is the
  capability-gated stop (`process-transcript-abort.v1`).
- **Manage Session.** Usage card, purple model card (Switch Model opens `ModelPicker`; Context Window
  and Thinking morph into one anchored slider that commits at most once on collapse), then the blue
  Session container: Current Branch (`workspace-inspector.v1` Files/Changes/History), Agent
  Instructions, Available Tools (Chat-layer `tools.active`), Project Resources, Session History
  (100-row pages, `session-history-pages.v1`), Subagent History, then Export as HTML/JSON.
- **Home.** The pinned row routes the `openSessionId` from `home.status`; Home's composer sends
  `home.prompt` and follows a successor chapter carrying the unsent draft. A chat claiming Home has
  no header bar (#740) and its title reads **Home**: its ring opens Manage Home, its gear opens
  Settings, and the composer's Stop is the only Stop (#811). Home sheets are routed by `ChatView`'s `HomeSheetRoute`, open at medium,
  and read through `HomeSheetReadOwner`; Tasks follow the Gateway
  [Home contract](../../../../gateway/docs/home.md). Task Stop and Steer live in the worker's chat
  (#911).
- **New Session.** Settings, trust and Git preparation are fenced to the original profile,
  lifecycle and workspace; one command per gesture; a created route is consumed once and never
  replayed into a replacement Mac.

## Invariants

- Opening, paging and live intake never reveal an unverified projection; coverage retires
  disposable work but never accepted commands, drafts or canonical intake.
- Detached readers receive no automatic scroll writes; pinned readers follow only through the
  native anchor.
- Disposable state (opening, imports, entrance ledger, floating displays) lives in
  `ChatSessionPresentation`; nothing here is persisted except drafts via State.
- Reduce Motion removes spatial motion and never hides authoritative text.
- Disable Home's icon, title and subtitle use `tronError`; Pause memory keeps standard styling.

## Entry points

`SessionShellView.swift`, `ChatView.swift`, `ChatTranscriptPresentationStore.swift`,
`ChatScrollCoordinator.swift`, `ChatComposerView.swift`, `ToolDetailSheet.swift`,
`HomeManageSheet.swift`.

## Signals

| Signal | Level | Meaning |
|---|---|---|
| `display.media` | error | A current artifact download failed or its AVPlayerItem failed, once per preparation (`DisplayVideoPlayback.swift`): `requestID`, `stage`, player `status`, allowlisted error `domain`/`code` and one underlying pair; never names, paths or URLs |
| `opening.failed` | warning | The conversation layout did not settle and the open failed (`ChatView.swift`); settlement reasons in `details`. Chat's trace records: [Core](../../../Core/README.md#signals) |

## Verify

Classes under `TronMobileUITests/`: `TronHomeDashboardUITests`, `TronHomeSheetsUITests`,
`TronDashboardHomeButtonUITests`, `TronNewSessionUITests`, `TronSubagentParityUITests`,
`TronToolSheetsPolishUITests`, `TronChatDisplayStripUITests`, `TronChatAnnotationUITests`,
`TronComposerUploadUITests`, `TronChatHapticsUITests`, `TronReadonlyAttachmentUITests`, `TronCameraCaptureUITests`,
`TronSessionRowClockUITests`, and the Home, Manage Session and Ask User journeys in
`TronSmokeUITests` ([runbook](../../../docs/development.md#efficient-focused-tests)). Real
boundaries: `scripts/ios-gateway-e2e-test run-ui` and `scripts/tron test gateway
src/home/home-session-catalog.e2e.test.ts src/sessions/home-activation.e2e.test.ts`. Motion,
gestures, the private top blur and the keyboard need a `Tron Device` check.

## Not here
Mounted-session state and drafts: [State](../../State/README.md). Event and sync rules:
[events](../../../docs/events.md). Shared components and sheet rules:
[presentation parity](../../../docs/presentation-parity.md). Settings sheets reached from Manage
Session: [Settings](../Settings/README.md). Terminals: [Terminal](../Terminal/README.md).
