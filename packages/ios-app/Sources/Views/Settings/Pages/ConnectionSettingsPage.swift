import SwiftUI

struct ConnectionSettingsPage: View {
    @Environment(\.dismiss) private var dismiss
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
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Presets
                    if !settingsState.connectionPresets.isEmpty {
                        Text("Presets")
                            .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                            .foregroundStyle(.tronTextSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        ForEach(settingsState.connectionPresets) { preset in
                            presetRow(preset)
                        }
                    }

                    // Server
                    Text("Server")
                        .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .medium))
                        .foregroundStyle(.tronTextSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(spacing: 0) {
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

                        Divider()
                            .padding(.leading, 38)

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
                    .sectionFill(.tronEmerald)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 40)
            }
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
        .padding(12)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                applyPreset(preset)
            }
        }
        .sectionFill(.tronEmerald)
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.tronEmerald.opacity(0.5), lineWidth: 1)
            }
        }
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
