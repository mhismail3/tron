# Context Control Primitive UI Audit

Status: `implementation_candidate`

This audit records the restored Session Briefing surface, its Context Control
primitive section, and the old pre-primitive UI families that must be evaluated
before any further native surface returns. The retired Agent Control panel is
historical context only: a surface is not restored because it existed before. It
must name the owning primitive/module, current backend substrate, user and agent
workflow, provider-visible boundary, mobile shape, risks, rejection criteria,
and test burden.

## Implemented Candidate: Session Briefing / Context Control

- Old surface history: the retired Agent Control chat model/percentage pill
  opened a broad legacy control panel with context and miscellaneous controls.
- User value: switch the active model from the same catalog used by new-session
  setup, inspect what is in provider context, compact now, clear into a new
  context epoch, and audit recent context actions from the chat surface.
- Current substrate: `domains/context_control` with
  `context_control_snapshot`, `context_control_action`, and
  `context_control_epoch` resources; compact/clear timeline events carry action
  refs. Model switching reuses the existing model catalog and chat model-switch
  path rather than adding a context-control model primitive. Native Session
  Briefing reads/writes context through first-party `context_control::ui_*`
  wrappers, while model/provider access remains behind `capability::execute`.
- Missing primitive owner: none for this slice; `context_control` owns context
  visibility and epoch actions. Model selection remains owned by model/session
  state. Memory remains read-only through refs.
- Proposed module/resource shape: keep context control as a narrow primitive
  inside the Session Briefing chat-sheet surface; future learned-state editing
  belongs to memory/procedural modules, not this sheet.
- Provider visibility: provider-safe projections only: bounded composition
  labels, token estimates, redacted refs, redaction/truncation proof, epoch and
  action refs. No raw prompts, hidden chain-of-thought, secrets, env values,
  paths, commands, logs, grants, or authorities.
- Mobile UI idea: tap timeline/model pill; show a model picker section, Context
  Breakdown, toolbar compact/clear/reload actions, memory read-only status,
  recent actions, and timeline-pill action details.
- Risks: accidental legacy broad-panel resurrection, raw context leakage, clear
  acting like deletion, or context operations without durable audit.
- Rejection criteria: memory retain/edit, source control, skill activation,
  prompt library, raw log, raw prompt, new model-switching backend authority, or
  non-session-scoped context authority in the first slice.
- Test burden: Rust resource/projection/authority/idempotency/epoch tests, iOS
  build and UI interaction tests, simulator tap/compact/clear/detail checks,
  and provider-guidance/schema tests.
- Next decision: after adversarial review, decide whether learned-state status
  or activity/logging deserves the next native control surface.

## Candidate: Learned State

- Old surface: memory, rules, hooks, procedures, retained notes, and behavior
  toggles appeared as mixed local controls.
- User value: understand what Tron has learned, why it was included, and how to
  approve, shadow, rollback, or remove durable learned behavior.
- Current substrate: `domains/memory` resources, prompt traces, memory decision
  evidence, and `procedural_record`/activation resources.
- Missing primitive owner: a native learned-state surface owner is not chosen;
  memory and procedural modules own server state.
- Proposed module/resource shape: a read-first Learned State cockpit backed by
  memory/procedural list/inspect/eval resources, with separate activation
  decision surfaces only after review.
- Provider visibility: bounded memory/procedural summaries, prompt-trace refs,
  decision proof, eval status, policy state, and redacted snippets only.
- Mobile UI idea: grouped cards by memory, rules, hooks, and procedures with
  activation status, provenance, confidence/eval, and approval history.
- Risks: hidden prompt injection, accidental always-on learned behavior, raw
  memory bodies, unclear scope, or local-only UI truth.
- Rejection criteria: native edit/retain/tombstone before server review
  contract, raw memory display, unscoped toggles, or automatic activation.
- Test burden: memory/procedural scope, redaction, activation, rollback,
  prompt inclusion, iOS confirmation, and simulator workflow tests.
- Next decision: design after Context Control is accepted.

## Candidate: Runtime Cockpit / Workers / Jobs / Subagents

- Old surface: broad worker/job/subagent dashboards and fixed execution panels.
- User value: see what autonomous work is running, waiting, blocked, cancelled,
  or ready for review.
- Current substrate: `module_activity::overview`, worker lifecycle catalog,
  module runtime state, jobs/program execution resources, and subagent tasks.
- Missing primitive owner: the existing Runtime Cockpit is diagnostics-first;
  a chat-native work surface is not yet justified.
- Proposed module/resource shape: module-owned activity and task surfaces that
  inspect records and delegate actions through runtime/subagent operations.
- Provider visibility: bounded state, refs, lifecycle, cancellation, timeout,
  and review evidence; no commands, logs, stdout/stderr, env, paths, pids, or
  raw job payloads.
- Mobile UI idea: timeline activity lane with drill-in by active work item,
  preserving Settings -> Diagnostics Runtime Cockpit for global diagnostics.
- Risks: reviving a fixed product dashboard, exposing raw execution detail, or
  bypassing module runtime authority.
- Rejection criteria: PTY/browser defaults, direct job log panels, unscoped
  cancel buttons, or product-specific panels.
- Test burden: runtime/subagent/job state projection, cancellation, timeout,
  authority, no raw leakage, and simulator timeline interaction.
- Next decision: review after context and learned-state surfaces.

## Candidate: Logs, Traces, Diagnostics, Feedback Bundles

- Old surface: local logs and diagnostics were visible in several places.
- User value: explain failures and package evidence for debugging without
  leaking secrets or overwhelming chat.
- Current substrate: local logs, diagnostics bundles, MetricKit, trace
  list/inspect, update diagnostics, and capability evidence.
- Missing primitive owner: a server-owned activity/logging module may be needed
  for first-class audit views; raw logs remain diagnostics-only.
- Proposed module/resource shape: activity/logging records with redacted
  summaries, trace refs, failure class, and feedback bundle refs.
- Provider visibility: trace/error summaries and redacted refs only.
- Mobile UI idea: failure-centric sheet opened from error/action pills, with
  export feedback action and no raw log stream by default.
- Risks: raw logs/secrets/paths, excessive UI noise, or diagnostic data being
  mistaken for provider context.
- Rejection criteria: folding raw logs into Context Control, persistent chat
  log viewer by default, or provider-visible debug payloads.
- Test burden: redaction, bundle custody, trace refs, error-pill navigation,
  and simulator failure workflow.
- Next decision: separate activity/logging module discovery.

## Candidate: Source control, worktrees, repo changes

- Old surface: source-control panels, worktree selectors, diffs, and repo
  workflow controls.
- User value: understand and approve real repo changes, especially
  self-update/self-modification workflows.
- Current substrate: git/resource operations, patch proposals, repository tree
  snapshots, import preview/update diagnostics, and session resources.
- Missing primitive owner: repo workflow is not a native panel owner yet; it
  should be a module pack with explicit authority and review.
- Proposed module/resource shape: source-control module with status/diff/apply
  proposal refs, review checkpoints, rollback refs, and current workspace
  scope.
- Provider visibility: bounded diff/status summaries and resource refs only.
- Mobile UI idea: review queue from chat action pills, not a permanent fixed
  Git dashboard.
- Risks: accidental writes, production deploy paths, broad repo mutation,
  unbounded diffs, local paths, or hidden generated changes.
- Rejection criteria: `tron deploy`, raw file dumps, broad worktree UI before
  module ownership, or unreviewed apply buttons.
- Test burden: exact authority, diff bounding, approval, rollback evidence,
  simulator review/apply flow, and no-deploy guards.
- Next decision: test with self-update stress workflow before native surface.

## Candidate: Prompt library, prompt artifacts, prompt queues

- Old surface: saved prompts, queues, artifacts, and prompt workflow panels.
- User value: reuse and review high-value instructions without hiding prompt
  changes from the user.
- Current substrate: prompt artifacts and procedural records; prompt queues are
  intentionally removed.
- Missing primitive owner: prompt library is not a primitive; it must be a
  module or procedural artifact owner.
- Proposed module/resource shape: prompt artifact records with validation,
  scope, activation status, provenance, and explicit include/exclude decisions.
- Provider visibility: labels, refs, validation and inclusion proof; no raw
  hidden prompt bodies unless explicitly surfaced to the user.
- Mobile UI idea: small insertion/review sheet from composer, not an always-on
  prompt queue.
- Risks: hidden prompt injection, stale prompt claims, queue resurrection, or
  invisible behavior changes.
- Rejection criteria: automatic prompt activation, hidden system prompt edits,
  or queue-like background prompt execution.
- Test burden: scope, redaction, insertion, activation approval, and composer
  simulator tests.
- Next decision: defer until learned-state discussion.

## Candidate: Approvals, Notifications, Inbox

- Old surface: inbox/notifications/approval queues and device notification
  affordances.
- User value: catch pending decisions and delivery failures across devices.
- Current substrate: approval resources, notification/device registration
  resources, delivery metadata, and chat/system error pills.
- Missing primitive owner: APNs/device delivery and native inbox are not fully
  activated.
- Proposed module/resource shape: notification delivery module plus native inbox
  rendering read/decision state from server resources.
- Provider visibility: notification summaries, state, delivery refs, and
  approval status only.
- Mobile UI idea: small top-level inbox badge with grouped approval/attention
  cards and deep links to action sheets.
- Risks: local-only unread truth, APNs entitlement drift, privacy leakage, or
  alert fatigue.
- Rejection criteria: native inbox before server read-state/delivery contract,
  fake push status, or raw payload exposure.
- Test burden: device registration, delivery failure, read state, approval
  action, physical-device validation, and simulator fallback.
- Next decision: requires notification module acceptance.

## Candidate: Media, voice notes, attachments

- Old surface: media workflow panels and saved voice notes.
- User value: inspect attached artifacts, transcripts, and media-derived refs.
- Current substrate: attachments, media artifacts, blob refs, local composer
  transcription, and generic resource inspection.
- Missing primitive owner: media artifact UI is not selected beyond composer
  attachment flow.
- Proposed module/resource shape: media module with artifact list/inspect,
  transcription refs, archive lifecycle, and retention policy.
- Provider visibility: media metadata, blob refs, MIME/size/transcript summary
  refs only.
- Mobile UI idea: attachment detail sheet from chat bubbles with archive and
  transcript refs.
- Risks: raw media bytes in provider context, local-only retention, or voice
  note product panel resurrection.
- Rejection criteria: raw audio display, hidden transcription retention, or
  media browser without server resources.
- Test burden: blob custody, MIME/size checks, transcript refs, archive,
  camera/photo/file flows, and simulator media tests.
- Next decision: defer until media module review.

## Candidate: Skills, Modules, Dependency Policy, Lifecycle/Runtime

- Old surface: skill/package panels and module controls mixed local state with
  execution controls.
- User value: see what modules exist, what is pending review, what is enabled,
  and why runtime/dependency gates block work.
- Current substrate: module registry, proposals, validation, install, dependency
  policy, lifecycle, runtime, module activity, worker lifecycle, generated UI
  resources.
- Missing primitive owner: native module management should remain a generic
  module-plane cockpit unless a specific package owns a surface.
- Proposed module/resource shape: module-plane review cockpit that composes
  registry/proposal/validation/install/dependency/lifecycle/runtime records and
  generated package-owned UI surfaces.
- Provider visibility: bounded module summaries, refs, gate states, and
  authority labels only.
- Mobile UI idea: Runtime Cockpit evolves toward module review/work surfaces
  with generic drill-ins and generated package-owned controls.
- Risks: fixed panels, silent activation, package-manager side effects,
  dependency restoration, raw manifests/paths/grants, or managed skill
  resurrection.
- Rejection criteria: repo-managed `packages/agent/skills`, local module truth,
  package install without review, direct runtime execution, or wildcard
  selectors.
- Test burden: module-plane static gates, authority selectors, lifecycle/runtime
  denial, dependency side-effect guards, generated UI rendering, and simulator
  module review workflows.
- Next decision: use adversarial review findings and real stress sessions to
  choose the next surface.
