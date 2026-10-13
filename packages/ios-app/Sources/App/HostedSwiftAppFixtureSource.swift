#if HOSTED_TEST
/// The single-file SwiftUI app the #889 run journey displays and runs. It is
/// ordinary SwiftUI source, the kind an agent writes and presents with
/// `display`; docs/swift-apps.md describes the supported subset.
enum HostedSwiftAppFixtureSource {
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
}
#endif
