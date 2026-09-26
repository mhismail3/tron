# Organized model picker

- **Started:** 2026-09-25
- **Status:** Active
- **Last updated:** 2026-09-25, MP1–MP6 claimed
- **Goal:** Replace the flat model list with Recent and Latest card rails plus collapsible provider sections, using the app's existing surfaces.

## Goal and constraints

The shared `ModelPicker` currently renders one alphabetical-ish vertical list of
every available model. It gives no fast path to models the user actually uses and
no sense of what is new or which provider a model belongs to. The target layout,
top to bottom:

1. **Recent** — a horizontally scrolling rail of cards for models the user
   recently used.
2. **Latest** — the same rail, ordered by model release date (newest first).
3. **All models** — the complete list grouped by provider, with each provider
   header collapsing/expanding like the dashboard's workspace groups.

Rules that override an agent's own judgment:

- **One picker.** All callers keep using the single shared `ModelPicker`
  (`SetupComponents.swift`). No per-caller variants or flags.
- **Standard styling only.** Rails and cards reuse the existing Tron
  primitives: the tinted `glassEffect` rounded card from the New Session quick
  selections, `tronScrollSurface` rows, `TronTypography`, and the dashboard's
  disclosure header/chevron/animation. Extract a shared component rather than
  copy-pasting; the New Session quick-selection rail moves onto it in the same
  change. No new colors, fonts, radii, or bespoke chrome.
- **Canonical truth stays canonical.** "Recent" and "release date" are Gateway
  facts delivered to iOS. iOS does not keep its own usage history or a
  hard-coded date table.
- **Distinct choices stay distinct.** Latest aliases and pinned releases remain
  separate selectable models with their existing identity labels
  (`packages/ios-app/docs/development.md`, model picker paragraph). Only the
  Latest rail collapses an alias/pinned pair (see Plan rules).
- **Preserve current behavior.** Toolbar search action, bottom search field,
  keyboard/dismiss guards, selection binding, per-caller theme accent
  (`tronSettingsVisualTheme`), and accessibility labels/values keep working.
- Empty sections are hidden, never shown as placeholders.

## Context (2026-09-25)

- Picker: `ModelPicker` and `ModelPickerSearchPolicy` in
  `packages/ios-app/Sources/UI/Onboarding/SetupComponents.swift`. Callers:
  `NewSessionSheet.swift`, `SessionSummaryCards.swift` (Manage Session →
  Switch Model), `AgentConfigurationControls.swift` (Agent Defaults),
  `KnowledgeDashboardView.swift`, and `OnboardingView.swift` (embedded with
  `minHeight: 260`).
- Model data: `ModelSummary` in
  `packages/ios-app/Sources/Models/ResourceCatalogModels.swift`, served by the
  Gateway `model.list` RPC (`GatewayService.models` in
  `packages/gateway/src/transport/gateway-service.ts`, paged and cached).
  Fields: provider, id, name, reasoning, input, context/max tokens,
  available. **No release date and no usage data exist anywhere today.**
- The pinned Pi SDK `Model` type (`@earendil-works/pi-ai` 0.87.1) has no release
  date. Pi generates its catalog from models.dev, which does publish
  `release_date`, but Pi drops it.
- "Pinned release · date" labels are parsed from `-YYYYMMDD` ID suffixes in
  `ModelDisplayFormatting.swift`; most IDs have no suffix, so this is not a
  release-date source.
- Horizontal card precedent: New Session quick selections
  (`NewSessionSheet.swift`, `ScrollView(.horizontal)` + `HStack` of
  `glassEffect(.regular.tint(...).interactive(), in: RoundedRectangle(cornerRadius: 12))`
  with `.scrollClipDisabled()`).
- Collapsible precedent: dashboard workspace groups (`workspaceHeader` in
  `SessionShellView.swift`; phase/generation state in
  `SessionListWorkspaceDisclosure`, `SessionListPagination.swift`).

## Plan rules

- **Recent** = models whose run actually started (admitted `agent_start` in a
  user session), most recent first, deduplicated by `provider/id`, bounded
  (proposed 12 stored, rail shows those still in the available catalog). Merely
  opening the picker or changing a default does not count. Scope is
  Gateway-wide: one list shared by every paired device (decided 2026-09-25).
- **Latest** = available models with a known release date, newest first, top 10;
  ties break by display name. When a latest alias and its pinned release share
  a release date, the rail shows only the alias; both remain selectable in the
  provider section (decided 2026-09-25). Models without a date appear only in
  provider sections.
- **Provider sections** use the same model rows as today (icon, name, identity
  line, selected checkmark). Section order: provider of the current selection
  first, then providers alphabetically by display name. Expansion state is
  remembered per device, keyed by Gateway profile and provider ID, as a local
  presentation preference (decided 2026-09-25). A provider with no remembered
  state starts expanded only if it holds the current selection. Header shows
  provider display name and model count.
- **Search**: while the query is non-empty, rails are hidden and provider
  sections show only matches, all expanded; clearing search restores the prior
  expansion state.
- **Cards**: fixed width sized for Dynamic Type (name up to two lines, provider
  as secondary line), selected card uses the stronger tint + checkmark exactly as
  the rows do, `accessibilityLabel`/`Value` match row semantics.

## Tasks

| ID | Status | Scope | Depends on | Owner |
| --- | --- | --- | --- | --- |
| MP1 | Claimed | Gateway: record recent model usage and serve it via a new read RPC | none | tron organized-model-picker, 2026-09-25 |
| MP2 | Claimed | Gateway: optional `releaseDate` on `model.list` items from a bundled models.dev snapshot | none | tron organized-model-picker, 2026-09-25 |
| MP3 | Claimed | iOS: shared horizontal card rail component; move New Session quick selections onto it | none | tron organized-model-picker, 2026-09-25 |
| MP4 | Claimed | iOS: generalize dashboard disclosure state into a shared collapsible-section primitive | none | tron organized-model-picker, 2026-09-25 |
| MP5 | Claimed | iOS: sectioned `ModelPicker` (Recent, Latest, provider sections, search mode) | MP1, MP2, MP3, MP4 | tron organized-model-picker, 2026-09-25 |
| MP6 | Claimed | E2E proof, screenshots, and owning-doc updates | MP5 | tron organized-model-picker, 2026-09-25 |

## Task details

### MP1 — Recent model usage (Gateway)

- New Gateway-owned bounded store (new `recent-models.ts` in
  `packages/gateway/src/providers/`), persisted in Gateway state, written when
  a user session's `agent_start` is admitted in `runtime-slot.ts` with that
  session's current model. Subagent sessions do not write.
- New read RPC (proposed `model.recent`) returning ordered `{provider, id,
  lastUsedAt}` refs, bounded. Kept separate from `model.list` because that
  catalog is paged and snapshot-cached; usage is volatile.
- Broadcast a lightweight change event (or reuse the existing catalog-changed
  path) so an open picker refreshes; the picker's load follows the presentation
  read rules in `AGENTS.md` (latest-request fence, disposable).
- Tests: one integration test driving a faux-model prompt and asserting the
  RPC order/dedupe/bound. Document the RPC in `packages/gateway/README.md`.

### MP2 — Release dates (Gateway)

- Source (decided 2026-09-25): a Gateway-bundled snapshot of models.dev
  `release_date` keyed by `provider/id` (new `model-release-dates.json` in
  `packages/gateway/src/providers/`), regenerated only by a manual maintainer
  script (new `update-model-release-dates` in `scripts/`). No runtime network
  fetch. Document the refresh step in `packages/gateway/README.md`.
- `model.list` items gain optional `releaseDate: "YYYY-MM-DD"`; iOS
  `ModelSummary` decodes it as optional. Unknown models simply have no date.
- Custom models (Settings → Custom Models) have no date unless a later task adds
  an editor field.

### MP3 — Shared card rail (iOS)

- Extract the New Session quick-selection rail into a reusable view in
  `packages/ios-app/Sources/UI/Theme/` (section title + horizontal
  `ScrollView` + tinted glass cards, `.scrollClipDisabled()`, horizontal
  padding matching list content). It takes an accent so each caller's theme
  applies.
- Replace the New Session quick-selection implementation with it in the same
  change; visuals there must be unchanged (before/after screenshot).

### MP4 — Shared collapsible sections (iOS)

- Promote `SessionListWorkspaceDisclosure` (phase + generation state) and the
  header's chevron/rotation/animation into a neutral shared primitive usable by
  a `ScrollView`/`LazyVStack` as well as the dashboard `List`. The dashboard
  moves onto it with identical behavior; no second disclosure implementation.

### MP5 — Sectioned picker (iOS)

- A pure sectioning function (alongside `ModelPickerSearchPolicy`) builds
  Recent, Latest, and provider groups from catalog + recent refs + query.
  Before writing it, list its failure modes (stale recent ref not in catalog,
  unavailable model, missing dates, alias/pinned ties, selection in collapsed
  section, empty search result, provider with zero available models) and test
  only those.
- `ModelPicker` renders the sections; callers pass nothing new except that the
  picker loads recents itself through the app model for its profile/scope.
- Onboarding's embedded picker: rails are naturally empty/hidden on a fresh
  install; confirm the 260-pt embedded layout still works.

### MP6 — Proof and docs

- Extend `SessionSheetPresentationTests` (or the owning UI test) to open the
  picker against a fixture catalog and assert section order, collapse/expand,
  search mode, and selection from a rail card; retain light/dark screenshots at
  a stable artifact path.
- Update the model picker paragraph in `packages/ios-app/docs/development.md`
  and the picker description in `packages/ios-app/docs/architecture.md`; add the
  new RPC/field to `packages/gateway/README.md`.

## Handoff log

_No entries yet._
