import SwiftUI

struct TaskSettingsSection: View {
    @Binding var taskAutoInjectEnabled: Bool
    let updateServerSetting: (() -> ServerSettingsUpdate) -> Void

    var body: some View {
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
        } header: {
            Text("Task Manager")
                .font(TronTypography.caption)
        } footer: {
            Text("Include active task summary in each turn's context")
                .font(TronTypography.caption2)
        }
        .listSectionSpacing(16)
    }
}
