# iOS App Architecture

> Last verified: 2026-06-07 (PET-11 primitive capability identity cleanup).

## Overview

**Minimum iOS**: 26.0

The iOS app is a SwiftUI `/engine` client. On the primitive teardown branch it
is intentionally a shell: it pairs with a local Tron server, sends prompts,
renders session messages, persists a local event cache for reconstruction, and
renders generic runtime surfaces emitted by the engine. It does not own fixed
product modes for Work, Audit Details, Source Control, Prompt Library, Voice
Notes, Skills, Agent Control, subagents, worktrees, audio transcription,
plugin sources, memory-retain, or rules.

The Rust server remains authoritative for provider communication, session/event
truth, model routing, execution, state, logs, and generated runtime data. iOS
may cache and render server facts, but it must not invent capability policy,
source-control state, worker state, or product dashboards locally.

## Retained Surface

- Connection, pairing, onboarding, and local paired-server selection.
- Settings needed to reach the server, configure providers, choose models, and
  inspect local diagnostics.
- Session list, session creation/fork/resume, prompt composer, attachments,
  and message rendering.
- Live event plugins plus stored-event reconstruction into `ChatMessage`.
- Generic capability invocation chips and generic generated runtime surfaces.
- Local logs, feedback bundles, MetricKit payload retention, and bounded local
  event cache integrity.

## Deleted Fixed Product Modes

The primary source tree must not contain these view roots or their matching
state/client objects:

- `Views/Work`
- `Views/AuditDetails`
- `Views/SourceChanges`
- `Views/PromptLibrary`
- `Views/VoiceNotes`
- `Views/Skills`
- `Views/Subagents`
- `Views/AgentControl`
- `Services/Network/Clients/CapabilityClient.swift`
- `Services/Network/Clients/GitClient.swift`
- `Services/Network/Clients/PromptLibraryClient.swift`
- `Services/Network/Clients/SkillClient.swift`
- `Services/Network/Clients/WorktreeClient.swift`

`SourceGuardTests.testPrimitiveShellHasNoFixedProductModes` is the regression
gate for this boundary.

## Directory Structure

```
Sources/
+-- App/                  App entry point, app delegate, scene phases
+-- Core/                 Dependency injection, event plugins, transformers
+-- Database/             Local event database and cache queries
+-- Models/               Messages, event types, engine protocol DTOs
+-- Services/             Engine transport, domain clients, pairing,
|                         diagnostics, notifications, storage
+-- ViewModels/           Chat state, event handlers, settings/onboarding state
+-- Views/                Chat, input bar, message bubbles, session tree,
|                         settings, onboarding, dynamic surfaces, diagnostics
+-- Theme/                Colors, typography, design tokens
+-- Utilities/            Shared helpers
+-- Assets.xcassets/      App icons and image assets
```

The retained `Views/Capabilities` components render capability lifecycle data
as generic chat evidence. They are not a capability catalog, admin console, or
operator policy surface. Capability identity is limited to the model-visible
primitive name, optional operation name, trace/root invocation ids, theme
color, and runtime-supplied presentation hints.

## Data Flow

```
Prompt:  InputBar -> ChatViewModel -> AgentClient -> agent::prompt
Live:    WebSocket -> EngineClient -> EventRegistry -> Plugin -> ChatViewModel
Stored:  EventDatabase -> UnifiedEventTransformer -> ChatMessage -> ChatView
Surface: Generated UI ref/data -> GeneratedRuntimeSurfaceView
```

The shell mounts `ContentView` even before onboarding is complete. First-run
onboarding is presented as a sheet over the shell. When `onboardingComplete` is
true but no active paired server exists, the shell stays visible.

## Engine Client Boundary

`EngineConnection` owns the WebSocket request/response transport. Domain client
files are thin method wrappers over `/engine` frames; they must not encode
product policy. Any fixed workflow-specific client removed in PET-8 must stay
removed unless a later scorecard row proves it is boot infrastructure.

Engine invocation context carries session/workspace ids and trace metadata when
needed. The server owns validation, routing, execution, idempotency, and event
publication. iOS records delivered stream cursors for acknowledgement and
diagnostics only; it does not use them as an alternate truth store.

## Event Handling

Live events use self-dispatching plugins registered in `EventRegistry`. Stored
events use `UnifiedEventTransformer` for reconstruction. Unsupported or
malformed events are diagnostics; they are not normalized through retired
product names.

See `events.md` for the current plugin categories and reconstruction boundary.

## Dynamic Runtime Surfaces

`Views/DynamicSurfaces/GeneratedRuntimeSurfaceView.swift` is the retained
generic renderer for server/agent-authored runtime data. It uses native SwiftUI
layout primitives and submits only generic action coordinates or encoded action
payloads supplied by the runtime surface. It must not map fixed feature names
into custom sheets.

## Diagnostics And Build Identity

The settings toolbar exposes Logs in every build configuration. The client log
ingestion service mirrors bounded client logs into the server `logs` table while
connected, creating a self-feeding diagnostics loop that the runtime can inspect
without relying on a debug-only export button.

`ProdDebug` backs the `Tron Fast` scheme: it keeps production bundle identity
and entitlements while using debug build settings for fast local iteration.

## Testing And Evidence

For shell-affecting changes:

- Regenerate the project with `xcodegen generate` when files are added,
  deleted, or renamed.
- Run `SourceGuardTests`, which compiles the full app/test target and enforces
  deleted product roots.
- Capture iPhone and iPad simulator screenshots when UI behavior changes.
- Include simulator name, UDID, bundle id, launch/openurl return codes, and
  screenshot paths in the relevant scorecard evidence.
