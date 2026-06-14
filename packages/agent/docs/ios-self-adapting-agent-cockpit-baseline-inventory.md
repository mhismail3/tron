# iOS Self-Adapting Agent Cockpit Baseline Inventory

Status: `complete`

This inventory records the retained source, test, docs, and proof surfaces for
the iOS self-adapting agent cockpit baseline. It is intentionally limited to
iOS client projection, the existing read-only resource inspection boundary, and
proof-layer changes. Server worker lifecycle behavior remains owned by the
Self-Updating Worker Runtime Foundation artifacts.

## Retained Runtime Surfaces

- `WorkerLifecycleClient` is a thin `/engine` client over existing catalog,
  resource, and worker-lifecycle functions.
- `WorkerLifecycleRepository` is the SwiftUI/session boundary; concrete engine
  clients remain inside `Support/Composition`.
- `AgentCockpitProjection` is the pure state mapper for worker catalog rows,
  package resource rows, lifecycle actions, confirmations, activity, and
  runtime surface rows.
- `AgentCockpitViewModel` refreshes server facts, executes confirmed lifecycle
  actions, and decodes active `ui_surface` resources.
- `AgentCockpitSheet` and `AgentStatusCapsuleView` are the user-facing cockpit
  shell. They render generic engine facts; they do not hardcode successor
  feature panels.
- `ChatSheetModifier` observes the single-sheet coordinator state while
  constructing its binding so the cockpit capsule reliably presents the sheet.
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

## Regression Gates

- Swift focused tests: Worker lifecycle DTO/client tests, cockpit projection and
  view-model tests, generated UI renderer tests, and theme token tests.
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
