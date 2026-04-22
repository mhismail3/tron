import SwiftUI

#if DEBUG || BETA
/// Debug-only diagnostics page.
///
/// Renders the `system.getDiagnostics` RPC payload — server identity,
/// session counts, and the full RPC method surface — so developers can
/// inspect a connected server without SSH'ing in.
///
/// Gated by `#if DEBUG || BETA` so the production bundle has neither
/// the page nor the RPC call site for it.
struct DiagnosticsPage: View {
    let rpcClient: RPCClient

    @State private var result: SystemDiagnosticsResult?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var lastFetchedAt: Date?

    var body: some View {
        SettingsPageContainer(title: "Diagnostics") {
            if let result {
                serverCard(result.server)
                sessionsCard(result.sessions)
                rpcCard(result.rpc)
                meta(result: result)
            } else if let errorMessage {
                errorCard(errorMessage)
            } else if isLoading {
                loadingCard
            } else {
                placeholderCard
            }

            refreshCard
        }
        .task { await refresh() }
    }

    // MARK: - Sections

    private func serverCard(_ identity: SystemDiagnosticsResult.ServerIdentity) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Server")
            SettingsCard {
                SettingsRow(icon: "tag", label: "Version") {
                    Text(identity.version)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextMuted)
                }
                SettingsRowDivider()
                SettingsRow(icon: "number", label: "Protocol") {
                    Text("v\(identity.protocolVersion) (min client v\(identity.minClientProtocolVersion))")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextMuted)
                }
                SettingsRowDivider()
                SettingsRow(icon: "cpu", label: "Platform") {
                    Text("\(identity.platform) \(identity.arch)")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextMuted)
                }
                SettingsRowDivider()
                SettingsRow(icon: "person.crop.circle", label: "PID") {
                    Text("\(identity.pid)")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextMuted)
                }
                SettingsRowDivider()
                SettingsRow(icon: "clock", label: "Uptime") {
                    Text(formatUptime(identity.uptimeSeconds))
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextMuted)
                }
                if let origin = identity.origin {
                    SettingsRowDivider()
                    SettingsRow(icon: "network", label: "Origin") {
                        Text(origin)
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextMuted)
                    }
                }
            }
        }
    }

    private func sessionsCard(_ counts: SystemDiagnosticsResult.SessionCounts) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "Sessions")
            SettingsCard {
                SettingsRow(icon: "rectangle.stack", label: "Active Sessions") {
                    Text("\(counts.active)")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextMuted)
                }
                SettingsRowDivider()
                SettingsRow(icon: "play.circle", label: "Active Runs") {
                    Text("\(counts.activeRuns)")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextMuted)
                }
            }
        }
    }

    private func rpcCard(_ surface: SystemDiagnosticsResult.RpcSurface) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(title: "RPC Surface")

            SettingsCard {
                SettingsRow(icon: "number.square", label: "Total Methods") {
                    Text("\(surface.totalMethods)")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextMuted)
                }
            }

            SettingsCaption(text: "By Group")

            SettingsCard {
                let sortedGroups = surface.methodsByGroup.sorted { $0.key < $1.key }
                ForEach(Array(sortedGroups.enumerated()), id: \.offset) { index, entry in
                    SettingsRow(icon: "square.grid.2x2", label: entry.key) {
                        Text("\(entry.value)")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextMuted)
                    }
                    if index < sortedGroups.count - 1 {
                        SettingsRowDivider()
                    }
                }
            }

            SettingsCaption(text: "\(surface.methods.count) methods total — tap to expand")

            DisclosureGroup {
                SettingsCard {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(surface.methods, id: \.self) { method in
                            Text(method)
                                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                                .foregroundStyle(.tronTextPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            } label: {
                Text("All methods")
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronEmerald)
            }
            .tint(.tronEmerald)
            .padding(.horizontal, 4)
            .padding(.top, 8)
        }
    }

    private func meta(result: SystemDiagnosticsResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Snapshot: \(result.timestamp)")
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
            if let lastFetchedAt {
                Text("Fetched at \(lastFetchedAt.formatted(date: .omitted, time: .standard))")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    // MARK: - State cards

    private var loadingCard: some View {
        SettingsCard {
            HStack {
                ProgressView().tint(.tronEmerald)
                Text("Fetching diagnostics…")
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(.tronTextPrimary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
        }
    }

    private var placeholderCard: some View {
        SettingsCard {
            Text("Tap Refresh to fetch a snapshot.")
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(.tronTextMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
        }
    }

    private func errorCard(_ message: String) -> some View {
        SettingsCard(accent: .tronError) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Failed to fetch diagnostics")
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronError)
                Text(message)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
        }
    }

    private var refreshCard: some View {
        SettingsCard(interactive: true) {
            Button {
                Task { await refresh() }
            } label: {
                SettingsRow(icon: "arrow.clockwise", label: "Refresh") {
                    if isLoading {
                        ProgressView().tint(.tronEmerald).scaleEffect(0.7)
                    } else {
                        EmptyView()
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
        }
    }

    // MARK: - Actions

    private func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let snapshot = try await rpcClient.misc.getDiagnostics()
            result = snapshot
            errorMessage = nil
            lastFetchedAt = Date()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func formatUptime(_ seconds: Int) -> String {
        // A plain "Nd Nh Nm Ns" breakdown. Human-friendly, never "1.5 days".
        if seconds < 60 { return "\(seconds)s" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        var parts: [String] = []
        if days > 0 { parts.append("\(days)d") }
        if hours > 0 { parts.append("\(hours)h") }
        if minutes > 0 { parts.append("\(minutes)m") }
        if secs > 0 && days == 0 { parts.append("\(secs)s") }
        return parts.joined(separator: " ")
    }
}
#endif
