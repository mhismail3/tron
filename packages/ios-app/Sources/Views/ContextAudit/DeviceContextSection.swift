import SwiftUI

// MARK: - Device Context Section (shows injected device signals for transparency)

@available(iOS 26.0, *)
struct DeviceContextSection: View {
    let deviceContext: ServerSettings.IntegrationSettings.DeviceContextSettings
    let location: ServerSettings.IntegrationSettings.LocationSettings
    @State private var isExpanded = false

    private let accentColor: Color = .tronEmerald

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "iphone")
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(accentColor)
                    .frame(width: 18)
                Text("Device Context")
                    .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(accentColor)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                    .foregroundStyle(.tronTextMuted)
                    .rotationEffect(.degrees(isExpanded ? -180 : 0))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isExpanded)
            }
            .padding(12)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }

            // Content
            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    signalRows
                    contextLinePreview
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .sectionFill(accentColor)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Signal Rows

    @ViewBuilder
    private var signalRows: some View {
        let ctx = DeviceContextService.shared.collectContext(settings: deviceContext)

        if let level = ctx["batteryLevel"] as? Int, let state = ctx["batteryState"] as? String {
            EnvironmentItemRow(icon: "battery.100", label: "Battery", value: "\(level)% \(state)", accent: accentColor)
        }
        if let network = ctx["networkType"] as? String {
            let expensive = (ctx["isExpensiveNetwork"] as? Bool) == true
            EnvironmentItemRow(
                icon: network == "wifi" ? "wifi" : "antenna.radiowaves.left.and.right",
                label: "Network",
                value: expensive ? "\(network.capitalized) (expensive)" : network.capitalized,
                accent: accentColor
            )
        }
        if let darkMode = ctx["darkMode"] as? Bool {
            EnvironmentItemRow(
                icon: darkMode ? "moon.fill" : "sun.max.fill",
                label: "Display",
                value: darkMode ? "Dark mode" : "Light mode",
                accent: accentColor
            )
        }
        if let audioRoute = ctx["audioRoute"] as? String {
            EnvironmentItemRow(icon: "headphones", label: "Audio", value: audioRoute, accent: accentColor)
        }
        if let tz = ctx["timezone"] as? String {
            EnvironmentItemRow(icon: "clock", label: "Timezone", value: tz, accent: accentColor)
        }
        if location.enabled,
           let locPart = LocationService.shared.formatContextPart(precision: location.precision) {
            EnvironmentItemRow(icon: "location", label: "Location", value: locPart, accent: accentColor)
        }
    }

    // MARK: - Full Context Line Preview

    @ViewBuilder
    private var contextLinePreview: some View {
        if let line = DeviceContextService.shared.formatContextLine(
            settings: deviceContext,
            locationSettings: location
        ) {
            ScrollView {
                Text(line)
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(.tronTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 80)
            .sectionFill(accentColor, cornerRadius: 6, subtle: true)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}
