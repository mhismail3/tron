import SwiftUI

struct CapabilityInvocationChip: View {
    let data: CapabilityInvocationData
    var onTap: (() -> Void)?
    var onCancel: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: CapabilityPresentation.symbol(for: data.identity))
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 3) {
                    Text(data.displayName)
                        .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .semibold))
                        .foregroundStyle(.tronTextPrimary)
                        .lineLimit(1)

                    Text(subtitle)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .regular))
                        .foregroundStyle(.tronTextMuted)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if data.status == .running || data.status == .generating {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: data.status.iconName)
                        .foregroundStyle(statusTint)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.tronSurface.opacity(colorScheme == .light ? 0.92 : 0.68))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if data.status == .running || data.status == .generating {
                Button(role: .destructive) {
                    onCancel?()
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tint: Color {
        CapabilityPresentation.color(for: data.identity)
    }

    private var statusTint: Color {
        switch data.status {
        case .success: .tronSuccess
        case .error, .unavailable: .tronError
        case .approvalRequired: .tronAmber
        case .generating, .running: tint
        }
    }

    private var subtitle: String {
        if let duration = data.formattedDuration {
            return "\(data.subtitle) · \(duration)"
        }
        return data.subtitle
    }
}

struct CapabilityInvocationDetailSheet: View {
    let data: CapabilityInvocationData

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CapabilityDetailHeader(data: data)
                CapabilityMetadataSection(identity: data.identity)

                if !data.arguments.isEmpty {
                    CapabilitySection(title: "Arguments") {
                        CapabilityInvocationCodeBlock(text: data.arguments)
                    }
                }

                if let result = data.result, !result.isEmpty {
                    CapabilitySection(title: "Result") {
                        CapabilityResultRenderer(
                            content: result,
                            details: data.details,
                            identity: data.identity
                        )
                    }
                }

                if !data.logs.isEmpty {
                    CapabilitySection(title: "Logs") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(data.logs.enumerated()), id: \.offset) { _, line in
                                CapabilityInvocationCodeBlock(text: line)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle(data.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct CapabilityInvocationResultView: View {
    let result: CapabilityInvocationResultData

    var body: some View {
        CapabilityResultRenderer(
            content: result.content,
            details: result.details,
            identity: result.identity
        )
    }
}

private struct CapabilityDetailHeader: View {
    let data: CapabilityInvocationData

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: CapabilityPresentation.symbol(for: data.identity))
                .font(TronTypography.sans(size: 24, weight: .semibold))
                .foregroundStyle(CapabilityPresentation.color(for: data.identity))
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 4) {
                Text(data.displayName)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                Text(data.statusLabel)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                    .foregroundStyle(.tronTextMuted)
            }
            Spacer()
        }
    }
}

private struct CapabilityMetadataSection: View {
    let identity: CapabilityIdentity

    var body: some View {
        CapabilitySection(title: "Identity") {
            VStack(alignment: .leading, spacing: 8) {
                metadataRow("Contract", identity.contractId)
                metadataRow("Implementation", identity.implementationId)
                metadataRow("Function", identity.functionId)
                metadataRow("Plugin", identity.pluginId)
                metadataRow("Worker", identity.workerId)
                metadataRow("Catalog", identity.catalogRevision.map(String.init))
                metadataRow("Schema", identity.schemaDigest)
                metadataRow("Trust", identity.trustTier)
                metadataRow("Risk", identity.riskLevel)
                metadataRow("Effect", identity.effectClass)
                metadataRow("Trace", identity.traceId)
                metadataRow("Binding", identity.bindingDecisionId)
            }
        }
    }

    @ViewBuilder
    private func metadataRow(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .top, spacing: 12) {
                Text(label)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(.tronTextMuted)
                    .frame(width: 92, alignment: .leading)
                Text(value)
                    .font(TronTypography.code(size: TronTypography.sizeCaption, weight: .regular))
                    .foregroundStyle(.tronTextSecondary)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct CapabilitySection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
            content
        }
    }
}

struct CapabilityResultRenderer: View {
    let content: String
    let details: [String: AnyCodable]?
    let identity: CapabilityIdentity

    var body: some View {
        if let details, let pretty = Self.prettyJSON(details) {
            CapabilityInvocationCodeBlock(text: pretty)
        } else if looksLikeJSON(content), let pretty = Self.prettyJSONString(content) {
            CapabilityInvocationCodeBlock(text: pretty)
        } else {
            CapabilityInvocationCodeBlock(text: content)
        }
    }

    private func looksLikeJSON(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
    }

    private static func prettyJSON(_ value: [String: AnyCodable]) -> String? {
        let raw = value.mapValues(\.value)
        guard JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func prettyJSONString(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        else { return nil }
        return String(data: pretty, encoding: .utf8)
    }
}

private struct CapabilityInvocationCodeBlock: View {
    let text: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(TronTypography.code(size: TronTypography.sizeCaption, weight: .regular))
                .foregroundStyle(.tronTextSecondary)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.tronSurface.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private extension CapabilityInvocationData {
    var statusLabel: String {
        switch status {
        case .generating: "Generating"
        case .running: "Running"
        case .approvalRequired: "Approval required"
        case .success: "Completed"
        case .error: "Failed"
        case .unavailable: "Unavailable"
        }
    }
}
