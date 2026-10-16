#if HOSTED_TEST
/// The single-file SwiftUI apps the #889 run journeys display and run. They
/// are ordinary SwiftUI source, the kind an agent writes and presents with
/// `display`; docs/swift-apps.md describes the supported subset.
enum HostedSwiftAppFixtureSource {
    /// The file a `display-swift…` scenario displays: its name and source.
    static func file(for scenario: String) -> (name: String, source: String)? {
        guard scenario.contains("display-swift") else { return nil }
        if scenario.contains("model-malformed-init") {
            return ("MalformedInitializer.swift", "import SwiftUI\nstruct Model { init(_ value Int) {} }\nstruct ContentView: View { var body: some View { Text(\"Must not run\") } }")
        }
        if scenario.contains("model-malformed-pattern") {
            return ("MalformedPattern.swift", "import SwiftUI\nenum Event { case count(Int) }\nstruct ContentView: View { var body: some View { switch Event.count(1) { case .count(let): Text(\"Must not run\") } } }")
        }
        if scenario.contains("model-bootstrap") {
            return ("ModelBootstrap.swift", "import SwiftUI\nstruct Missing { var value: Int; init() {} }\nstruct ContentView: View { @State var model = Missing(); var body: some View { Text(\"Must not run\") } }")
        }
        if scenario.contains("model-initializers") { return ("Models.swift", modelInitializers) }
        if scenario.contains("model-payloads") { return ("Events.swift", modelPayloads) }
        if scenario.contains("type-features-extension") {
            return ("ProtocolExtension.swift", "import SwiftUI\nprotocol Named { var title: String { get } }\nextension Named { var title: String { \"Hidden default\" } }\nstruct ContentView: View { var body: some View { Text(\"Must not run\") } }")
        }
        if scenario.contains("type-features-malformed") {
            return ("MalformedProtocol.swift", "import SwiftUI\nprotocol Broken { var value: Int { get bogus } }\nstruct ContentView: View { var body: some View { Text(\"Must not run\") } }")
        }
        if scenario.contains("type-features-deep") {
            let signature = String(repeating: "() -> ", count: 600)
            return ("DeepProtocol.swift", "import SwiftUI\nprotocol Deep { func check(value: \(signature)Int) }\nstruct ContentView: View { var body: some View { Text(\"Must not run\") } }")
        }
        if scenario.contains("type-features") { return ("Shapes.swift", typeFeatures) }
        if scenario.contains("timer") { return ("Stopwatch.swift", stopwatch) }
        if scenario.contains("budget") { return ("Budget.swift", budget) }
        if scenario.contains("dictionary") { return ("Dictionary.swift", dictionary) }
        if scenario.contains("optional-chain") { return ("OptionalChain.swift", optionalChain) }
        if scenario.contains("broken") { return ("Broken.swift", broken) }
        if scenario.contains("deep") {
            // Nesting past the parser limit, on line 3.
            let nested = String(repeating: "(", count: 2_000) + "1" + String(repeating: ")", count: 2_000)
            return ("Deep.swift", "import SwiftUI\n\nlet depth = \(nested)\n\nstruct ContentView: View {\n    var body: some View { Text(\"Deep\") }\n}\n")
        }
        if scenario.contains("diagnostic-cap") {
            let declarations = (1...12).map { "class Unsupported\($0) { deinit {} }" }.joined(separator: "\n")
            return ("Capped.swift", "import SwiftUI\n" + declarations + "\nstruct ContentView: View { var body: some View { Text(\"Must not run\") } }")
        }
        if scenario.contains("diagnostic-generic-malformed") {
            return ("MalformedGeneric.swift", "import SwiftUI\nfunc invalid<T U>() { }\nstruct ContentView: View { var body: some View { Text(\"Must not run\") } }\n")
        }
        if scenario.contains("diagnostic-malformed") {
            return ("Malformed.swift", "import SwiftUI\nclass Broken { deinit {\n")
        }
        if scenario.contains("diagnostics") { return ("Diagnostics.swift", diagnostics) }
        if scenario.contains("limits") { return ("Limits.swift", limits) }
        if scenario.contains("truncated") {
            // Past the document sheet's text preview limit, so the preview is truncated.
            let padding = (0..<6_000).map { "// Padding line \($0) keeps this file past the preview limit." }
            return ("Habits.swift", habits + "\n" + padding.joined(separator: "\n"))
        }
        return ("Habits.swift", habits)
    }

    /// #1146: model construction shares action rollback and refuses missing slots.
    static let modelInitializers = #"""
    import SwiftUI
    struct Ticket {
        var title: String
        var count: Int
        init(_ title: String, count: Int = 2) { self.title = title; self.count = count }
    }
    class Ledger {
        var total: Int
        init(start: Int) { total = start }
    }
    struct Missing { var value: Int; init() {} }
    struct Early {
        var value: Int
        init(store: Ledger) { store.total = 99; let callback = self.read; value = 1 }
        func read() -> Int { value }
    }
    struct Returning { var value = 1; init() { return 3 } }
    struct Failing {
        var value: Int
        init(store: Ledger) { store.total = 99; let numbers = [1]; value = numbers[9] }
    }
    struct ContentView: View {
        @State private var ticket = Ticket("First")
        @State private var ledger = Ledger(start: 3)
        var body: some View {
            VStack {
                Text("\(ticket.title)/\(ticket.count)/\(ledger.total)").accessibilityIdentifier("models.state")
                Button("Construct models") { ticket = Ticket("Next", count: 5); ledger = Ledger(start: 4) }
                Button("Reject incomplete initializer") { ticket.count = 99; let missing = Missing() }
                Button("Fail constructor mutation") { ticket.count = 99; let bad = Failing(store: ledger) }
                Button("Reject extra initializer argument") { ticket.count = 99; let bad = Ticket("Bad", bogus: 1) }
                Button("Reject partial self") { ticket.count = 99; let bad = Early(store: ledger) }
                Button("Reject initializer return") { ticket.count = 99; let bad = Returning() }
                Button("Reject unknown stored field") { ticket.count = 99; ledger.unknown = 1 }
            }
        }
    }
    """#

    /// Payloads remain values; switches bind only the selected alternative.
    static let modelPayloads = #"""
    import SwiftUI
    indirect enum Event: Hashable {
        case count(Int)
        case message(text: String)
        case wrapped(Event)
        case batch([Event])
        case empty
        var number: Int {
            switch self {
            case .count(let value): return value
            default: return -1
            }
        }
    }
    enum Other: Hashable { case count(Int) }
    enum FirstKey: Hashable { case same }
    enum SecondKey: Hashable { case same }
    struct ContentView: View {
        @State private var event = Event.count(2)
        @State private var report = "ready"
        var summary: String {
            switch event {
            case let .count(value): return "count \(value)"
            case .wrapped(.message(let text)): return "wrapped \(text)"
            case .message(let text): return text
            case .wrapped(_): return "other wrap"
            case .batch(_): return "batch"
            case .empty: return "empty"
            }
        }
        var body: some View {
            VStack {
                Text("\(summary)/\(event.number)").accessibilityIdentifier("events.state")
                Text(report).accessibilityIdentifier("events.report")
                Button("Construct stored case") { let make = Event.count; event = make(3) }
                Button("Wrap payload") { event = Event.wrapped(Event.message(text: "hello")) }
                Button("Compare payloads") {
                    let first: AnyHashable = Event.count(2)
                    let same: AnyHashable = Event.count(2)
                    let other: AnyHashable = Other.count(2)
                    let keys: [AnyHashable: Int] = [FirstKey.same: 1, SecondKey.same: 2]
                    report = "\(first == same)/\(first == other)/\(Event.message(text: "ok"))/\(keys.count)/\(keys[FirstKey.same] ?? -1)/\(keys[SecondKey.same] ?? -1)"
                }
                Button("Exhaust payload nesting") {
                    report = "must roll back"
                    for _ in 0..<200 { event = Event.wrapped(event) }
                }
                Button("Exhaust payload containers") {
                    report = "must roll back"
                    for _ in 0..<200 { event = Event.batch([event]) }
                }
                Button("Reject payload arity") { report = "must roll back"; event = Event.count(1, 2) }
                Button("Reject payload label") { report = "must roll back"; event = Event.message(wrong: "bad") }
                Button("Reject payload pattern") {
                    report = "must roll back"
                    switch event { case .count(let first, let second): report = "wrong"; default: report = "wrong" }
                }
            }
        }
    }
    """#

    static let typeFeatures = #"""
    import SwiftUI

    protocol Shape {
        associatedtype Unit = Int
        var title: String { get }
        func area(_ scale: Int) -> Int
    }
    struct Square: Shape {
        let title: String
        let side: Int
        func area(_ scale: Int) -> Int { side * side * scale }
    }
    class ModelObject { var value = 1 }
    struct RectangleModel: Shape {
        let title: String
        let width: Int
        let height: Int
        func area(_ scale: Int) -> Int { width * height * scale }
    }
    struct ContentView: View {
        @State private var width = 120
        @State private var commits = 0
        @State private var observations = 0
        @State private var repaints = 0
        @State private var bound = Square(title: "Bound", side: 3)
        @State private var boundObject = ModelObject()
        var body: some View {
            let shapes: [any Shape] = [Square(title: "Square", side: 3), RectangleModel(title: "Rectangle", width: 2, height: 4)]
            let titles = shapes.map { $0.title }.joined(separator: ", ")
            let area = shapes.map { $0.area(2) }.reduce(0, +)
            let object = ModelObject()
            let optional: Square? = Square(title: "Optional", side: 3)
            let mapped = optional.map { $0.area(1) } ?? 0
            VStack {
                Text("\(titles): \(area); optional \(mapped)").accessibilityIdentifier("types.dispatch")
                GeometryReader { proxy in
                    VStack {
                        Text("\(Int(proxy.size.width)) x \(Int(proxy.size.height)); local \(Int(proxy.frame(in: .local).origin.x))/\(Int(proxy.frame(in: .local).maxX)); equal \(proxy.size == proxy.frame(in: .local).size)")
                            .accessibilityIdentifier("types.geometry")
                        Text("Repaints: \(repaints)").accessibilityIdentifier("types.repaints")
                        Button("Reject geometry write") { commits += 1; proxy.size.width = 999 }
                        Button("Reject global frame") { commits += 1; let frame = proxy.frame(in: .global) }
                    }
                    .onChange(of: proxy.size) { observations += 1 }
                }
                .frame(width: width, height: 180)
                Button("Resize geometry") { width = 240 }
                Button("Repaint geometry") { repaints += 1 }
                Button("Reject missing record member") { commits += 1; let value = shapes[0].missing }
                Button("Reject missing object member") { commits += 1; let value = object.missing }
                Button("Reject missing record binding") { commits += 1; let value = $bound.missing }
                Button("Reject missing object binding") { commits += 1; let value = $boundObject.missing }
                Text("Commits: \(commits)").accessibilityIdentifier("types.commits")
                Text("Observations: \(observations)").accessibilityIdentifier("types.observations")
            }
        }
    }
    """#

    static let dictionary = #"""
    import SwiftUI

    @main
    struct DictionaryApp: App {
        var body: some Scene { WindowGroup { DictionaryView() } }
    }

    enum Kind: String, CaseIterable { case fruit, drink }
    struct Item: Identifiable {
        let id: Int
        let name: String
        let kind: Kind
    }

    struct Note { var text: String? }

    struct DictionaryView: View {
        @State private var numbers: [Int: Int] = [1: 10]
        @State private var flags: [Bool: String] = [true: "yes", false: "no"]
        @State private var notes: [String: Note] = ["one": Note(text: "start")]
        @State private var buckets: [String: [Int]] = [:]
        @State private var defaultCalls = 0
        @State private var keyCalls = 0
        @State private var report = "ready"
        @State private var items: [Item] = [
            Item(id: 1, name: "Apple", kind: .fruit),
            Item(id: 2, name: "Pear", kind: .fruit),
            Item(id: 3, name: "Tea", kind: .drink)
        ]

        var body: some View {
            let grouped = Dictionary(grouping: items, by: { $0.kind })
            let tally = grouped.mapValues { $0.count }
            let example = ["a": 1]
            let empty = Dictionary<String, Int>()
            NavigationStack {
                List {
                    Text("\(tally[.fruit, default: 0]) fruit / \(tally[.drink, default: 0]) drinks")
                        .accessibilityIdentifier("dictionary.tally")
                    ForEach(grouped.keys.sorted { $0.rawValue < $1.rawValue }, id: \.self) { kind in
                        Section(kind.rawValue) {
                            ForEach(grouped[kind] ?? [], id: \.id) { item in Text(item.name) }
                        }
                    }
                    Text("\(grouped.count) categories / \(grouped.values.map { $0.count }.reduce(0, +)) items")
                        .accessibilityIdentifier("dictionary.count")
                    NavigationLink("Dictionary checks") {
                        VStack(spacing: 8) {
                            Text(stateSummary).accessibilityIdentifier("dictionary.state")
                            Text(report).accessibilityIdentifier("dictionary.report")
                            Text("\(example.description) / \(empty)").accessibilityIdentifier("dictionary.description")
                            Button("Exercise dictionaries") { exercise() }
                            Button("Fail dictionary write") {
                                damage()
                                let values = [1]
                                let invalid = values[9]
                            }
                            Button("Reject mutable key") { damage(); numbers[[1, 2]] = 3 }
                            Button("Skip missing chained write") { notes["ghost"]?.text = "bad" }
                            Button("Exhaust dictionary copies") {
                                damage()
                                var growing = [:]
                                for index in 0..<100000 { growing[index] = index }
                            }
                            Button("Exceed dictionary limit") {
                                damage()
                                var large = Dictionary(grouping: 0..<100000, by: { $0 })
                                large[100000] = []
                            }
                        }
                    }
                }
                .navigationTitle("Dictionary")
            }
        }

        var stateSummary: String {
            let count = buckets["new", default: []].count
            let note = notes["one"].text ?? "nil"
            return "\(numbers[2] ?? 0)/\(numbers[3] ?? 0)/\(numbers[7] ?? 0); buckets \(count); notes \(notes.count)/\(note); flags \(flags.count); calls \(defaultCalls)/\(keyCalls)"
        }
        func defaultAmount() -> Int { defaultCalls += 1; return 4 }
        func nextKey() -> Int { keyCalls += 1; return 7 }
        func damage() {
            numbers[2] = 99
            notes["one"].text = "bad"
            buckets["new", default: []].append(5)
            report = "bad"
        }
        func exercise() {
            var copy = numbers
            numbers[2, default: 0] += 3
            numbers[1] = nil
            copy[2] = 9
            numbers[3, default: defaultAmount()] += 1
            numbers[nextKey(), default: 0] += 2
            numbers[nextKey(), default: 0] += 2
            buckets["new", default: []].append(9)
            notes["one"].text = nil
            flags[false] = nil
            var probe = [1: 5]
            let missing = probe[99, default: 7]
            let existing = probe[1, default: 1 / 0]
            var total = 0
            for (key, value) in numbers { total += key + value }
            let mapped = numbers.map { key, value in key + value }.reduce(0, +)
            let filtered = numbers.filter { $0.key != 7 }.mapValues { $0 + 1 }.values.reduce(0, +)
            let ordered = numbers.sorted { $0.key < $1.key }.map { $0.value }.reduce(0, +)
            let found = numbers.contains { key, value in key == 3 && value == 5 }
            let empty = Dictionary<Int, Int>().isEmpty
            let tagged = [1: "int", true: "bool", "1": "string", .fruit: "enum", "fruit": "text"]
            var nullable: [Int: Int?] = [:]
            nullable[1, default: nil] = nil
            let same = [true: 1, false: 2] == [false: 2, true: 1]
            report = "read \(missing)/\(existing)/\(probe.count); copy \(copy[1] ?? 0)/\(copy[2] ?? 0); loops \(total)/\(mapped); mapped \(filtered)/\(ordered)/\(found)/\(empty); keys \(tagged.count)/\(nullable.count)/\(same)"
        }
    }
    """#

    /// #1142: a nil optional-chain receiver skips the rest of its postfix chain
    /// (arguments, later indexes, lazy defaults and assignment right-hand sides);
    /// a present receiver runs normally, and `??` and parentheses end the chain.
    static let optionalChain = #"""
    import SwiftUI

    @main
    struct OptionalChainApp: App {
        var body: some Scene { WindowGroup { OptionalChainView() } }
    }

    struct Note {
        var text: String?
        var score: Int
        var tags: [String]

        func scaled(_ extra: Int) -> Int { score + extra }
    }

    struct Holder { var note: Note? }
    class ChainBox {
        var value = 0
        func add(_ amount: Int) -> Int { value += amount; return value }
    }

    struct OptionalChainView: View {
        @State private var notes: [String: Note] = ["one": Note(text: "start", score: 1, tags: ["a"])]
        @State private var parent: Note? = Note(text: "child", score: 0, tags: [])
        @State private var missing: Note? = nil
        @State private var holder: Holder? = Holder(note: nil)
        @State private var counts: [String: Int]? = nil
        @State private var box = ChainBox()
        @State private var order = ""
        @State private var calls = 0
        @State private var keyCalls = 0
        @State private var report = "ready"

        var body: some View {
            VStack(spacing: 8) {
                Text(stateSummary).accessibilityIdentifier("optionalChain.state")
                Text(report).accessibilityIdentifier("optionalChain.report")
                Button("Exercise optional chains") { runChains() }
                Button("Fail after optional write") { failAfterWrite() }
                Button("Fail grouped optional chain") { failGroupedChain() }
                Button("Fail forced nil") { parent?.score = 99; let value = (missing?.score)! }
                Button("Fail forced nil field") { parent?.score = 99; let value = parent?.text!.count }
                Text("\(order)/\(box.value)").accessibilityIdentifier("optionalChain.order")
                Button("Exercise receiver order") { exerciseOrder() }
            }
        }

        var stateSummary: String {
            let one = notes["one"]
            let parentText = parent?.text ?? "nil"
            let ghost = notes["ghost"]?.score ?? -9
            return "one \(one?.score ?? 0)/\(one?.tags.count ?? 0); parent \(parent?.score ?? 0)/\(parentText); missing \(missing?.score ?? -9); ghost \(ghost); notes \(notes.count); calls \(calls)/\(keyCalls)"
        }

        func bump() -> Int { calls += 1; return 1 }
        func nextKey() -> String { keyCalls += 1; return "one" }
        func textTransform() -> (String) -> Int { calls += 1; return { $0.count } }
        func makeBox() -> ChainBox? { order += "R"; return box }
        func nilBox() -> ChainBox? { order += "N"; return nil }
        func argument() -> Int { order += "A"; return 2 }
        func exerciseOrder() {
            let first = makeBox()?.add(argument())
            makeBox()?.value += argument()
            nilBox()?.value = argument()
            let last = nilBox()?.add(argument())
        }

        func runChains() {
            let skippedArgument = missing?.scaled(bump()) ?? -1
            let skippedIndex = notes["none"]?.tags[bump()] ?? "no tag"
            let skippedDefault = counts?[nextKey(), default: bump()] ?? -2
            counts?[nextKey(), default: bump()] += bump()
            missing?.score = bump()
            missing?.tags.append("x")
            notes["ghost"]?.text = "bad"
            let absent: ((Int) -> Int)? = nil
            let present: ((Int) -> Int)? = { $0 + 10 }
            let skippedCall = absent?(bump()) ?? -4
            let presentCall = present?(bump()) ?? -5
            let direct = parent?.scaled(bump()) ?? -3
            parent?.score += bump()
            parent?.text = nil
            holder?.note?.score = bump()
            notes[nextKey()]?.score += bump()
            notes["one"]?.tags.append("b")
            let deep = holder?.note?.text ?? "no deep"
            let grouped = (missing?.score ?? 0) + bump()
            let coalesced = missing?.score ?? bump()
            let kept = parent?.score ?? bump()
            let blank = parent?.text ?? "blank"
            let skippedFactory = missing?.text.map(textTransform())
            let groupedFactory = (missing?.text).map(textTransform())
            var amounts: [String: Int]? = [:]
            amounts?[nextKey(), default: bump()] += bump()
            let amount = amounts?["one"] ?? -99
            amounts?[nextKey(), default: bump()] = 10
            let replaced = amounts?["one"] ?? -99
            notes["one"]!.score += 1
            let skippedForce = missing?.text!.count ?? -10
            report = "\(skippedArgument)/\(skippedIndex)/\(skippedDefault)/\(skippedCall)/\(presentCall)/\(direct)/\(grouped)/\(coalesced)/\(kept)/\(deep)/\(blank)/\(amount)/\(replaced)/\(skippedForce)"
        }

        func failAfterWrite() {
            makeBox()?.value = 99
            parent?.text = "bad"
            parent?.score = 99
            let values = [1]
            let invalid = values[9]
        }

        func failGroupedChain() {
            parent?.text = "bad"
            let grouped = (missing?.scaled(bump())) + 1
        }
    }
    """#

    static let stopwatch = #"""
    import SwiftUI

    @main
    struct StopwatchApp: App {
        var body: some Scene { WindowGroup { ContentView() } }
    }

    struct ContentView: View {
        @State private var ticks = 0
        @State private var fail = false
        @State private var extra = false
        let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

        var body: some View {
            VStack {
                Text("Ticks: \(ticks)")
                    .accessibilityIdentifier("stopwatch.ticks")
                Button("Fail one subscriber") { fail = true }
                Button("Add ninth subscriber") { extra = true }
                ForEach(0..<8, id: \.self) { index in
                    Text("Subscriber \(index)")
                        .onReceive(timer) { _ in
                            if index == 0 && fail { missingFunction() }
                            ticks += 1
                        }
                }
                if extra {
                    Text("Ninth subscriber")
                        .onReceive(timer) { _ in ticks += 1 }
                }
            }
        }
    }
    """#

    static let habits = #"""
    import SwiftUI

    let explicitGenericArray: [Int] = Array<Int>()

    @main
    struct HabitsApp: App {
        var body: some Scene {
            WindowGroup {
                ContentView()
            }
        }
    }

    struct Habit: Identifiable {
        let id = UUID()
        var name: String
        var icon: String
        var streak: Int = 0
        var doneToday: Bool = false
    }

    enum Filter: String, CaseIterable {
        case all, open, done
    }

    struct CompletionBadge<Value>: View where Value == Int {
        let value: Value

        var body: some View {
            Text("Generic count: \(value); array: \(explicitGenericArray.count)")
                .accessibilityIdentifier("habits.generic-count")
        }
    }

    struct ContentView: View {
        @State private var habits: [Habit] = [
            Habit(name: "Drink water", icon: "drop.fill", streak: 4),
            Habit(name: "Read 20 pages", icon: "book.fill", streak: 11),
            Habit(name: "Stretch", icon: "figure.cooldown", streak: 2)
        ]
        @State private var newHabit = ""
        @State private var filter: Filter = .all

        private var completed: Int {
            habits.filter { $0.doneToday }.count
        }

        var body: some View {
            NavigationStack {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            CompletionBadge(value: identity<Int>(completed))
                            Text("Less than one: \(completed < 1)")
                                .accessibilityIdentifier("habits.generic-comparison")
                            Text("\(completed) of \(habits.count) done today")
                                .font(.headline)
                                .accessibilityIdentifier("habits.summary")
                            ProgressView(value: Double(completed), total: Double(max(habits.count, 1)))
                                .tint(.green)
                        }
                        .padding(.vertical, 4)
                        Picker("Show", selection: $filter) {
                            ForEach(Filter.allCases, id: \.self) { option in
                                Text(option.rawValue.capitalized)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    Section("Today") {
                        ForEach($habits) { $habit in
                            if filter == .all || (filter == .done) == habit.doneToday {
                                HabitRow(habit: $habit)
                            }
                        }
                        .onDelete { offsets in
                            habits.remove(atOffsets: offsets)
                        }
                    }
                    Section("New habit") {
                        HStack {
                            TextField("Habit name", text: $newHabit)
                            Button("Add") {
                                withAnimation {
                                    habits.append(Habit(name: newHabit, icon: "star.fill"))
                                }
                                newHabit = ""
                            }
                            .disabled(newHabit.isEmpty)
                        }
                    }
                }
                .navigationTitle("Habits")
            }
        }
    }

    struct HabitRow: View {
        @Binding var habit: Habit

        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: habit.icon)
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(habit.doneToday ? Color.green : Color.blue, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(habit.name)
                    Text("\(habit.streak) day streak")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    habit.doneToday.toggle()
                    habit.streak += habit.doneToday ? 1 : -1
                } label: {
                    Image(systemName: habit.doneToday ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(habit.doneToday ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Complete \(habit.name)")
            }
        }
    }

    func identity<T>(_ value: T) -> T where T: Equatable {
        value
    }
    """#

    /// A second app style: a shared `ObservableObject` store passed through
    /// `environmentObject`, a `TabView`, `List`s, an enum `switch` and
    /// `String(format:)`.
    static let budget = #"""
    import SwiftUI

    @main
    struct BudgetApp: App {
        @StateObject private var store = BudgetStore()

        var body: some Scene {
            WindowGroup {
                RootView()
                    .environmentObject(store)
            }
        }
    }

    enum Category: String, CaseIterable {
        case food, travel, fun

        var icon: String {
            switch self {
            case .food: return "fork.knife"
            case .travel: return "airplane"
            case .fun: return "gamecontroller.fill"
            }
        }
    }

    struct Expense: Identifiable {
        let id = UUID()
        var title: String
        var amount: Double
        var category: Category
    }

    class BudgetStore: ObservableObject {
        @Published var expenses: [Expense] = [
            Expense(title: "Groceries", amount: 42.5, category: .food),
            Expense(title: "Train ticket", amount: 18, category: .travel)
        ]

        var total: Double {
            expenses.reduce(0) { $0 + $1.amount }
        }

        func spent(on category: Category) -> Double {
            expenses.filter { $0.category == category }.map { $0.amount }.reduce(0, +)
        }

        func add(_ category: Category) {
            expenses.append(Expense(title: "New \(category.rawValue)", amount: 12.25, category: category))
        }
    }

    struct RootView: View {
        var body: some View {
            TabView {
                ExpensesView()
                    .tabItem { Label("Expenses", systemImage: "list.bullet") }
                SummaryView()
                    .tabItem { Label("Summary", systemImage: "chart.pie") }
            }
        }
    }

    struct ExpensesView: View {
        @EnvironmentObject var store: BudgetStore
        @Environment(\.dismiss) private var dismiss
        @State private var planningTrip = false

        var body: some View {
            NavigationStack {
                List {
                    ForEach(store.expenses) { expense in
                        HStack {
                            Image(systemName: expense.category.icon)
                            Text(expense.title)
                            Spacer()
                            Text(String(format: "$%.2f", expense.amount))
                        }
                    }
                    Section("Add") {
                        ForEach(Category.allCases, id: \.self) { category in
                            Button("Add \(category.rawValue)") {
                                store.add(category)
                            }
                        }
                    }
                }
                .navigationTitle("Expenses")
                .toolbar {
                    Button("Plan trip") { planningTrip = true }
                    Button("Leave app") { dismiss() }
                }
                .sheet(isPresented: $planningTrip) {
                    TripSheet()
                }
            }
        }
    }

    struct TripSheet: View {
        @EnvironmentObject var store: BudgetStore
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            NavigationStack {
                Text("A train ticket for 12.25")
                    .navigationTitle("New trip")
                    .toolbar {
                        Button("Save trip") {
                            store.add(.travel)
                            dismiss()
                        }
                    }
            }
        }
    }

    struct SummaryView: View {
        @EnvironmentObject var store: BudgetStore

        var body: some View {
            NavigationStack {
                List {
                    ForEach(Category.allCases, id: \.self) { category in
                        HStack {
                            Text(category.rawValue.capitalized)
                            Spacer()
                            Text(String(format: "%.2f", store.spent(on: category)))
                                .accessibilityIdentifier("budget.\(category.rawValue)")
                        }
                    }
                    Text(String(format: "Total $%.2f across %d expenses", store.total, store.expenses.count))
                        .accessibilityIdentifier("budget.total")
                    Text(store.expenses.last.map { "Latest: \($0.title)" } ?? "No expenses")
                    Text(store.expenses.first { $0.amount > 1000 }.map { "Big: \($0.title)" } ?? "No big expense")
                    NavigationLink("Biggest expense") {
                        BiggestView()
                    }
                }
                .navigationTitle("Summary")
            }
        }
    }

    struct BiggestView: View {
        @EnvironmentObject var store: BudgetStore
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            VStack {
                Text(store.expenses.sorted { $0.amount > $1.amount }[0].title)
                Button("Back to summary") { dismiss() }
            }
            .navigationTitle("Biggest")
        }
    }
    """#

    /// Supported dictionaries, protocol requirements and enum payloads beside
    /// an unsupported custom View initializer; only the latter diagnoses.
    static let broken = #"""
    import SwiftUI

    struct ContentView: View {
        @State private var scores: [String: Int] = ["Ada": 3]
        init() { }

        var body: some View {
            let other = ["Bob": 4]
            Text("Scores")
        }
    }

    enum Result {
        case value(Int)
    }

    protocol HasValue { var value: Int { get } }
    """#

    /// One invalid child must not erase earlier/later siblings or swallow an
    /// error in a value helper called by an action.
    static let diagnostics = #"""
    import SwiftUI
    struct ContentView: View {
        @State private var taps = 0
        var body: some View {
            VStack {
                Text("Taps: \(taps)").accessibilityIdentifier("diagnostics.taps")
                Text([1].count())
                HStack {
                    Text("Nested sibling")
                    Text(badValue())
                    Text("After nested failure")
                }
                Text("Last sibling")
                ForEach(0..<3, id: \.self) { index in
                    Text("Row \(10 / (index - 1))")
                }
                Button("Count") { taps += 1 }
                Button("Fail action") {
                    taps += 10
                    taps = badValue()
                }
            }
        }
        func badValue() -> Int {
            let values = [1]
            return values[4]
        }
    }
    protocol Marker {}
    """#

    /// Runaway and hostile programs and an unsupported view. Each must end
    /// in a diagnostic or a safe value while the rest of the app keeps working.
    static let limits = #"""
    import SwiftUI

    struct ContentView: View {
        @State private var taps = 0
        @State private var note = ""
        @State private var nested = false
        @State private var ledger = Ledger(rows: [Entry(amount: 1)])
        @StateObject private var store = Store()

        var body: some View {
            VStack(spacing: 12) {
                Text("Taps: \(taps)")
                    .accessibilityIdentifier("limits.taps")
                Text(note)
                    .accessibilityIdentifier("limits.note")
                Button("Count") { taps += 1 }
                Text("State: \(ledger.rows.count)/\(ledger.total)/\(store.items.count)/\(store.child.number)")
                    .accessibilityIdentifier("limits.state")
                TransactionButtons(ledger: $ledger, store: store)
                Button("Recurse forever") { taps = deeper(taps) }
                Button("Grow forever") {
                    var text = "ab"
                    while true { text = text + text }
                }
                Button("Read itself") { taps = forever }
                Button("Overflow") {
                    taps += 10
                    note = "must roll back"
                    store.child.number = 99
                    let lowest = -9223372036854775807 - 1
                    taps = lowest / -1
                }
                Button("Hostile format") {
                    note = String(format: "%s|%@|%5.1f", taps, 2.5, 3)
                }
                Button("Compare shared") {
                    var shared = [1]
                    for _ in 0..<40 { shared = [shared, shared] }
                    note = shared == shared ? "same" : "different"
                }
                Button("Describe shared") {
                    var shared = [1]
                    for _ in 0..<40 { shared = [shared, shared] }
                    note = "\(shared)"
                }
                Button("Nest views") { nested = true }
                MapCard()
                if nested {
                    Nest()
                }
            }
            .padding()
        }

        var forever: Int {
            forever
        }

        func deeper(_ n: Int) -> Int {
            deeper(n + 1)
        }
    }

    struct Entry {
        var amount: Int
    }

    struct Ledger {
        var rows: [Entry]
        var total: Int { rows.reduce(0) { $0 + $1.amount } }
    }

    class Counter {
        var number = 0
    }

    class Store: ObservableObject {
        @Published var items = [1]
        var child = Counter()
    }

    struct TransactionButtons: View {
        @Binding var ledger: Ledger
        @ObservedObject var store: Store

        var body: some View {
            HStack {
                Button("Loop forever") {
                    change()
                    while true { store.child.number += 1 }
                }
                Button("Commit changes") { change() }
            }
        }

        func change() {
            ledger.rows[0].amount += 1
            ledger.rows[0].amount += 1
            ledger.rows.append(Entry(amount: 2))
            store.items.append(2)
            let alias = store.child
            alias.number += 1
        }
    }

    struct MapCard: View {
        var body: some View {
            Map()
        }
    }

    struct Nest: View {
        var body: some View {
            VStack {
                Nest()
            }
        }
    }
    """#
}
#endif
