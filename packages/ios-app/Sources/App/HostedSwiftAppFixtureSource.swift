#if HOSTED_TEST
/// The single-file SwiftUI apps the #889 run journeys display and run. They
/// are ordinary SwiftUI source, the kind an agent writes and presents with
/// `display`; docs/swift-apps.md describes the supported subset.
enum HostedSwiftAppFixtureSource {
    /// The file a `display-swift…` scenario displays: its name and source.
    static func file(for scenario: String) -> (name: String, source: String)? {
        guard scenario.contains("display-swift") else { return nil }
        if scenario.contains("budget") { return ("Budget.swift", budget) }
        if scenario.contains("broken") { return ("Broken.swift", broken) }
        if scenario.contains("deep") {
            // Nesting past the parser limit, on line 3.
            let nested = String(repeating: "(", count: 2_000) + "1" + String(repeating: ")", count: 2_000)
            return ("Deep.swift", "import SwiftUI\n\nlet depth = \(nested)\n\nstruct ContentView: View {\n    var body: some View { Text(\"Deep\") }\n}\n")
        }
        if scenario.contains("limits") { return ("Limits.swift", limits) }
        if scenario.contains("truncated") {
            // Past the document sheet's text preview limit, so the preview is truncated.
            let padding = (0..<6_000).map { "// Padding line \($0) keeps this file past the preview limit." }
            return ("Habits.swift", habits + "\n" + padding.joined(separator: "\n"))
        }
        return ("Habits.swift", habits)
    }

    static let habits = #"""
    import SwiftUI

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

    /// Swift outside the subset: a dictionary literal on line 4.
    static let broken = #"""
    import SwiftUI

    struct ContentView: View {
        @State private var scores: [String: Int] = ["Ada": 3]

        var body: some View {
            Text("Scores")
        }
    }
    """#

    /// Runaway and hostile programs and an unsupported view. Each must end
    /// in a diagnostic or a safe value while the rest of the app keeps working.
    static let limits = #"""
    import SwiftUI

    struct ContentView: View {
        @State private var taps = 0
        @State private var note = ""
        @State private var nested = false

        var body: some View {
            VStack(spacing: 12) {
                Text("Taps: \(taps)")
                    .accessibilityIdentifier("limits.taps")
                Text(note)
                    .accessibilityIdentifier("limits.note")
                Button("Count") { taps += 1 }
                Button("Loop forever") {
                    var n = 0
                    while true { n += 1 }
                }
                Button("Recurse forever") { taps = deeper(taps) }
                Button("Grow forever") {
                    var text = "ab"
                    while true { text = text + text }
                }
                Button("Read itself") { taps = forever }
                Button("Overflow") {
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
