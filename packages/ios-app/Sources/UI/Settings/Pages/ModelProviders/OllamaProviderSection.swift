import SwiftUI

/// Ollama is a runtime endpoint, not a credential provider. This section
/// projects the configured server URL and the server's live `/api/tags` plus
/// `/api/show` evidence without attempting to install or control Ollama.
struct OllamaProviderSection: View {
    let baseUrl: String
    let models: [ModelInfo]
    let isRefreshing: Bool
    let onSaveEndpoint: (String) -> Void
    let onRefresh: () async -> Void

    @State private var endpointDraft = ""

    private var reachable: Bool? {
        models.compactMap(\.providerReachable).first
    }

    private var installedModels: [ModelInfo] {
        models.filter { $0.installed == true }
    }

    private var endpointIsValid: Bool {
        guard let components = URLComponents(string: endpointDraft),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host != nil,
              components.query == nil,
              components.fragment == nil
        else { return false }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsCard(accent: .tronAmber) {
                header
                SettingsRowDivider()
                statusRow
                SettingsRowDivider()
                endpointEditor
            }

            if reachable == true {
                installedCard
            } else if reachable == false {
                guidanceCard(
                    icon: "exclamationmark.triangle.fill",
                    title: "Endpoint unavailable",
                    detail: "Start Ollama on the configured host or correct the endpoint. Tron does not install or manage the Ollama service."
                )
            }
        }
        .onAppear { endpointDraft = baseUrl }
        .onChange(of: baseUrl) { _, newValue in endpointDraft = newValue }
    }

    private var header: some View {
        HStack(spacing: ProviderSettingsRowLayout.spacing) {
            Image("IconOllama")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.tronAmber)
                .frame(
                    width: ProviderSettingsRowLayout.leadingIconWidth,
                    height: ProviderSettingsRowLayout.leadingIconWidth
                )
            Text("Ollama")
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
                .multilineTextAlignment(.leading)
            if reachable == true {
                Image(systemName: "checkmark.circle.fill")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronSuccess)
            }
            Spacer()
            Button {
                Task { await onRefresh() }
            } label: {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.tronAmber)
                } else {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                        .foregroundStyle(.tronAmber)
                }
            }
            .buttonStyle(.plain)
            .frame(
                width: ProviderSettingsRowLayout.trailingActionWidth,
                height: ProviderSettingsRowLayout.circularActionDiameter,
                alignment: .trailing
            )
            .disabled(isRefreshing)
            .accessibilityLabel("Refresh Ollama models")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var statusRow: some View {
        HStack(alignment: .top, spacing: ProviderSettingsRowLayout.spacing) {
            Image(systemName: statusIcon)
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(statusColor)
                .frame(width: ProviderSettingsRowLayout.leadingIconWidth)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronTextPrimary)
                Text(statusDetail)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear
                .frame(width: ProviderSettingsRowLayout.trailingActionWidth, height: 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    private var statusIcon: String {
        switch reachable {
        case true: "checkmark.circle.fill"
        case false: "exclamationmark.triangle.fill"
        case nil: "circle.dotted"
        }
    }

    private var statusColor: Color {
        switch reachable {
        case true: .tronSuccess
        case false: .tronError
        case nil: .tronTextMuted
        }
    }

    private var statusTitle: String {
        switch reachable {
        case true: "Reachable"
        case false: "Not reachable"
        case nil: "Checking endpoint"
        }
    }

    private var statusDetail: String {
        switch reachable {
        case true: "\(installedModels.count) installed model\(installedModels.count == 1 ? "" : "s") discovered."
        case false: models.first?.unavailableReason ?? "The server could not reach this Ollama endpoint."
        case nil: "Refreshing installed models and capability metadata."
        }
    }

    private var endpointEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: ProviderSettingsRowLayout.spacing) {
                Image(systemName: "network")
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(.tronAmber)
                    .frame(width: ProviderSettingsRowLayout.leadingIconWidth)
                Text("Endpoint")
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear
                    .frame(width: ProviderSettingsRowLayout.trailingActionWidth, height: 1)
            }

            HStack(spacing: ProviderSettingsRowLayout.spacing) {
                Color.clear
                    .frame(width: ProviderSettingsRowLayout.leadingIconWidth, height: 1)
                TextField("http://localhost:11434", text: $endpointDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(TronTypography.code(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(.tronTextMuted.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

                Button("Save") {
                    onSaveEndpoint(endpointDraft.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(.tronAmber)
                .frame(
                    width: ProviderSettingsRowLayout.trailingActionWidth,
                    alignment: .trailing
                )
                .disabled(!endpointIsValid || endpointDraft == baseUrl)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var installedCard: some View {
        if installedModels.isEmpty {
            guidanceCard(
                icon: "arrow.down.circle",
                title: "No models installed",
                detail: "Pull a model with Ollama, then refresh. For example: ollama pull gemma4:e4b"
            )
        } else {
            SettingsCard(accent: .tronAmber) {
                ForEach(Array(installedModels.enumerated()), id: \.element.id) { index, model in
                    installedModelRow(model)
                    if index < installedModels.count - 1 { SettingsRowDivider() }
                }
            }
        }
    }

    private func installedModelRow(_ model: ModelInfo) -> some View {
        HStack(alignment: .top, spacing: ProviderSettingsRowLayout.spacing) {
            Image(systemName: "cpu")
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(.tronAmber)
                .frame(width: ProviderSettingsRowLayout.leadingIconWidth)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.formattedModelName)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                    .foregroundStyle(.tronTextPrimary)
                Text(modelSummary(model))
                    .font(TronTypography.sans(size: TronTypography.sizeCaption))
                    .foregroundStyle(.tronTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear
                .frame(width: ProviderSettingsRowLayout.trailingActionWidth, height: 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func modelSummary(_ model: ModelInfo) -> String {
        var details = [model.formattedContextWindow]
        if let parameterSize = model.parameterSize { details.append(parameterSize) }
        var capabilities: [String] = []
        if model.supportsTools == true { capabilities.append("tools") }
        if model.supportsThinking { capabilities.append("thinking") }
        if model.supportsImages { capabilities.append("vision") }
        if !capabilities.isEmpty { details.append(capabilities.joined(separator: ", ")) }
        return details.joined(separator: " · ")
    }

    private func guidanceCard(icon: String, title: String, detail: String) -> some View {
        SettingsCard(accent: .tronAmber) {
            HStack(alignment: .top, spacing: ProviderSettingsRowLayout.spacing) {
                Image(systemName: icon)
                    .font(TronTypography.sans(size: TronTypography.sizeBody))
                    .foregroundStyle(.tronAmber)
                    .frame(width: ProviderSettingsRowLayout.leadingIconWidth)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .medium))
                    Text(detail)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextSecondary)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear
                    .frame(width: ProviderSettingsRowLayout.trailingActionWidth, height: 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
    }
}
