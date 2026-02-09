import SwiftUI

struct CompactionSection: View {
    @Binding var triggerTokenThreshold: Double
    @Binding var defaultTurnFallback: Int
    @Binding var preserveRecentTurns: Int
    @Binding var forceAlwaysCompact: Bool
    let updateServerSetting: (() -> ServerSettingsUpdate) -> Void

    var body: some View {
        // Compaction Threshold slider (50%–95%, step 5%)
        Section {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Compaction Threshold", systemImage: "gauge.with.dots.needle.67percent")
                        .font(TronTypography.subheadline)
                    Spacer()
                    Text("\(Int(triggerTokenThreshold * 100))%")
                        .font(TronTypography.subheadline)
                        .foregroundStyle(.tronEmerald)
                        .monospacedDigit()
                }
                Slider(
                    value: $triggerTokenThreshold,
                    in: 0.50...0.95,
                    step: 0.05
                )
                .tint(.tronEmerald)
            }
            .onChange(of: triggerTokenThreshold) { _, newValue in
                updateServerSetting {
                    ServerSettingsUpdate(context: .init(compactor: .init(
                        triggerTokenThreshold: newValue
                    )))
                }
            }
        } header: {
            Text("Compaction")
                .font(TronTypography.caption)
        } footer: {
            Text("Context usage % that triggers compaction. Lower values compact sooner, preserving more headroom.")
                .font(TronTypography.caption2)
        }

        // Max Turns stepper (3–20)
        Section {
            HStack {
                Label("Max Turns", systemImage: "repeat")
                    .font(TronTypography.subheadline)
                Spacer()
                Text("\(defaultTurnFallback)")
                    .font(TronTypography.subheadline)
                    .foregroundStyle(.tronEmerald)
                    .monospacedDigit()
                    .frame(minWidth: 20)
                Stepper("", value: $defaultTurnFallback, in: 3...20)
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
            }
            .onChange(of: defaultTurnFallback) { _, newValue in
                updateServerSetting {
                    ServerSettingsUpdate(context: .init(compactor: .init(
                        defaultTurnFallback: newValue
                    )))
                }
            }
        } footer: {
            Text("Maximum turns between compactions, even if the threshold hasn't been reached.")
                .font(TronTypography.caption2)
        }

        // Keep Recent Turns stepper (0–10)
        Section {
            HStack {
                Label("Keep Recent Turns", systemImage: "arrow.counterclockwise.circle")
                    .font(TronTypography.subheadline)
                Spacer()
                Text("\(preserveRecentTurns)")
                    .font(TronTypography.subheadline)
                    .foregroundStyle(.tronEmerald)
                    .monospacedDigit()
                    .frame(minWidth: 20)
                Stepper("", value: $preserveRecentTurns, in: 0...10)
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
            }
            .onChange(of: preserveRecentTurns) { _, newValue in
                updateServerSetting {
                    ServerSettingsUpdate(context: .init(compactor: .init(preserveRecentCount: newValue)))
                }
            }
        } footer: {
            Text("Number of recent turns kept verbatim after compaction. The rest is summarized.")
                .font(TronTypography.caption2)
        }

        // Compact Every Cycle toggle
        Section {
            Toggle(isOn: $forceAlwaysCompact) {
                Label("Compact Every Cycle", systemImage: "arrow.triangle.2.circlepath")
                    .font(TronTypography.subheadline)
            }
            .onChange(of: forceAlwaysCompact) { _, newValue in
                updateServerSetting {
                    ServerSettingsUpdate(context: .init(compactor: .init(forceAlways: newValue)))
                }
            }
        } footer: {
            Text("Force compaction after every response. Useful for testing compaction behavior.")
                .font(TronTypography.caption2)
        }
        .listSectionSpacing(16)
    }
}
