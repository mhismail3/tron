import SwiftUI

@available(iOS 26.0, *)
struct AppearanceSection: View {
    @State private var appearanceSettings = AppearanceSettings.shared
    @State private var fontSettings = FontSettings.shared

    var body: some View {
        Section {
            Picker("Mode", selection: Binding(
                get: { appearanceSettings.mode },
                set: { appearanceSettings.mode = $0 }
            )) {
                ForEach(AppearanceMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Text("Aa")
                        .font(TronTypography.mono(size: 28, weight: .medium))
                        .foregroundStyle(.tronEmerald)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Recursive")
                            .font(TronTypography.headline)
                            .foregroundStyle(.tronTextPrimary)
                        Text(casualLabel)
                            .font(TronTypography.caption)
                            .foregroundStyle(.tronTextSecondary)
                            .contentTransition(.numericText())
                    }

                    Spacer()

                    Text(String(format: "%.2f", fontSettings.casualAxis))
                        .font(TronTypography.subheadline)
                        .foregroundStyle(.tronEmerald)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }

                Spacer()
                    .frame(height: 2)
                Slider(
                    value: Binding(
                        get: { fontSettings.casualAxis },
                        set: { fontSettings.casualAxis = $0 }
                    ),
                    in: 0...1
                ) {
                    Text("Font Style")
                } minimumValueLabel: {
                    Text("Linear")
                        .font(TronTypography.caption2)
                        .foregroundStyle(.tronTextMuted)
                } maximumValueLabel: {
                    Text("Casual")
                        .font(TronTypography.caption2)
                        .foregroundStyle(.tronTextMuted)
                }
                .tint(.tronEmerald)
            }
            .padding(.vertical, 4)
        } header: {
            Text("Appearance")
                .font(TronTypography.caption)
        } footer: {
            Text("Auto follows your system appearance setting. Font style adjusts the casual axis — Linear is precise, Casual is playful.")
                .font(TronTypography.caption2)
        }
        .listSectionSpacing(16)
    }

    private var casualLabel: String {
        let value = fontSettings.casualAxis
        if value < 0.2 { return "Linear" }
        if value < 0.4 { return "Semi-Linear" }
        if value < 0.6 { return "Balanced" }
        if value < 0.8 { return "Semi-Casual" }
        return "Casual"
    }
}
