# Experimental: running single-file SwiftUI apps (#889)

Off by default behind **Settings › System › Setup › Run Swift files**. The agent writes a
single-file SwiftUI app and presents it with `display`; the phone shows the source in the shared
document sheet and, with the flag on, a play control runs it as a native SwiftUI app in a large
sheet (idea: <https://x.com/ronithhh/status/2102163666422702538>).

## End to end

1. The agent calls `display` with a `.swift` `path` or `internal_file`; the Gateway already
   classifies it as `code` ([display artifacts](display-artifacts.md)).
2. `AttachmentFilePreviewSheet` opens it; with `SwiftAppExperiment` on, `TronDocumentSheet`
   shows a leading **Run <file>** control. Truncated previews never run.
3. `SwiftAppRunnerSheet` parses once (`SwiftAppParser`) and renders through
   `SwiftAppRenderer`; dismissal discards the program and its state.

## Inline mini-app card (#1339)

An **inline** `.swift` display with the flag on shows `SwiftAppDisplayCard` instead of source:
Swift logo, title, caption (else "Swift app") and a play control in the inline card's lavender
glass (`DisplayInlineLayoutPolicy`, `DisplayInlineControlFace`). The card is one button; its
menu keeps **View Source** (with its own Run) and **Tool Details**. It loads through the same
bounded `inlineArtifact(for:)` and `AttachmentFilePreviewPolicy`; a tap presents a `DisplayRoute`
with `runsSwiftApp` (`SwiftAppDisplayRunner` hosts the unchanged runner with the selected
profile's link host). Past the 320,000-byte preview bound it reads "Too large to run · View
Source", a failed load "Unavailable · View Source"; both open the source and never run. Done
discards the program; cards never auto-open, so cache install, reconnect and relaunch replay
nothing; turning the flag off swaps an open runner for the source sheet. No new authority,
feed or storage in source-only previews. Offers use the explicit review below. Canonical mini-app source lives in
[`tools/web/apps/<app-id>/`](../../../tools/web/README.md).

## Tron styling (#909)

The runner is a `TronDocumentSheet`. The program's first real view (after `App`, `WindowGroup`,
custom view structs and a root `TabView`) sits in one `SwiftAppHostStack` with
`tronDocumentSheetChrome`: `TronSheetTitle` (root `navigationTitle`, else the file name) and
Done. The program's outermost `NavigationStack` merges into it (`SwiftAppNavigationStack`); a
root `TabView` gets one host stack per tab with `tabItem`/`badge`/`tag` outside; Lists and Forms
hide their scroll background and carry `tronScrollEdgeChrome`; presented sheets keep their own
stacks. Theme values are environment defaults, so a program's own `font`, `tint`,
`foregroundStyle` and similar modifiers win.

## Folder-backed apps

Gateway membership is `files/apps/<id>/`, with optional app.json and separate
SQLite values under `state/apps/<id>/`. The folder protocol and permission owner
are documented in [Gateway Apps](../../gateway/docs/swift-apps.md).
There is no offer, install review or pending catalog. File removal never clears
saved values. Code/data/feed access belongs to the Gateway's native first-open
consent, not a model-created grant. Unsupported web/network programs are blocked.

The shared Swift interpreter and retained receipt-backed write owner remain the
execution/state boundary; no ambient filesystem, network or native APIs are added.
The Apps catalog UI and paired protocol must be updated together before release.

## Flag

An iPhone-only preference (`ExperimentalSettingsContent`, UserDefaults key
`tron.experimental.swiftApps`) read through the observable `SwiftAppExperiment.shared`, so open
sheets gain or lose the control at once. The launch argument
`-tron.experimental.swiftApps YES|NO` sets the same stored choice:

Use the [iOS development helpers](../../../.agents/skills/tron-ios/SKILL.md) for
simulator/device work; do not bypass their host leases.

## Runtime and safety

`TronSwiftAppEngine` (`SwiftAppEngine/`) owns lexer and AST (`SwiftAppSyntax.swift`), parser,
dynamic values, a tree-walking evaluator, the bounded library and value-to-SwiftUI conversion;
`Sources/UI/SwiftApps/` renders it in Tron's chrome. Each interpreted view struct is a real
`SwiftAppCustomView` whose SwiftUI identity owns its `@State`.

- **No ambient authority.** No file, network, process or native-call surface; names resolve to
  the program's declarations or the fixed builtins (`SwiftAppRuntimeMembers.swift`); no
  reflection, selectors or `AsyncImage`; the only timer is the runtime-owned
  `Timer.publish(every:on:in:).autoconnect()` for `.onReceive`; text renders verbatim; `print` is
  a no-op; `@Environment(\.dismiss)` closes only what the program presented.
- **Links (#1160)** via `SwiftAppLinkPolicy`, only on the host of the profile selected at Run:
  an `itms-services://?action=download-manifest&url=…` whose manifest is `https` on that host
  (straight to the system prompt), or an `https` page there after an **Open link?** alert.
  V2 additionally requires an exact manifest from the installed feed and an explicit
  native user action; lifecycle/timer/change callbacks cannot open an OS install.
  Source-only/v1 previews retain their named host policy. Refused links diagnose or
  roll back; admitted links open only after action commit. Other environment keys diagnose.
- **Diagnostics.** Unsupported syntax is collected per construct with its line, stopping at 10
  (saying more may remain); no partial program runs; lexer, delimiter and nesting errors are
  fatal. A failing view statement is isolated so siblings and ForEach rows keep rendering; value
  functions and actions still throw. Diagnostics use `TronInfoCard`.
- **Transactions.** Actions (`onAppear`, `onChange`, gestures) journal first writes at their
  storage owners; a budget stop or thrown error restores every written slot (nested state,
  bindings, arrays, dictionaries, `@Published`, aliased objects, globals) and shows "Action
  cancelled; state restored". Native dismiss waits for commit; direct control writes are single
  updates.

Every entry from SwiftUI runs under one work budget and never hangs or crashes the app:

| Limit | Value | Owner |
| --- | --- | --- |
| Steps / wall clock | 2,000,000 / 2 s per entry | `SwiftAppRuntime.tick` |
| Interpreted call depth | 160 | `SwiftAppRuntime.enterCall` |
| Native stack headroom | 256 KB reserved | `SwiftAppStackGuard` |
| Syntax nesting | 256 levels | `SwiftAppParser.nest` |
| Nested interpreted view structs | 48 | `SwiftAppCustomView.maximumDepth` |
| Array, range, characters / dictionary | 100,000 elements / entries | `SwiftAppRuntime.admit`, `checkDictionaryCount` |
| String | 1,000,000 UTF-8 bytes | `SwiftAppRuntime.admit` |
| Composite description | 10,000 characters | `SwiftAppValue.display` |
| Format width or precision | 64 | `SwiftAppFormat` |
| Timers | ≥ 0.1 s, 8 per runner, stop after 3 consecutive failures | `SwiftAppRuntime` |

New arrays, dictionaries and strings are charged by size; writeback charges the possible copy.
Trapping arithmetic (`Int.min / -1`, `Int(Double.nan)`, `abs(Int.min)`) reports overflow;
`+ - *` wrap. `String(format:)`/`specifier:` pair each conversion with a matching argument type
(`*` widths, positional arguments and `%n` rejected). Sizes clamp to ±10,000 points. Known
limits: budgets are per entry (two seconds per body or action can block the main thread);
self-triggering `onChange`/`onAppear` can loop at run-loop pace; retained memory across actions
is bounded only per value; closure cycles may leak; device stack protection is
simulator-validated.

## Supported subset

- **Declarations:** `@main` App with `WindowGroup`, view structs, value structs (memberwise
  init, `mutating func`), `ObservableObject` classes, enums (raw values, `CaseIterable`,
  computed properties, methods), top-level `let`/`var`/`func`; generic clauses and `where`
  are erased (no static checking), explicit specialization accepted. One synchronous,
  nonfailable `init` per struct or class (defaults required; no overloads, delegation,
  convenience, failable, throwing, async, view/App initializers or deinitializers).
- **Enum payloads:** positional or labeled, nested to 64; `case let`, nested patterns,
  wildcards and alternatives bind per branch; qualified patterns without bindings compare.
  Payload cases are not keys and have no `allCases`; implicit cases must be unambiguous; a
  SwiftUI argument such as `.pickerStyle(.segmented)` still reads the native symbol.
- **Property wrappers:** `@State`, `@Binding`, `@StateObject`, `@ObservedObject`, `@Published`,
  `@EnvironmentObject` with `.environmentObject(_:)`; `$name`, `$item.field`, `ForEach($items)`.
- **Statements:** `let`/`var`, (compound) assignment, `if`/`else`, `if let`, `guard`,
  `for … in … where`, `while`, `switch` (lists, ranges, `default`), `return`, `break`,
  `continue`.
- **Expressions:** literals, interpolation with `specifier:`, arithmetic, comparison, logic,
  ternary, `??`, ranges, arrays, tuples, closures (`$0`, named), key paths, operator references.
- **Library:** common `Array`, `String`, `Int`, `Double` members, `Optional.map`/`flatMap`,
  `min`, `max`, `abs`, `random(in:)`, `String(format:)`, `UUID()`, `withAnimation`.
- **Dictionaries:** literals, `Dictionary()`, `Dictionary(grouping:by:)`, optional and default
  subscripts with nested writeback (default reads never insert; `dict[key] = nil` removes);
  keys are String, Int, Bool or payload-free enum cases; value semantics, unspecified order;
  `keys`, `values`, `count`, `isEmpty`, `contains(where:)`, `map`, `filter`, `mapValues`,
  `sorted`, `forEach`, tuple destructuring. `ForEach` needs an array. Optional chaining skips
  the rest of its postfix chain (no later evaluation or insertion); keys and receivers evaluate
  once; postfix `!` on nil diagnoses.
- **Protocols:** requirements, associated types and constraints are parsed and erased;
  existentials dispatch dynamically; no conformance checks, default implementations or
  protocol extensions (those diagnose); extensions must target a concrete declared type.
- **Geometry:** `GeometryReader` with read-only `size` and `frame(in: .local)` snapshots
  (clamped 0…10,000, compared by value); global and named spaces and safe-area geometry
  diagnose.
- **Views:** Text, Label, Image(systemName:), Button, Toggle, TextField, SecureField, Stepper,
  Slider, ProgressView, Picker, V/H/Z (and lazy) stacks, LazyVGrid, ScrollView, List, Form,
  Section, Group, GroupBox, DisclosureGroup, NavigationStack, NavigationLink, Link, TabView,
  ForEach (`onDelete`/`onMove`), Spacer, Divider, Color, basic shapes, ContentUnavailableView.
- **Modifiers:** layout, typography, colors, tint, backgrounds, overlays, clip shapes, shadows,
  navigation titles, control styles, `sheet`, `alert`, `toolbar`, `swipeActions`, `searchable`,
  `tabItem`, `badge`, `onAppear`, `onTapGesture`, `onChange`, `onReceive` (timer),
  `disabled`, accessibility identifiers and labels.

Not supported: Swift Concurrency (`async`/`await`, `.task`; #1140), other frameworks,
custom `ViewModifier`s.

## Installed-state engine port

`SwiftAppPersistence` accepts an installed app's bounded JSON snapshot and emits one batch
of changed keys after a successful synchronous action, including native binding writes.
`@AppStorage("key")` supports Bool, Int, Double and String defaults. `@Persisted("key")`
(or `@Persisted`, keyed by `Type.property`) supports arrays/dictionaries containing finite
scalars and value structs; dictionary keys are String, Int or Bool. Persistent wrappers
require non-static View/App variables and literal keys. Shared keys share one observable
slot; incompatible scalar/container declarations diagnose. Constructors, serialization,
size refusal and failed actions share the existing rollback journal and emit no batch.
Opening only restores defaults; it never writes them. Chat displays have no installed
identity and diagnose rather than silently pretending to save.

Scalar entries are ordinary JSON; integers must fit JSON's exact ±(2^53−1) range.
Collections use the engine's version-1 typed envelope
(`version`, `value`), preserving numeric, dictionary-key and struct identity; changed struct
fields or an unknown collection format refuse restoration. This is app-owned JSON inside
the existing app store, not a store-format migration. Existing key/value bounds apply.
[`Features/SwiftApps/State`](../Sources/Features/SwiftApps/State/README.md) owns the host
transport and retained write lifecycle. `AppModel` composes pinned-connection reads and
receipt-backed mutations; `apps.open` loads source/state coherently and every interpreter
commit fences source and state revisions. `SwiftAppRunnerSheet` injects the port only when
its launch supplies that installed session. Closing stops timers, not accepted writes;
unsaved/failed changes remain owned and appear in the existing notice/error surfaces.
Clean reopens read the Gateway afresh. Presented program versions remain owned until
closed, so another clean reader cannot orphan a writer. Manage rechecks unresolved
writes after awaits; accepted install work also blocks conflicting management.

## Apps catalog

The Tron menu opens `InstalledAppsSheet`. Folder membership is independent of
saved values and of the chat Run Swift files setting. Native accesses must use
`apps.catalog`, exact-content `apps.open` and the Gateway's permission result.
The old registry list and install-review flows are not available. Client file
deletion is outside this release; saved-value clearing requires separate approval.

The Gateway runtime suite compiles
[`PersistenceBoundaryMain.swift`](../../gateway/src/modules/apps/fixtures/PersistenceBoundaryMain.swift)
with the real engine, applies batches through Gateway receipts and restores a
fresh native process/Gateway. This is not an iPhone UI persistence proof.

## Recovered Builds preview (#1319)

[`tools/web/apps/builds-preview/BuildsPreview.swift`](../../../tools/web/apps/builds-preview/README.md)
is the canonical runnable historical snapshot of the Builds design (#1156, #1162): mode
filters, search and a notes/metadata destination over recorded rows, with an inert disabled
Install and no host URL or credentials; it cannot build, install or restart anything. The UI
test bundle hands its exact bytes to the hosted fixture (`TRON_HOSTED_SWIFT_APP_SOURCE`). Try it
by displaying the file (inline card or sheet) with the flag on: switch modes, open a row, search
`1112` and a nonexistent title; Install stays disabled; Done and rerun reset the state.

## Apps design review fixture

`HostedAppsDesignFixture` (`-tron-apps-design-fixture`, hosted builds only) composes the
shared list/group/feed, tags, Manage rows, metadata table and document sheets for review.
Its catalog, state and history are synthetic proposals, not installed-app RPC projections.
Only its Swift row launches the existing interpreter; the HTML rows open proposed metadata,
not an implemented web backend. It writes no app data and runs no migrations.

`TronAppsDesignUITests` captures Apps and Manage in light/dark and default/Accessibility
XXXL. `-apps-design-expanded` selects the shared large detent for still captures; the normal
fixture and interaction journey start medium. XXXL Manage captures include a scrolled
continuation so a first-viewport image does not imply that all rows fit at once. The focused
`testCaptureAppsManage…` journeys omit the independent Automations comparison; the original
comparison journeys remain available separately. Its interaction journey opens the real
interpreter, returns through Manage and Data, then continues the shared feed. It does not prove
installed persistence, provenance or HTML launch. No production Apps menu entry is enabled by
this fixture.

```bash
scripts/tron-ios-test run --only-testing TronMobileUITests/TronAppsDesignUITests
```

## Validation

Hosted journeys in `TronSwiftAppUITests` run the programs in `HostedSwiftAppFixtureSource`
through the read-only attachment fixture (`-readonly-preview-scenario display-swift…`):
inline card open/replay and bounded states (#1339), the recovered Builds preview (#1319), model
initialization and rollback, enum payloads, protocols and geometry, refused protocol
extensions, optional chaining, timers, `habits` (generics, bindings, pickers), dictionaries,
the flag and truncation gate, `budget` (shared store, tabs, dismissal, the link policy at the
fixture's `OpenURLAction`), the live Settings switch, contained failures (`broken`, nesting
limit, `limits` with loops, recursion, overflow, hostile formats, rollback) and sibling-
preserving diagnostics. `assertToolbarTint` checks the hosted chrome. Screenshots are labelled
simulator evidence on fixture data.

```bash
scripts/tron-ios-test build
scripts/tron-ios-test run --only-testing TronSwiftAppUITests/TronSwiftAppUITests
```
