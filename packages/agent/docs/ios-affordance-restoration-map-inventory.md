# iOS Affordance Restoration Map Inventory

Status: `complete`

Machine-readable inventory:
[`ios-affordance-restoration-map-inventory.tsv`](ios-affordance-restoration-map-inventory.tsv)

This inventory is the exhaustive source-backed historical map for the original
iOS restoration planning phase. It compares the old modular capability iOS tree at
`ad5e484722c6f7abbe764126409494026216ad92` to the current IOSAC baseline and
classifies every deleted or renamed old iOS path through grouped rows. The
grouping is intentional: future restoration decisions happen by user-facing
affordance, not by blindly copying legacy files.

The old reference contributes 848 old paths that were deleted or renamed before
the current baseline:

- 567 `Sources/` paths;
- 266 `Tests/` paths;
- 2 `docs/` paths;
- 13 `.claude/rules/` paths.

The static gate verifies that each old path is covered by at least one
inventory row pattern.

## Controlled Vocabulary

Classifications:

- `phase1_local_native`: iOS can implement the affordance fully without
  restored backend agent capability.
- `phase1_server_fact`: iOS can render current server facts without adding new
  backend capability.
- `phase1_review_only`: the concept is worth user review, but implementation
  waits for an approved first-principles shape.
- `phase2_agent_execution`: the surface requires restored agent-loop, module,
  resource, event, or capability behavior.
- `superseded_current_shell`: the current generic shell already replaced the
  old surface or owns the durable equivalent.
- `reject_candidate`: the old item is recorded but likely not worth restoring.

Functional-without-agent-backend values:

- `yes`: can be functional today with current iOS/platform/current server facts.
- `no`: requires future backend or agent capability.
- `review`: not implementable until the user chooses a design direction.

## First-Principles Review Rubric

Every future slice must answer these questions before implementation:

1. Is this affordance a useful long-term signal for an autonomous
   self-updating agent?
2. Does it meaningfully improve how a user works with their agent system?
3. What is the simplest, most minimal, intuitive, utilitarian way to include it?
4. What part is functional today, and what must stay absent until Phase 2?
5. What old behavior is evidence only and must not be copied by default?

## Historical Phase 1 Review Queue

The queue below was the original Phase 1 planning order. It is retained as
historical evidence, not as live scheduling state. Current restoration status is
recorded in `ios-affordance-restoration-progress.md`.

1. Chat composer affordance/menu sheet restoration.
2. Dictation/audio capture and voice input affordance audit.
3. Prompt/input history/snippet affordance audit.
4. Chat visual cues, status, empty/loading/error affordance polish.
5. Settings, onboarding, diagnostics, and pairing affordance restoration.
6. Notification/inbox concept review, only if functional without fake server
   push.
7. Remaining local-native affordance families from the inventory after user
   review.

## Future Slice Review Packet

Each future slice must present this packet before implementation:

- old surface name and old paths;
- current gap;
- proposed modern UX shape;
- exact app entry point;
- what will be functional immediately;
- what remains absent, disabled, or deferred;
- required tests;
- required screenshots or simulator validation;
- user decision required before implementation.

## Phase 2 Anchor

This original anchor required a full Phase 2 agent-execution restoration plan
after the Phase 1 map and local-native slices. That plan now exists in
`phase-2-agent-execution-restoration-scorecard.md`,
`phase-2-agent-execution-restoration-evidence-manifest.md`,
`phase-2-agent-execution-restoration-inventory.md`, and
`phase-2-agent-execution-restoration-inventory.tsv`. The Phase 2 plan covers
every deferred BPRC bucket: capability discovery, filesystem, jobs/processes,
worker self-extension, subagents, goals/queues/questions, approvals, web,
git/worktrees, skills/rules/hooks/memory, MCP, scheduling, program execution,
database/events, settings, and dependency restoration.

Phase 2 work must restore capability through worker-owned functions, triggers,
resources, events, grants, conformance checks, and generated or justified native
UI. It must not restore the old hardcoded harness or fixed product panels by
default.

Agent cockpit placement review: current server-fact diagnostics surface;
passive chat banner removed; re-evaluate from first principles before Phase 2
agent-execution UI.

## Current Boundary

This map does not restore any UI or backend behavior. It records the historical
review taxonomy and original slice ordering. It is not the live Phase 1 queue:
Phase 1 closeout and shipped/deferred behavior are recorded in
`ios-affordance-restoration-progress.md`, while live Phase 2 planning is
recorded in the `phase-2-agent-execution-restoration-*` artifacts. Any future
slice that changes Swift source must run the relevant iOS
build/test/simulator checks and update the iOS architecture docs with actual
restored behavior.
