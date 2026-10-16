# Experimental: running single-file SwiftUI apps (#889)

Status: experimental prototype, off by default behind a flag that Settings › Tools & Diagnostics › Experimental can turn on.

The idea comes from an X post by @ronithhh: a Swift interpreter that runs native,
fully interactive iOS apps directly from a `.swift` file
(<https://x.com/ronithhh/status/2102163666422702538>). In Tron, the agent writes a
single-file SwiftUI app and presents it with `display`. The phone shows the
source in the shared document sheet and, when the flag is on, a play control
runs that file as a native SwiftUI app in a large sheet.

## End to end

1. The agent writes `Habits.swift` and calls `display` with a `path` or
   `internal_file` source. The Gateway already classifies `.swift` as a `code`
   artifact; no Gateway change is involved.
2. iOS opens the artifact in `AttachmentFilePreviewSheet`
   ([display artifacts](display-artifacts.md)).
3. When `SwiftAppExperiment` allows it, `TronDocumentSheet` shows a leading
   play control (`Run Habits.swift`). Truncated previews never run.
4. `SwiftAppRunnerSheet` parses the file once (`SwiftAppParser`) and renders the
   root view through `SwiftAppRenderer`. Dismissing the sheet discards the
   program and its state.

## Tron styling (#909)

A plain file looks like Tron with no styling code. The runner is a
`TronDocumentSheet` (shared detents, sheet material, `tronPresentation`
typography and the sheet's tint). The program's first real view, after its
`App`, `WindowGroup`, custom view structs and a root `TabView`, sits in a
`SwiftAppHostStack`. That is one NavigationStack with the shared
`tronDocumentSheetChrome`: a `TronSheetTitle` and a Done control that closes the
runner. The title is the program's root `navigationTitle`, else the file name.

- The program's own outermost `NavigationStack` merges into that stack
  (`SwiftAppNavigationStack`), so its title, toolbar items and pushes use the
  sheet's bar.
- A root `TabView` gets one host stack per tab, with the tab's
  `tabItem`/`badge`/`tag` kept outside it. A stack around the TabView would hide
  each tab's toolbar.
- Lists and Forms hide their scroll background so the sheet material shows,
  and Lists, Forms and ScrollViews carry `tronScrollEdgeChrome`.
- Sheets and destinations the program presents keep their own NavigationStacks.

Theme values are environment defaults set above the program. A program's own
`font`, `tint`, `foregroundStyle`, `scrollContentBackground` or
`navigationBarTitleDisplayMode` is applied closer to its views and wins.

## Flag

Off by default; without it `.swift` artifacts are unchanged. Turn it on from
the iPhone in **Settings › Tools & Diagnostics › Experimental › Run Swift files**
(`ExperimentalSettingsView`). It is an iPhone-only preference with no Gateway
setting behind it, stored under the UserDefaults key
`tron.experimental.swiftApps`. The change applies at once: an open `.swift`
sheet gains or loses its run control without a relaunch, because the sheet
reads the observable `SwiftAppExperiment.shared` rather than UserDefaults.

The launch argument `-tron.experimental.swiftApps YES` (or `NO`) still sets the
same stored choice, so later normal launches keep it and the Settings switch
shows and can change it.

```bash
# Simulator (Development build)
xcrun simctl launch booted com.tron.mobile.beta -tron.experimental.swiftApps YES
# Physical device (Tron Device / LocalDevice build)
xcrun devicectl device process launch --device <device-id> --terminate-existing com.tron.mobile -tron.experimental.swiftApps YES
```

## Runtime and safety

`Sources/UI/SwiftApps/` owns the interpreter: lexer and AST
(`SwiftAppSyntax.swift`), parser, dynamic values, a tree-walking evaluator, the
bounded standard library, and native rendering. Each interpreted view struct is
a real `SwiftAppCustomView` whose SwiftUI identity owns that instance's
interpreted `@State`, so state follows the normal SwiftUI lifecycle.

The interpreter has no file, network, process, or native-call surface. A
program can only build views and change its own interpreted state: names
resolve to the program's own declarations or to a fixed list of builtins
(`SwiftAppRuntimeMembers.swift`), and there is no reflection, selector, URL,
`Link`, or `AsyncImage`. The only timer is the runtime-owned, bounded
`Timer.publish(every:on:in:).autoconnect()` source used by view-lifetime
`.onReceive`; it has no arbitrary scheduler or background execution. Text renders verbatim, so Markdown
links never open URLs. `print` is a no-op. `@Environment(\.dismiss)` closes
the presentation the program created around that view (its `sheet` or a
`NavigationLink` destination, through `SwiftAppPresentedContent`); in the
program's root view it does nothing, so a program never closes the runner.
Unsupported syntax is collected at grammar-owned boundaries (unsupported initializer
forms, deinitializers, unsupported extensions, type checks and async/await),
with a construct name and
source line for each. At 10 diagnostics parsing stops and explicitly says more
may remain. No partial program runs. Lexer errors, malformed delimiters and
nesting exhaustion remain fatal rather than guessing a recovery boundary.

View-builder bodies and native container content isolate a runtime failure to
its failing statement, preserving earlier and later working siblings, including
nested stacks and ForEach rows. A work-budget stop preserves completed siblings
but does not refill the budget to attempt the rest of that entry. Ordinary value
functions and action closures still throw to their caller; containment never
converts a failed action into a successful commit. Calling a property as a method
names that property rather than just printing its dynamic value. Diagnostics reuse the
shared `TronInfoCard` with semantic error accent, typography and glass surface;
the runner keeps `tronDocumentSheetChrome`.

Actions (including `onAppear`, `onChange`, and gesture callbacks) are
transactional. A budget stop or any thrown runtime error restores every written
interpreted storage slot to its pre-action value before showing
“Action cancelled; state restored” and the cause over the app (with its source
line when available).
This includes nested/derived state, projected `@Binding` values, arrays, dictionaries,
`@Published` and aliased object fields, globals and static storage. The runtime
journals first writes at storage owners, so reference identity is preserved;
rollback does not evaluate code or spend the exhausted budget. Native dismiss
effects wait until commit. A successful action commits all writes and clears
the previous action error. Direct native control binding writes remain single
slot updates; their subsequent `onChange` is a separate action.

Every entry from SwiftUI (a view body, an action, a container's content
closure) runs under one work budget. Exhausting any limit stops that entry
with a diagnostic; it never hangs or crashes the app.

| Limit | Value | Owner |
| --- | --- | --- |
| Steps | 2,000,000 per entry | `SwiftAppRuntime.tick` |
| Wall clock | 2 s per entry | `SwiftAppRuntime.tick` |
| Interpreted call depth (functions, closures, computed properties) | 160 | `SwiftAppRuntime.enterCall` |
| Native stack headroom (evaluator and parser) | 256 KB reserved | `SwiftAppStackGuard` |
| Syntax nesting (bounds AST depth) | 256 levels | `SwiftAppParser.nest` |
| Nested interpreted view structs | 48 | `SwiftAppCustomView.maximumDepth` |
| Array, range, or string-as-characters | 100,000 elements | `SwiftAppRuntime.admit`, `SwiftAppValue.asArray` |
| Dictionary | 100,000 entries | `SwiftAppRuntime.checkDictionaryCount` |
| String | 1,000,000 UTF-8 bytes | `SwiftAppRuntime.admit` |
| Composite value description | 10,000 characters | `SwiftAppValue.display` |
| Format width or precision | 64 | `SwiftAppFormat` |
| Timer interval | at least 0.1 s | runtime-owned timer subscription |
| Live timer subscriptions | 8 per runner | `SwiftAppRuntime` |
| Consecutive failed timer callbacks | 3 before stopping that subscription | `SwiftAppRuntime` |

Each newly produced array, dictionary or string is charged to the step budget by
size, so one entry allocates a bounded amount. Dictionary projections and tuple
iteration charge before materialization; value-semantic writeback charges the
possible full copy, and scalar hashing pays for key length. Grouping owns unique
native builder storage and appends in place, without quadratic group copies. Integer arithmetic and conversions that
would trap in Swift (`Int.min / -1`, `Int(Double.nan)`, `abs(Int.min)`,
`b + 1` in `a...Int.max`) report an overflow instead; `+`, `-`, and `*` wrap.
`String(format:)` and `specifier:` go through `SwiftAppFormat`, which pairs
each conversion with an argument of the right dynamic type, so a format such as
`%s` or `%@` can never make Foundation read a number as a pointer; `*`
widths, positional arguments and `%n` are rejected. Frame, padding, font and
other sizes are clamped to ±10,000 points.

Remaining limits, by design of this prototype:

- Budgets are per entry, not per app. A program can keep the main thread busy
  for up to two seconds per action or body, and a list of many expensive rows
  multiplies that. Arrays are copied on mutation, so appending thousands of
  items in one action reaches the step budget.
- An `onChange` that changes its own value, or `onAppear` that re-presents
  itself, can loop at the run loop's pace without blocking it. Timer callbacks
  are capped per runner, run as ordinary budgeted transactions, stop after
  three consecutive failures, and are cancelled with their view or runner.
- Memory retained across many separate actions is bounded only by the
  per-value limits and the user's taps.
- Closures can form reference cycles with their scopes; they are released
  when the program's last view goes away only if no cycle holds them.
- Physical-device stack size (1 MB main thread) is protected by the stack
  guard but has been validated only on the simulator.

## Supported subset

- **Declarations:** `@main struct …: App` with `WindowGroup`, view structs,
  value structs (memberwise init, `mutating func`), classes used as
  `ObservableObject` stores, and enums with cases, raw values, `CaseIterable`,
  computed properties, and methods. Top-level `let`, `var`, and `func` are
  supported. Generic parameter clauses and `where` constraints on functions
  and structs are accepted as documentation and erased dynamically; they do
  not provide static type checking. Explicit generic specialization such as
  `identity<Int>(value)` is accepted for declared generic functions.
- **Model construction:** structs/classes may declare one synchronous, nonfailable
  `init`, with positional/labeled arguments and defaults. It replaces memberwise
  construction. Every stored field needs a declared default or initializer assignment;
  missing slots, extra arguments and returning a value diagnose. Partially initialized
  `self` cannot escape. Constructors share the existing action journal, or own its
  outer transaction when invoked outside an action. Native view-state initialization
  failures use the existing error/chrome presentation, never silent nil state.
  View/App initializers, overloads, delegation, convenience/failable/throwing/async
  initializers and deinitializers remain unsupported. No reflective/native construction.
- **Enum payloads:** cases may carry positional or labeled values, including nested
  enums. Construction checks labels/arity; immutable values include their declaring
  type, and structural equality is budgeted. Descriptions use the bounded writer.
  Retained payload nesting (including arrays/dictionaries/records) is capped at 64.
  `case let .count(value)`, `.message(let text)`, nested cases, wildcards and
  alternatives bind only within the selected branch. Case-only patterns such as
  `.count` ignore payloads; explicit empty or malformed lists diagnose, including
  on a nonmatching case. Raw values and synthesized `allCases` remain payload-free
  only; payload cases are not dictionary keys and have no synthesized ordering. Implicit cases must be unambiguous; qualify conflicting
  cases/native symbols because there is no static contextual type inference.
- **Property wrappers:** `@State`, `@Binding`, `@StateObject`,
  `@ObservedObject`, `@Published`, and `@EnvironmentObject` with
  `.environmentObject(_:)`. `$name`, `$item.field`, and `ForEach($items)` work.
- **Statements:** `let`/`var`, assignment and compound assignment, `if`/`else`,
  `if let`, `guard`, `for … in … where`, `while`, `switch` (cases, lists,
  ranges, `default`), `return`, `break`, and `continue`.
- **Expressions:** literals, string interpolation (including `specifier:`),
  arithmetic, comparison, logic, ternary, `??`, ranges, arrays, tuples,
  closures (`$0`, named parameters), key paths, and operator references such as
  `reduce(0, +)`.
- **Library:** common `Array`, `String`, `Int`, and `Double` members
  (`filter`, `map`, `reduce`, `sorted`, `contains`, `append`, `remove`,
  `firstIndex`, `first(where:)`/`first { … }`, `enumerated`, `joined`,
  `uppercased`, `formatted`, …), `Optional.map`/`flatMap` (nil stays nil; a
  non-collection value is passed to the closure, while arrays, ranges and strings
  keep their own `map`),
  `min`, `max`, `abs`, `random(in:)`, `String(format:)`, `UUID()`, and
  `withAnimation`.
- **Dictionaries:** `[:]`, key/value literals, annotations and `Dictionary()`;
  `Dictionary(grouping:by:)`; optional and lazy-default subscripts, including
  compound assignment and nested mutating writeback. Plain missing-key reads
  return nil; default reads never insert. Direct `dict[key] = nil` removes the
  entry, but a nested nil field or `dict[key, default: …] = nil` preserves it.
  Keys are immutable tagged String, Int, Bool or payload-free enum cases (enum
  identity follows the runtime's existing case-name semantics). Mutable keys and
  duplicate literal keys diagnose. Copies have value semantics; order is
  unspecified, so sort keys/entries when presentation order matters.
  `keys`, `values`, `count`, `isEmpty`, `contains(where:)`, `map`, `filter`,
  `mapValues`, `sorted` and `forEach` are supported, along with flat tuple
  destructuring in loops and closures. `filter`/`mapValues` retain a dictionary;
  `map`/`sorted` produce arrays. Keys/defaults in compound or mutating writeback
  are evaluated at most once. Native `ForEach` requires an array (for example,
  sorted keys/entries or `Array(dict)`), not a dictionary or dictionary binding.
  Optional chaining (`?`) skips the remainder of that postfix chain when its
  marked receiver is nil: later keys, arguments, defaults and assignment RHSs do
  not run, and missing dictionary entries are not inserted. Parentheses and `??`
  terminate that chain; a skipped result becomes ordinary nil, not a stored skip
  marker. Calls resolve their receiver/callee before arguments. Keys, defaults
  and computed receivers are evaluated once per operation, including mutating
  writeback. Function-returned class references remain writable without rerunning
  the receiver. Postfix `!` diagnoses nil rather than silently reading through it.
  Genuine failures still roll back the whole action. Use default subscripts when
  inserting through nested writeback; setting a nil field on a present value
  retains its dictionary entry.
- **Protocols:** property requirements (`get` or `get set`), method signatures,
  associated-type declarations and inheritance/constraint syntax are parsed and
  erased as documentation. Existential annotations such as `[any Shape]` contain
  concrete interpreted values whose existing members dispatch dynamically. There
  is no conformance checking, protocol default implementation, initializer or
  subscript requirement support. Extensions must target a concrete type already
  declared in the file; protocol/native/forward extensions diagnose instead of
  silently dropping their bodies. Missing concrete members diagnose at runtime
  rather than turning into placeholder functions. Binding projections require an
  existing stored field; invalid projections diagnose before construction without
  running computed getters. Views still declare `View` directly; protocol
  inheritance does not make a model into a native view. Malformed requirements
  and excessively nested signatures stop parsing rather than hiding a body.
- **Geometry:** `GeometryReader { proxy in ... }` uses native layout and the same
  bounded lazy-content entry as other containers. Each layout supplies immutable
  `size.width`/`height` and `frame(in: .local)` snapshots. Local rects expose
  `origin`, `size`, `width`/`height`, `minX`/`minY`, `maxX`/`maxY`, and `midX`/`midY`;
  origin exposes `x`/`y` (zero). Dimensions are finite and clamped to 0...10,000.
  These values are read-only, not native proxy references; snapshot equality and
  descriptions include their dimensions, so `onChange(of: proxy.size)` observes
  resizing rather than a constant type name. Global/named coordinate
  spaces and safe-area geometry are unsupported; writes and unsupported frame
  requests diagnose and roll back the action. Layout changes reevaluate content
  without changing the existing runner chrome.
- **Views:** Text, Label, Image(systemName:), Button, Toggle, TextField,
  SecureField, Stepper, Slider, ProgressView, Picker, V/H/Z stacks (and lazy
  forms), LazyVGrid, ScrollView, List, Form, Section, Group, GroupBox,
  DisclosureGroup, NavigationStack, NavigationLink, TabView, ForEach (with
  `onDelete`/`onMove`), Spacer, Divider, Color, basic shapes, and
  ContentUnavailableView.
- **Modifiers:** layout (padding, frame, offset), typography, colors, tint,
  backgrounds and overlays, clip shapes, shadows, navigation titles, button,
  list, picker, and text field styles, `sheet`, `alert`, `toolbar`,
  `swipeActions`, `searchable`, `tabItem`, `badge`, `onAppear`,
  `onTapGesture`, `onChange`, `onReceive` with the supported timer publisher,
  `disabled`, and accessibility identifiers and
  labels.

Not supported: initializer forms excluded above, `async`/`await` tasks, Swift Concurrency or synchronous `.task` closures,
frameworks other than SwiftUI (WeatherKit, CoreLocation, networking), persistence,
and custom `ViewModifier`s. Generic parameter, constraint and protocol syntax is
statically unchecked as described above. Bounded `.task`/`Task.sleep` continuations
remain tracked in #1140; timer support does not enable them.

## Validation

Hosted XCUITest journeys in `TronReadonlyAttachmentUITests` display the
sources in `HostedSwiftAppFixtureSource` through the readonly attachment
fixture (`-readonly-preview-scenario display-swift…`):

- `testDisplayedSwiftModelsInitializeAndRollback` exercises model defaults/arguments,
  value/reference rollback, incomplete and bootstrap initialization, and malformed
  initializer/pattern syntax.
- `testDisplayedSwiftEnumPayloadsBindAndStayBounded` exercises constructor identity,
  computed properties, nested bindings, descriptions, and rollback after payload
  depth, label, arity and pattern errors.
- `testDisplayedSwiftProtocolsAndGeometryUseConcreteValues` runs concrete
  existential model dispatch and native geometry resizing, proves local/read-only
  enforcement with action rollback, snapshot equality/change identity, optional
  map preservation, missing concrete members, and malformed/deep signatures.
- `testSwiftProtocolExtensionsCannotSilentlyDisappear` refuses a program with a
  protocol default implementation instead of silently discarding its extension.
- `testDisplayedSwiftOptionalChainSkipsMissingLinks` proves skipped arguments,
  keys/defaults/RHSs, optional closures and mutating writeback, postfix grouping,
  forced-nil failure, computed reference receiver ordering, and action rollback.
- `testDisplayedSwiftTimerTicksAndStopsWithRunner` runs the `timer` stopwatch
  through the real readonly attachment preview and exercises its subscription
  limits, failure-stop and runner-dismissal cancellation.
- `testDisplayedSwiftFileRunsAsInteractiveAppBehindExperimentFlag` runs
  `habits`: dynamically erased generic function/struct syntax, a forward
  explicit specialization, `Array<Int>()`, and a less-than expression render
  and reevaluate alongside the existing `@Binding`, segmented `Picker`, and
  `TextField` interactions.
- `testDisplayedSwiftDictionaryAppGroupsAndTalliesItems` runs a grouped list
  and tally with enum keys, then exercises integer/Bool keys, lazy/default
  writeback, nested nil, independent copies and tuple transforms. Invalid keys,
  copy-budget exhaustion and entry overflow must diagnose
  and roll back the whole action without changing the successful state.
- `testSwiftRunControlRequiresFlagAndCompletePreview` proves that with the flag
  off the `.swift` sheet is the ordinary document sheet (no run control, large
  detent, Done dismisses), and that a preview truncated at the text limit never
  offers to run.
- The `habits`, `budget` and `limits` journeys also check the hosted chrome
  with `assertToolbarTint`. The shared title (the program's root
  `navigationTitle`, or the file name for `limits`) carries a Done inked in the
  title's tint, so a runner that draws its own chrome fails. Done closes the
  runner back to the document. Each tab of `budget`'s root TabView has the
  chrome and keeps its own toolbar.
- `testDisplayedSwiftStoreAppSharesStateAcrossTabs` runs `budget`: an
  `ObservableObject` store shared through `environmentObject`, `TabView`,
  `List`, an enum `switch`, `String(format:)`, `Optional.map` on a value and on
  `first { … }`'s nil, then `dismiss()` popping a
  `NavigationLink` destination, closing the program's own sheet after its
  save action, and doing nothing in the root view (#1027).
- `testSettingsSwitchAddsAndRemovesSwiftRunControlLive` starts with the
  runner off, turns it on in Settings › Tools & Diagnostics › Experimental and runs
  the displayed file, then turns it off and sees the run control gone, all in
  one launch.
- `testSwiftAppFailuresStayContainedInTheRunner` runs `broken` (line-numbered
  unsupported syntax), a file nested past the parser limit, and `limits`: an
  unsupported view, an infinite loop, unbounded recursion, unbounded string
  growth, a self-reading computed property, `Int.min / -1`, comparing and
  describing a value with 2^40 shared leaves, a hostile format string, and a
  view that contains itself. Each ends in a diagnostic or a bounded value while
  the app stays responsive. The same journey verifies rollback of nested binding
  records/arrays, derived totals, published arrays and aliased object fields on
  budget failure; scalar state and object writes on arithmetic failure; successful
  commit afterward; and the shared info card’s primary text ink and visible bounds.

- `testSwiftDiagnosticsPreserveSiblingViews` verifies named, line-numbered
  failures between working stack children and ForEach rows, then verifies that
  the same failing value helper still rolls an action back.
- `testSwiftUnsupportedDiagnosticsAreBoundedAndMalformedSyntaxStops` verifies
  the 10-diagnostic cap, no execution of a partial parse, and fatal malformed
  delimiters. The existing failure journey verifies multiple unsupported
  constructs within the same declaration and across declarations in one report.

```bash
scripts/tron-ios-test build
scripts/tron-ios-test run \
  --only-testing TronMobileUITests/TronReadonlyAttachmentUITests/testDisplayedSwiftFileRunsAsInteractiveAppBehindExperimentFlag \
  --only-testing TronMobileUITests/TronReadonlyAttachmentUITests/testSwiftRunControlRequiresFlagAndCompletePreview \
  --only-testing TronMobileUITests/TronReadonlyAttachmentUITests/testDisplayedSwiftStoreAppSharesStateAcrossTabs \
  --only-testing TronMobileUITests/TronReadonlyAttachmentUITests/testSwiftAppFailuresStayContainedInTheRunner \
  --only-testing TronMobileUITests/TronReadonlyAttachmentUITests/testSettingsSwitchAddsAndRemovesSwiftRunControlLive \
  --only-testing TronMobileUITests/TronReadonlyAttachmentUITests/testSwiftDiagnosticsPreserveSiblingViews \
  --only-testing TronMobileUITests/TronReadonlyAttachmentUITests/testSwiftUnsupportedDiagnosticsAreBoundedAndMalformedSyntaxStops
```
