import SwiftUI

struct ConnectionSettingsPage: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var serverHost: String
    @Binding var serverPort: String
    let settingsState: SettingsState
    let onHostSubmit: () -> Void
    let onPortChange: (String) -> Void
    let updateServerSetting: (() -> ServerSettingsUpdate) -> Void

    private func applyPreset(_ preset: ConnectionPreset) {
        serverHost = preset.host
        let portString = String(preset.port)
        serverPort = portString
        onPortChange(portString)
        onHostSubmit()
    }

    private func isSelected(_ preset: ConnectionPreset) -> Bool {
        serverHost == preset.host && serverPort == String(preset.port)
    }

    private func presetChip(_ preset: ConnectionPreset) -> some View {
        let selected = isSelected(preset)
        let portString = String(preset.port)
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                applyPreset(preset)
            }
        } label: {
            HStack(spacing: 6) {
                Text(preset.label)
                    .font(TronTypography.caption)
                Text("\(preset.host):\(portString)")
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
                if !settingsState.connectionPresets.isEmpty {
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(settingsState.connectionPresets) { preset in
                                    presetChip(preset)
                                }
                            }
                        }
                    } header: {
                        Text("Presets")
                            .font(TronTypography.sans(size: TronTypography.sizeBody3))
                    }
                }

                ServerSettingsSection(
                    serverHost: $serverHost,
                    serverPort: $serverPort,
                    onHostSubmit: onHostSubmit,
                    onPortChange: onPortChange
                )
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background { Color.tronBackground.ignoresSafeArea() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Connection")
                        .font(TronTypography.button)
                        .foregroundStyle(.tronEmerald)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(.tronEmerald)
                    }
                }
            }
        }
    }
}
