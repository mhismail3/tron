import SwiftUI

@available(iOS 26.0, *)
struct AppearanceSettingsPage: View {
    var body: some View {
        NavigationStack {
            List {
                AppearanceSection()
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Appearance")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
