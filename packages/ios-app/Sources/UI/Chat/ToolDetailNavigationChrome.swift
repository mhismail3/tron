import SwiftUI

extension View {
    /// Tool-owned sheets use principal toolbar titles. Explicit inline mode
    /// prevents NavigationStack from reserving an empty large-title region
    /// above the first scroll row on physical devices.
    func tronToolDetailNavigationChrome() -> some View {
        navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
    }
}
