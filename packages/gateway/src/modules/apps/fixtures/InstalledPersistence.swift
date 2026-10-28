import SwiftUI

struct SavedEntry { var id: Int; var title: String }
struct ContentView: View {
    @AppStorage("count") var count = 0
    @Persisted var entries: [SavedEntry] = []
    @State var transient = 0
    var body: some View {
        VStack {
            Text("Count \(count)").accessibilityIdentifier("installed.count")
            Text("Saved \(entries.count)").accessibilityIdentifier("installed.entries")
            Text("Transient \(transient)").accessibilityIdentifier("installed.transient")
            Button("Add entry") {
                count += 1
                entries.append(SavedEntry(id: count, title: "Entry \(count)"))
                transient += 1
            }
            Button("Reject action") {
                count = 999
                entries = []
                transient = 999
                let values = [1]
                let invalid = values[9]
            }
        }
    }
}
