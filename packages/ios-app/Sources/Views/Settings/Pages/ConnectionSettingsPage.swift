import SwiftUI

struct ConnectionSettingsPage: View {
    @Binding var serverHost: String
    @Binding var serverPort: String
    let settingsState: SettingsState
    let onHostSubmit: () -> Void
    let onPortChange: (String) -> Void
    let updateServerSetting: (() -> ServerSettingsUpdate) -> Void

    @FocusState private var focusedField: Field?

    private enum Field {
        case host, port
    }

    var body: some View {
        SettingsPageContainer(title: "Connection") {
            // Presets
            if !settingsState.connectionPresets.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsSectionHeader(title: "Presets")

                    VStack(spacing: 8) {
                        ForEach(settingsState.connectionPresets) { preset in
                            presetRow(preset)
                        }
                    }
                }
            }

            // Server
            VStack(alignment: .leading, spacing: 0) {
                SettingsSectionHeader(title: "Server")

                SettingsCard {
                    HStack {
                        Image(systemName: "globe")
                            .font(TronTypography.sans(size: TronTypography.sizeBody))
                            .foregroundStyle(.tronEmerald)
                            .frame(width: 18)
                        Text("Host")
                            .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                        Spacer()
                        TextField("localhost", text: $serverHost)
                            .font(TronTypography.mono(size: TronTypography.sizeBody))
                            .multilineTextAlignment(.trailing)
                            .textContentType(.URL)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .host)
                            .onSubmit { onHostSubmit() }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                    .onTapGesture { focusedField = .host }

                    SettingsRowDivider()

                    HStack {
                        Image(systemName: "number")
                            .font(TronTypography.sans(size: TronTypography.sizeBody))
                            .foregroundStyle(.tronEmerald)
                            .frame(width: 18)
                        Text("Port")
                            .font(TronTypography.mono(size: TronTypography.sizeBody, weight: .medium))
                        Spacer()
                        TextField("9847", text: $serverPort)
                            .font(TronTypography.mono(size: TronTypography.sizeBody))
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                            .focused($focusedField, equals: .port)
                            .frame(width: 100)
                            .onChange(of: serverPort) { _, newValue in
                                if !newValue.isEmpty {
                                    onPortChange(newValue)
                                }
                            }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                    .onTapGesture { focusedField = .port }
                }
            }
        }
    }

    // MARK: - Preset Row

    private func presetRow(_ preset: ConnectionPreset) -> some View {
        let selected = serverHost == preset.host && serverPort == String(preset.port)

        return HStack(spacing: 10) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(TronTypography.sans(size: TronTypography.sizeXL))
                .foregroundStyle(selected ? .tronEmerald : .tronTextMuted)

            VStack(alignment: .leading, spacing: 2) {
                Text(preset.label)
                    .font(TronTypography.mono(size: TronTypography.sizeBody3, weight: .medium))
                    .foregroundStyle(.tronTextPrimary)
                Text("\(preset.host):\(String(preset.port))")
                    .font(TronTypography.code(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextSecondary)
            }

            Spacer()

            Image(systemName: "server.rack")
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(.tronEmerald.opacity(0.6))
        }
        .padding(10)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                applyPreset(preset)
            }
        }
        .sectionFill(.tronEmerald)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Actions

    private func applyPreset(_ preset: ConnectionPreset) {
        serverHost = preset.host
        let portString = String(preset.port)
        serverPort = portString
        onPortChange(portString)
        onHostSubmit()
    }
}
