import SwiftUI

struct MemorySettingsSection: View {
    @Binding var memoryAutoInject: Bool
    @Binding var memoryAutoInjectCount: Int
    let updateServerSetting: (() -> ServerSettingsUpdate) -> Void

    var body: some View {
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
                    Label("Entries to load", systemImage: "list.number")
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
        } header: {
            Text("Memory")
                .font(TronTypography.caption)
        } footer: {
            Text("Load recent session memories at start of new sessions")
                .font(TronTypography.caption2)
        }
        .listSectionSpacing(16)
    }
}
