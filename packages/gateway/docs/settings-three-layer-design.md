# Three-layer settings design

Approved implementation and visual direction for #1634, not the current contract. Production
implementation, migration validation and final candidate/golden review remain required.
Current behavior: [settings contract](settings-contract.md).

## Resolution and ownership

- One registry, resolver and audited change path. Precedence is **Project > Session override > Global**;
  Home uses its Profile as the Session override, has no Project, and no second chapter override.
- Global is the saved machine configuration with release defaults underneath, presented as one
  editable scope. Keep existing owned Pi/Gateway/credential stores; merging the concept does not
  mean moving credentials into a giant settings file. No UI Mac/default distinction.
- Replace per-key scope/layer permission lists with `sessionOverridable` and `projectSettable` booleans.
  Store bindings, value validation, writers, safety floors, effects and capability constraints remain
  necessary metadata, not independent scope policies. iOS derives row eligibility from the registry.
- Only trusted Project values enter resolution or SDK admission. Apply the allowlist before every
  consumer, not merely before UI rendering: raw SDK reads must not resurrect ignored safety keys.
  No pinned SDK/package modification is proposed; stop for a decision if that proves necessary.
- A set Project value masks the Session value at that instance; resolve per-model qualifiers within
  a scope before comparing scopes. Preserve supported map/tool composition only among admitted values;
  a masked Session value must not leak into composition. A lower scope's more-specific qualifier
  never outranks a higher scope's plain value.
- Keep a masked Session override stored, inactive, and unchanged. Removing the Project value reactivates
  it at the key's effect boundary. Changing a masked override is refused, including agent/taskId writes;
  Revert is not offered until Project releases the key. No misleading successful-but-ineffective edit.
- Missing/untrusted/unreadable Project settings contribute nothing. Session rows remain editable and
  show Session/Global values, never the Project pill. A notice says respectively “Project settings
  aren't applied until this project is trusted” or “Project settings couldn't be read”; details name
  the path. Trust changes remain in Trusted Projects, not an automatic approval in this sheet.
- Unknown/disallowed repo keys are ignored with bounded diagnostics naming file/key/reason, never
  secret values. Permissions, trust, credentials, approval floors, grants and budgets are forbidden
  even in trusted repos. This deliberately tightens existing unsafe Project behavior, not parity loss
  to hide. Thinking-token budgets count as budgets; tool availability and image visibility as permissions.
- Invalid/unavailable Project model: show the error and refuse the next affected request; do not silently
  select a lower-precedence model or fallback queue. Thinking capability clamping stays explicit.

## Key inventory and proposed allowlists

All 49 current `KEYS` declarations are listed below. Current layer abbreviations: C=Chat, H=Profile,
P=Project, M=Mac; all have release-default fallback when defined. `C*` is read-only launch evidence,
not writable scope. S/P columns are proposed booleans; safety “yes” forbids Project. “No” is not a claim
that a trusted executable resource is sandboxed. Groups are Gateway groups; iOS keeps its current cards.
Effects retain existing boundaries unless explicitly noted. Applicable Home keys use the same override
mechanism; its restricted execution recipe is not expanded by this redesign (decision below).

| Key | Group | Current layers | S | P | Safety | Mid-run / effect |
| --- | --- | --- | --- | --- | --- | --- |
| `model.ref[role=chat]` | model | C,H,P,M | yes | yes | no | Next request for running worker; otherwise next turn |
| `model.thinking[role=chat]` | model | C,H,P,M | yes | yes | no | Next request for running worker; otherwise next turn |
| `model.contextWindow` | model | C,P,M | yes | yes | no | Next turn; busy worker must settle |
| `model.thinkingBudgets` | workers | P,M | no | no | yes | New session |
| `model.thinking[role=summarizer]` | context | P,M | no | yes | no | Next compaction; ordinary runtime only |
| `model.queue[role=worker]` | workers | C*,H,M | yes | no | no | Next delegation; Home delegation capability |
| `model.queue[role=subagent]` | workers | C*,H,M | yes | no | no | Next child admission; existing children unchanged |
| `model.queue[role=background]` | workers | H,M | yes | no | no | Next memory pass; Home profile or Global Knowledge |
| `model.thinking[role=worker]` | workers | H | yes | no | no | Next delegation; Home delegation capability |
| `context.compaction.enabled` | context | C,P,M | yes | yes | no | Next compaction; ordinary runtime only |
| `context.compaction.reserveTokens` | context | C,P,M | yes | yes | no | Next compaction; ordinary runtime only |
| `context.compaction.keepRecentTokens` | context | C,P,M | yes | yes | no | Next compaction; ordinary runtime only |
| `context.compaction.instructions` | context | C,P,M | yes | yes | no | Next compaction; ordinary runtime only |
| `context.branchSummary.reserveTokens` | context | P,M | no | yes | no | Next branch summary; ordinary runtime only |
| `context.images.autoResize` | tools | C,P,M | yes | yes | no | New session |
| `context.images.block` | tools | C,P,M | yes | no | yes | Block next request; allow requires approval/new session |
| `tools.active` | tools | C,H,P,M | yes | no | yes | Next turn; busy worker must settle |
| `tools.codemode.mode` | tools | P,M | no | no | yes | New session; changes tool-call availability |
| `tools.codemode.inlineBudget` | tools | P,M | no | no | yes | New session; conservative budget prohibition |
| `tools.shell.path` | tools | P,M | no | yes | no | New session; trusted executable repo config |
| `tools.shell.commandPrefix` | tools | P,M | no | yes | no | New session; trusted executable repo config |
| `permissions.projectTrust` | trust | M | no | no | yes | Resource reload; explicit approval rules retained |
| `permissions.macTerminalKey` | connections | M | no | no | yes | Enrollment/revocation, next connection |
| `permissions.defaultProjectTrust` | trust | M | no | no | yes | Next trust decision |
| `permissions.floor` | approvals | M | no | no | yes | Next change; maintainer only |
| `permissions.budget.task` | workers | H | yes | no | yes | New tasks; lower live, raise approved/new admission |
| `run.queue.steeringMode` | run | C,P,M | yes | yes | no | Next delivery boundary |
| `run.queue.followUpMode` | run | C,P,M | yes | yes | no | Next delivery boundary |
| `run.retry.enabled` | run | C,P,M | yes | yes | no | Next request, no replay of accepted prompts |
| `run.retry.maxRetries` | run | C,P,M | yes | yes | no | Next request |
| `run.retry.baseDelayMs` | run | C,P,M | yes | yes | no | Next request |
| `run.retry.provider.timeoutMs` | run | C,P,M | yes | yes | no | Next provider request |
| `run.retry.provider.maxRetries` | run | C,P,M | yes | yes | no | Next provider request |
| `run.retry.provider.maxRetryDelayMs` | run | C,P,M | yes | yes | no | Next provider request |
| `run.transport` | run | C,P,M | yes | yes | no | Next request |
| `run.httpIdleTimeoutMs` | run | C,P,M | yes | yes | no | Next request |
| `run.websocketConnectTimeoutMs` | run | C,P,M | yes | yes | no | Next request |
| `run.httpProxy` | run | M | no | no | yes | Gateway restart; redacted |
| `run.cacheWarming` | run | M | no | no | no | New chat; ordinary runtime only |
| `sources.extensions` | sources | P,M | no | yes | no | Explicit resource reload, never implicit code execution |
| `sources.skills` | sources | P,M | no | yes | no | Resource reload |
| `sources.prompts` | sources | P,M | no | yes | no | Resource reload |
| `sources.themes` | sources | P,M | no | yes | no | Resource reload |
| `sources.packages` | sources | P,M | no | yes | no | Guided package editor/resource reload; trusted code |
| `sources.npmCommand` | sources | M | no | no | no | Next package operation |
| `setup.sessionDir` | setup | M, no writer | no | no | no | Stopped-runtime configuration; hide from Settings |
| `setup.installTelemetry` | setup | M | no | no | no | Next request |

Model-qualified keys: chat thinking, context window, compaction reserve/recent. Dynamic instances:
trust by project, terminal key by device, floors by key/direction. Expanding these is not a new key.
Outside the resolved-key registry: `tools.mcp.server` and `accounts.models.provider` are digest-only
record subjects; `home.profile.item` is a learned-note subject. Keep their guided editors and audit
privacy. Repo MCP credentials are never admitted; preserve repo executable definitions only behind
trust and explicit credential separation. Learned profile notes never become an extra settings layer.

## Effects, inheritance and resets

- Inherited rows mean current Global defaults; no launch snapshot is presented as a live override.
  Runtime admission applies changed defaults only at the declared effect boundary, never mid-stream.
  Pending startup/reload/restart effects are stated on the row; opening/dismissing never changes state.
- Global Reset removes the saved value and uses the release default (or “Not set”); does not clear
  Session or Project values. Session/Profile Revert unsets only that override and inherits Global.
  Explicit override equal to Global still gets Overridden until reverted. All resets use expected
  revisions, tiering, receipts and undo. Lowering a safety floor still needs the maintainer's tap.
- Home workers: retain current bounded admission inheritance, not an ambient Home recipe. Capture
  worker model queue/thinking, subagent queue and task budget at delegation; explicit task choices
  replace that seed; store resulting choices in the worker's Session override. Other worker defaults
  come from Global, not arbitrary Home tool/connection settings. The worker's trusted Project beats
  both seeded and explicit choices. Later Home model/queue edits affect future admissions, not existing
  workers; retain the existing live task-budget lowering boundary (raises never expand an active task).
- `settings` + `taskId` edits that worker's same override store. Model/thinking/Run changes apply next
  request with the existing fenced notification; busy tools/context changes wait. Project-masked
  writes refuse with file/key, so Home cannot inadvertently bypass Project precedence (#1336).
- Home remains hot-reloadable at supported boundaries. Keep its current restricted recipe: no repo,
  no ordinary automatic compaction, no arbitrary shell/extensions. Capability-inapplicable controls
  are omitted rather than pretending to work. The two allowlists grant scopes, not runtime features.
  New applicable Profile bindings use the existing override mechanism, not special per-key layers.
- Home-only worker defaults gain editable Global backing where currently Profile-only. Preserve
  existing Home defaults as overrides. Knowledge background work continues using Global, Home memory
  its Profile override. Coordinate #1593's proposed model-queue note moves; do not invent a fourth queue.
- Keep iPhone preferences device-local, editable under the existing This iPhone group in Global Settings:
  appearance, fonts, dashboard filters/limits and finished-child retention. They affect no agent and
  do not become Gateway keys or synchronize between phones. Haptics currently follow app/system policy;
  do not invent a setting. Local preferences are outside Gateway Changes; device enrollment secrets,
  setup flags, navigation state and last-look cursors are not settings to migrate into the registry.

Device-local settings (S=no, P=no, safety=no, immediate presentation effect; not Gateway layers):

| Key | Group | Current owner / storage |
| --- | --- | --- |
| `appearanceMode` (legacy `appearance.v1`) | This iPhone / Appearance | `AppearanceSettings`, UserDefaults |
| `fontFamily` | This iPhone / Appearance | `FontSettings`, UserDefaults |
| `monoFontFamily` | This iPhone / Appearance | `FontSettings`, UserDefaults |
| `fontAxisValues` | This iPhone / Appearance | `FontSettings`, UserDefaults |
| `subagentRecentFinishedRetentionMinutes.v1` | This iPhone / App Customizations | `AppLocalBehaviorSettings`, UserDefaults |
| `dashboardChatsPerProject.v1` | This iPhone / App Customizations | `AppLocalBehaviorSettings`, UserDefaults |
| `dashboard.serverFilter.preferences.v2` | This iPhone / App Customizations | `DashboardServerFilterPreferences`, UserDefaults |
| `dashboard.automations.preferences.v1` | Dashboard local presentation | Existing Dashboard preferences owner, UserDefaults |
| `dashboard.homeUsage.hiddenProviders.v1` | Dashboard Home usage visibility | Existing Home usage preferences owner, UserDefaults |

## Sheets and removal map

Every settings sheet hides its top drag indicator and follows the shared presentation contract:
managed/progressive presentation, native top-right Done, inherited title/action tint, shared top
chrome and standard detents. No local sheet-style or toolbar replacement; interactive Project
pills and passive Overridden tags reuse the shared control/status owners.

| Surface / owner | Proposed disposition |
| --- | --- |
| Global `SettingsView`, section links/cards | Keep current group styling/order; every setting row editable, never an inspection clone |
| Session `SessionContextSheet`, Home `HomeManageSheet` | One Settings row each; remove competing model/tool settings cards from Manage Session, keep composer shortcuts on same owner |
| `SessionSettingsView` | Replace split inline/editable/Configuration branches with same card/section components as Global; only eligible/applicable keys |
| Inherited / explicit override row | Plain effective Global value / Overridden tag plus existing round Revert; no source badge/link |
| Eligible row masked by Project | Disabled editor; separately tappable “Set by Project settings” pill (accessible while editor disabled) |
| Project pill info | Small sheet: “This is set by the current project's settings. Ask an agent to update them in the repo.” File and exact JSON key path |
| Non-overridable Project keys | One “Set by Project” row/subsheet, read-only actual allowed Project values only; no unrelated Global values |
| Untrusted/disallowed Project values | Diagnostic notice/details, not active Project overrides or disabled Session controls |
| `SettingsConfigurationInspection` | Delete destination, routes and solely-owned fixtures/assertions; no read-only Global Configuration anywhere |
| `SettingsConfigurationGroups` | Retire generic Global inspection; reuse only necessary read-only Project grouping, with Project-specific name |
| `SettingsProvenanceView` / Value & Source in `SettingsRendererRow` | Delete entire sheet, row inspection state/routes and source-only actions; shared editors/formatters stay |
| `TronValueRow` source affordance/hint | Remove settings-only source link/hint; do not change shared sheet chrome (`TronPresentation`, #1631) |
| Session/Home/Project `SettingsChangesLink` | Delete all; Global toolbar is the single Changes entry and sheet |
| Dashboard/New Session Project Settings routes | Reuse one Project read-only content owner; no Changes or inherited Global inspection |
| Mac/Built-in labels in settings/history/tools output | Global for setting origins; keep “built-in extension/tool” product categories (not a layer distinction) |
| `SettingsChangesModels`, `SettingsTarget`, renderer row models | Replace obsolete scope/exclusion tables; keep receipt/fencing owners, not parallel view caches |
| Hosted renderer/configuration fixtures | Delete source-only data/routes; update shared fixtures for retained UI behavior, not wholesale removal |
| UI locks `settings-value-source` (light/dark) | Delete source-only golden/assertion after naming surviving row/pill/undo oracles; explicit approval before golden changes |
| Other settings/admin goldens | Inspect semantic diffs; retain real-boundary locks; no blanket regeneration or unrelated UI updates |

Global Changes filters: scope (Global, session id+title, Home Profile; searchable archived/deleted
session identity), key, group, actor (maintainer/Home/worker task with task/session identity), time,
status. Each entry snapshots scope title/group/key at write so renames/deletion do not orphan filters;
show redacted old→new and Undo or its precise refusal. Preserve pending approvals and receipt fencing.
Project repo edits do not create new Tron settings entries; diagnostics/trust state have their own
owners. Non-repo outside edits to Global remain observed changes. Existing repo history is a real
persisted consumer: recommend retaining historical Project entries and their fenced Undo only in
Global Changes, with a Legacy Project filter. No new Project writes via settings.change; any retained
legacy undo applier may retire only when no retained undoable entry references it (approval below).

## One migration, backup and verification

- Prepare on an isolated copy of real state, never mutate live state in this task. Enumerate settings,
  profile, session JSONLs, audit segments, approvals and observed baselines; hash an automatic backup
  before any mutation. Preserve unknown fields, IDs, titles, timestamps, reasons and redacted data.
- One versioned forward migration of the small shared stores (approvals, audit ledger, Home
  record/Profile), run after the listener binds and before their owners load. Preflight and
  stage replacements; an automatic backup precedes publication; crash recovery completes the same
  transaction; rerun is a no-op. It never fails startup: a refusal changes nothing, logs
  `settings.migration-failed` and retries next start (#1649).
- Session JSONL is never rewritten. `RETIRED_SCOPES` (`kernel/settings/tool-contract.ts`), shared
  by the Session reader and shared-store migration, maps `mac`/`builtin` → Global and
  `chat`/`profile` → Session; the next settings write persists current names. Remove it once no retained
  session predates #1634. The Home record model moves into the Profile when none is saved.
- Preserve saved Global values in their owned stores as Global. Active Home chapter sessions are
  not read or folded; Home's saved choices live in the Profile.
- Explicit/legacy Session values remain overrides; old inherited `mac`/`builtin` frames are
  inheritance from Global. Fixed resource settings retain runtime boundary snapshots, not a new
  user override layer. Unrecognized scope names refuse at read for that session only.
- Migrate audit/approval vocabulary once (including before/after/target references) rather than keep
  dual live schemas. Preserve undo/conflict behavior and pending approvals/expiry; never auto-approve.
  Old titles unavailable in retained metadata show the stable id, not an invented historical title.
- Report before/after parity for Global, Home, existing sessions/workers, per-model instances and undo;
  expected deltas separately enumerate Project precedence and blocked safety settings. Prove second
  run no-op, corrupt input/partial-write recovery, backup restoration on a test copy and no live writes.
- After design approval: actual light/dark simulator previews of every requested sheet, indexed in the
  private packet. After visual approval: real-Gateway precedence, trust, safety, stale-override,
  unavailable-model, inheritance/reset/undo, taskId and migration tests; precise XCUITest row/pill/info
  and Changes filter assertions. Show reproducing RED before GREEN for fixes, preserve E2E artifacts.
- Run relevant tests directly and `scripts/tron verify --changed`; review golden diffs with maintainer.
  Checkpoint/rebase onto active E5 and iOS work, plain Git landing; no install/OTA/restart. Report needed
  Gateway+iOS rebuilds only when all workers have stopped. Product feature-paused kernel seams require
  an existing target owner or a separate maintainer/module decision before implementation.
