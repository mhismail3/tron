import SwiftUI

@available(iOS 26.0, *)
struct CodexAppSetupView: View {
    let viewModel: CodexAppViewModel
    let activeServer: PairedServer?
    let onDone: () -> Void

    private var accent: Color { .tronInfo }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                SettingsInfoCard(
                    icon: "terminal",
                    title: activeServer.map { "Codex on \($0.label)" } ?? "Pair a Server",
                    description: description,
                    accent: accent
                )

                if activeServer != nil {
                    statusSection
                    defaultsSection
                    actionsSection
                }
            }
            .padding(18)
        }
    }

    private var description: String {
        guard activeServer != nil else {
            return "Codex mode needs an active paired machine."
        }
        guard let status = viewModel.serverStatus else {
            return "Tron Server owns the Codex App Server process and endpoint."
        }
        if !status.enabled {
            return "Codex App Server is disabled in Tron Server settings."
        }
        if status.isRunning {
            return "Tron Server is running Codex App Server and this app connects directly to it."
        }
        return status.lastError ?? "Codex App Server is \(status.state)."
    }

    private var statusSection: some View {
        VStack(spacing: 0) {
            SettingsSectionHeader(title: "Server Managed", color: accent)
            SettingsCard(accent: accent) {
                SettingsRow(icon: "server.rack", label: "State", accentColor: accent) {
                    Text(viewModel.serverStatus?.state ?? "loading")
                        .font(TronTypography.codeSM)
                        .foregroundStyle(statusColor)
                }
                SettingsRowDivider()
                SettingsRow(icon: "network", label: "Endpoint", accentColor: accent) {
                    Text(viewModel.activeEndpoint?.url.absoluteString ?? viewModel.serverStatus?.listenUrl ?? "Unavailable")
                        .font(TronTypography.codeSM)
                        .foregroundStyle(.tronTextSecondary)
                        .lineLimit(1)
                }
                if let pid = viewModel.serverStatus?.pid {
                    SettingsRowDivider()
                    SettingsRow(icon: "number", label: "PID", accentColor: accent) {
                        Text("\(pid)")
                            .font(TronTypography.codeSM)
                            .foregroundStyle(.tronTextSecondary)
                    }
                }
            }
        }
    }

    private var defaultsSection: some View {
        VStack(spacing: 0) {
            SettingsSectionHeader(title: "Thread Defaults", color: accent)
            SettingsCard(accent: accent) {
                SettingsRow(icon: "folder", label: "Cwd", accentColor: accent) {
                    Text(viewModel.serverStatus?.defaults.preferredCwd?.nilIfEmpty ?? "Codex default")
                        .font(TronTypography.codeSM)
                        .foregroundStyle(.tronTextSecondary)
                        .lineLimit(1)
                }
                SettingsRowDivider()
                SettingsRow(icon: "cpu", label: "Model", accentColor: accent) {
                    Text(viewModel.serverStatus?.defaults.preferredModel?.nilIfEmpty ?? "Codex default")
                        .font(TronTypography.codeSM)
                        .foregroundStyle(.tronTextSecondary)
                        .lineLimit(1)
                }
                SettingsRowDivider()
                SettingsRow(icon: "checkmark.shield", label: "Approvals", accentColor: accent) {
                    Text(viewModel.serverStatus?.defaults.approvalPolicy.title ?? "On Request")
                        .font(TronTypography.codeSM)
                        .foregroundStyle(.tronTextSecondary)
                }
                SettingsRowDivider()
                SettingsRow(icon: "shippingbox", label: "Sandbox", accentColor: accent) {
                    Text(viewModel.serverStatus?.defaults.sandboxMode.title ?? "Workspace Write")
                        .font(TronTypography.codeSM)
                        .foregroundStyle(.tronTextSecondary)
                }
            }
        }
    }

    private var actionsSection: some View {
        HStack(spacing: 12) {
            Button {
                Task { try? await viewModel.refreshManagedServerStatus() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)

            Button {
                Task {
                    try? await viewModel.connect()
                    onDone()
                }
            } label: {
                Label("Connect", systemImage: "bolt.horizontal")
            }
            .buttonStyle(.borderedProminent)
            .tint(accent)
            .disabled(viewModel.activeEndpoint == nil)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var statusColor: Color {
        guard let status = viewModel.serverStatus else { return .tronTextMuted }
        if status.isRunning { return .tronSuccess }
        if status.enabled { return .tronWarning }
        return .tronTextMuted
    }
}
