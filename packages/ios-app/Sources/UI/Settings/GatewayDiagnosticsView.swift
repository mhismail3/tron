import SwiftUI

/// Compatibility destination retained for older deep links. Diagnostics now
/// lives in the combined Connections settings surface.
struct GatewayDiagnosticsView: View {
    var body: some View { ConnectionsSettingsView() }
}
