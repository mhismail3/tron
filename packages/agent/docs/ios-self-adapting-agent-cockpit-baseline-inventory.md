# iOS Self-Adapting Agent Cockpit Baseline Inventory

Status: `complete`

This inventory records the retained source, test, docs, and proof surfaces for
the iOS self-adapting agent cockpit baseline. It is intentionally limited to
iOS client projection, the existing read-only resource inspection boundary, and
proof-layer changes. Server worker lifecycle behavior remains owned by the
Self-Updating Worker Runtime Foundation artifacts.

## Retained Runtime Surfaces

- `WorkerLifecycleClient` is a thin `/engine` client over existing catalog,
  resource, module-activity overview, and worker-lifecycle functions.
- `WorkerLifecycleRepository` is the SwiftUI/session boundary; concrete engine
  clients remain inside `Support/Composition`.
- `AgentCockpitProjection` is the pure state mapper for worker catalog rows,
  package resource rows, lifecycle actions, confirmations, server-owned module
  activity, and runtime surface rows. Malformed catalog entries surface as
  catalog decode degradation instead of being silently omitted from counts or
  verification summaries.
- `AgentCockpitViewModel` refreshes server facts, executes confirmed lifecycle
  actions, decodes active `ui_surface` resources, and preserves the last good
  overview with an explicit degraded refresh-failure status when a connected
  refresh fails.
- `AgentCockpitSheet` is the retained user-facing cockpit diagnostics shell. It
  renders generic engine facts with standard liquid-glass sheet chrome and the
  shared segmented tab control; it does not hardcode successor feature panels.
- `ConnectionSettingsPage` exposes a compact Servers diagnostics row labeled
  `Runtime Cockpit` that opens the sheet.
- `ChatView` no longer mounts the passive cockpit capsule or refreshes cockpit
  data on session load. A future chat-level signal requires a fresh
  attention-worthy placement review.
- `TronColors` owns the neutral glass baseline used by chat, onboarding,
  settings, generated surfaces, and the cockpit.
- Existing `resource::list` and `resource::inspect` primitives are system-visible
  read surfaces for engine clients; resource writes, type registration, and
  wrapper mutations remain outside client visibility.

## Deliberately Absent Surfaces

- No new Rust primitive, provider-visible tool, public `/engine` route, database
  table, auth surface, settings field, production deploy command, or iOS fixed
  product panel was added.
- No successor capability implementation is bundled into the app.
- No worker package manifest is authored by iOS in this slice.
- No `ui_surface` action result is interpreted as a fixed iOS workflow.
- No passive always-visible worker-runtime banner is mounted in the primary
  chat surface.

## Regression Gates

- Swift focused tests: Worker lifecycle DTO/client tests, cockpit projection and
  view-model tests, generated UI renderer tests, and theme token tests. The DTO,
  projection, and view-model tests include malformed catalog decode degradation
  and refresh-failure truthfulness regressions.
- Rust static target:
  `ios_self_adapting_agent_cockpit_baseline_invariants`.
- Predecessor static target:
  `primitive_minimality_closure_invariants` keeps the PMC no-iOS-behavior proof
  bound to the completed PMC diff window rather than treating this later iOS
  cockpit slice as part of the historical teardown.
- Predecessor inventory gate:
  `primitive_code_cleanup_inventory_covers_tracked_files`.
- Final closeout: full Rust CI, full iOS test suite, personal-info guard,
  XcodeGen drift check, whitespace check, ignored-file scan, simulator
  validation, and clean git status before commit.
