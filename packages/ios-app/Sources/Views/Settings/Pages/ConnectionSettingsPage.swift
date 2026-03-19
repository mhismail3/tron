import SwiftUI

private struct ServerPreset: Identifiable {
    let id: String
    let label: String
    let host: String
    let port: String

    static let presets: [ServerPreset] = [
        ServerPreset(id: "main", label: "Main", host: "100.64.213.113", port: "9847"),
        ServerPreset(id: "secondary", label: "Secondary", host: "100.95.255.62", port: "9847"),
    ]
}

struct ConnectionSettingsPage: View {
    @Binding var serverHost: String
    @Binding var serverPort: String
    let settingsState: SettingsState
    let onHostSubmit: () -> Void
    let onPortChange: (String) -> Void
    let updateServerSetting: (() -> ServerSettingsUpdate) -> Void

    private func applyPreset(_ preset: ServerPreset) {
        serverHost = preset.host
        serverPort = preset.port
        onPortChange(preset.port)
        onHostSubmit()
    }

    private func isSelected(_ preset: ServerPreset) -> Bool {
        serverHost == preset.host && serverPort == preset.port
    }

    private func presetChip(_ preset: ServerPreset) -> some View {
        let selected = isSelected(preset)
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                applyPreset(preset)
            }
        } label: {
            HStack(spacing: 6) {
                Text(preset.label)
                    .font(TronTypography.caption)
                Text("\(preset.host):\(preset.port)")
                    .font(TronTypography.caption)
                    .opacity(selected ? 0.8 : 0.5)
            }
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(selected ? .tronSurface : .tronTextPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(selected ? Color.tronEmerald : Color.tronSurfaceElevated)
            )
            .overlay(
                Capsule()
                    .strokeBorder(selected ? Color.clear : Color.tronBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(ServerPreset.presets) { preset in
                                presetChip(preset)
                            }
                        }
                    }
                } header: {
                    Text("Presets")
                        .font(TronTypography.sans(size: TronTypography.sizeBody3))
                }

                ServerSettingsSection(
                    serverHost: $serverHost,
                    serverPort: $serverPort,
                    onHostSubmit: onHostSubmit,
                    onPortChange: onPortChange
                )

                if !settingsState.anthropicAccounts.isEmpty {
                    AccountSection(
                        accounts: settingsState.anthropicAccounts,
                        selectedAccount: Bindable(settingsState).selectedAnthropicAccount,
                        updateServerSetting: updateServerSetting
                    )
                }
            }
            .listStyle(.insetGrouped)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Connection")
                        .font(TronTypography.button)
                        .foregroundStyle(.tronEmerald)
                }
            }
        }
    }
}
