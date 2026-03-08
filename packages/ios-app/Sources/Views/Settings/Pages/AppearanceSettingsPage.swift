import SwiftUI

@available(iOS 26.0, *)
struct AppearanceSettingsPage: View {
    var body: some View {
        NavigationStack {
            List {
                AppearanceSection()
            }
            .listStyle(.insetGrouped)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Appearance")
                        .font(TronTypography.button)
                        .foregroundStyle(.tronEmerald)
                }
            }
        }
    }
}
