# Experimental: running single-file SwiftUI apps (#889)

Prototype status: behind a flag, not merged, awaiting review.

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

## Flag

Off by default; without it `.swift` artifacts are unchanged. Launch the app once
with the argument `-tron.experimental.swiftApps YES` to enable it. The choice is
recorded under the UserDefaults key `tron.experimental.swiftApps`, so later
normal launches keep it; launching with `NO` turns it off.

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

The interpreter has no file, network, process, or native-call surface. A program
can only build views and change its own interpreted state. A step budget and a
recursion-depth budget turn runaway programs into a diagnostic. Unsupported
syntax shows a readable message with its line number instead of running.
Unsupported modifiers are ignored, and unsupported views render an inline
diagnostic.

## Supported subset

- **Declarations:** `@main struct …: App` with `WindowGroup`, view structs,
  value structs (memberwise init, `mutating func`), classes used as
  `ObservableObject` stores, and enums with cases, raw values, `CaseIterable`,
  computed properties, and methods. Top-level `let`, `var`, and `func` are
  supported.
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
  `firstIndex`, `enumerated`, `joined`, `uppercased`, `formatted`, …),
  `min`, `max`, `abs`, `random(in:)`, `String(format:)`, `UUID()`, and
  `withAnimation`.
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
  `onTapGesture`, `onChange`, `disabled`, and accessibility identifiers and
  labels.

Not supported: custom `init`, enums with associated values, generics,
protocols with requirements, dictionaries, `async`/`await` tasks, Swift
Concurrency, frameworks other than SwiftUI (WeatherKit, CoreLocation,
networking), persistence, and custom `ViewModifier`s.

## Validation

The hosted XCUITest journey
`TronReadonlyAttachmentUITests/testDisplayedSwiftFileRunsAsInteractiveAppBehindExperimentFlag`
displays `HostedSwiftAppFixtureSource.habits`. It first proves the run control
is absent without the flag. With the flag, it runs the app and checks state
changes through `@Binding`, segmented `Picker` filtering, and `TextField` input
with an array append.

```bash
scripts/tron-ios-test build
scripts/tron-ios-test run --only-testing TronMobileUITests/TronReadonlyAttachmentUITests/testDisplayedSwiftFileRunsAsInteractiveAppBehindExperimentFlag
```
