import SwiftUI

struct ContextSettingsSection: View {
    @Binding var memoryLedgerEnabled: Bool
    @Binding var memoryAutoInject: Bool
    @Binding var memoryAutoInjectCount: Int
    @Binding var taskAutoInjectEnabled: Bool
    @Binding var discoverStandaloneFiles: Bool
    let updateServerSetting: (() -> ServerSettingsUpdate) -> Void

    var body: some View {
        // Ledger — own pill with caption
        Section {
            Toggle(isOn: $memoryLedgerEnabled) {
                Label("Auto-update ledger", systemImage: "book.closed")
                    .font(TronTypography.subheadline)
            }
            .tint(.tronEmerald)
            .onChange(of: memoryLedgerEnabled) { _, newValue in
                updateServerSetting {
                    ServerSettingsUpdate(context: .init(memory: .init(ledger: .init(enabled: newValue))))
                }
            }
        } header: {
            Text("Context")
                .font(TronTypography.bodySM)
        } footer: {
            Text("Automatically update the session memory ledger after each response.")
                .font(TronTypography.caption2)
        }

        // Memories — own pill
        Section {
            Toggle(isOn: $memoryAutoInject) {
                Label("Auto-inject memories", systemImage: "brain.head.profile")
                    .font(TronTypography.subheadline)
            }
            .tint(.tronEmerald)
            .onChange(of: memoryAutoInject) { _, newValue in
                updateServerSetting {
                    ServerSettingsUpdate(context: .init(memory: .init(autoInject: .init(enabled: newValue))))
                }
            }

            if memoryAutoInject {
                HStack {
                    Label("Maximum entries to load", systemImage: "list.number")
                        .font(TronTypography.subheadline)
                    Spacer()
                    Text("\(memoryAutoInjectCount)")
                        .font(TronTypography.subheadline)
                        .foregroundStyle(.tronEmerald)
                        .monospacedDigit()
                        .frame(minWidth: 20)
                    TronStepper(value: $memoryAutoInjectCount, range: 1...10)
                }
                .onChange(of: memoryAutoInjectCount) { _, newValue in
                    updateServerSetting {
                        ServerSettingsUpdate(context: .init(memory: .init(autoInject: .init(count: newValue))))
                    }
                }
            }
        } footer: {
            Text("Load recent session memories at start of new sessions.")
                .font(TronTypography.caption2)
        }

        // Tasks + rules
        Section {
            Toggle(isOn: $taskAutoInjectEnabled) {
                Label("Auto-inject task summary", systemImage: "list.bullet.clipboard")
                    .font(TronTypography.subheadline)
            }
            .tint(.tronEmerald)
            .onChange(of: taskAutoInjectEnabled) { _, newValue in
                updateServerSetting {
                    ServerSettingsUpdate(context: .init(tasks: .init(autoInject: .init(enabled: newValue))))
                }
            }

            Toggle(isOn: $discoverStandaloneFiles) {
                Label("Discover standalone rules files", systemImage: "doc.text.magnifyingglass")
                    .font(TronTypography.subheadline)
            }
            .tint(.tronEmerald)
            .onChange(of: discoverStandaloneFiles) { _, newValue in
                updateServerSetting {
                    ServerSettingsUpdate(context: .init(rules: .init(discoverStandaloneFiles: newValue)))
                }
            }
        } footer: {
            Text("Include active task summaries and discover rules files outside .claude/ directories.")
                .font(TronTypography.caption2)
        }
        .listSectionSpacing(16)
    }
}
