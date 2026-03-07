import SwiftUI

@available(iOS 26.0, *)
struct AppearanceSettingsPage: View {
    var body: some View {
        List {
            AppearanceSection()
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}
