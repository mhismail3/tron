import SwiftUI

struct CompactionSection: View {
    @Binding var triggerTokenThreshold: Double
    @Binding var preserveRecentCount: Int
    @Binding var maxPreservedRatio: Double
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
                .font(TronTypography.sans(size: TronTypography.sizeBody3))
        } footer: {
            Text("Context usage % that triggers compaction. Lower values compact sooner, preserving more headroom.")
                .font(TronTypography.caption2)
        }

        // Keep Recent Turns stepper (0–10)
        Section {
            HStack {
                Label("Keep Recent Turns", systemImage: "arrow.counterclockwise.circle")
                    .font(TronTypography.subheadline)
                Spacer()
                Text("\(preserveRecentCount)")
                    .font(TronTypography.subheadline)
                    .foregroundStyle(.tronEmerald)
                    .monospacedDigit()
                    .frame(minWidth: 20)
                TronStepper(value: $preserveRecentCount, range: 0...10)
            }
            .onChange(of: preserveRecentCount) { _, newValue in
                updateServerSetting {
                    ServerSettingsUpdate(context: .init(compactor: .init(preserveRecentCount: newValue)))
                }
            }
        } footer: {
            Text("Number of recent turns kept verbatim after compaction. The rest is summarized.")
                .font(TronTypography.caption2)
        }

        // Max Preserved Context slider (10%–50%, step 5%)
        Section {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Max Preserved Context", systemImage: "chart.pie")
                        .font(TronTypography.subheadline)
                    Spacer()
                    Text("\(Int(maxPreservedRatio * 100))%")
                        .font(TronTypography.subheadline)
                        .foregroundStyle(.tronEmerald)
                        .monospacedDigit()
                }
                Slider(
                    value: $maxPreservedRatio,
                    in: 0.10...0.50,
                    step: 0.05
                )
                .tint(.tronEmerald)
            }
            .onChange(of: maxPreservedRatio) { _, newValue in
                updateServerSetting {
                    ServerSettingsUpdate(context: .init(compactor: .init(
                        maxPreservedRatio: newValue
                    )))
                }
            }
        } footer: {
            Text("Maximum % of context window that preserved turns can consume.")
                .font(TronTypography.caption2)
        }
        .listSectionSpacing(16)
    }
}
