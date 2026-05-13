import SwiftUI

@available(iOS 26.0, *)
struct CapabilityInvocationChip: View {
    let data: CapabilityInvocationData
    var onTap: (() -> Void)?
    var onCancel: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    private var display: CapabilityInvocationDisplayModel { data.display }
    private var tint: Color { CapabilityPresentation.color(for: data.identity) }

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: CapabilityPresentation.symbol(for: data.identity))
                    .font(TronTypography.sans(size: TronTypography.sizeBodyLG, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 5) {
                    Text(titleString(size: TronTypography.sizeBody2))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Text(display.statusWithDuration)
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                        .foregroundStyle(.tronTextMuted)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                statusAccessory
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.clear)
                    .glassEffect(
                        .regular.tint(tint.opacity(colorScheme == .light ? 0.14 : 0.22)).interactive(),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
            }
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

    private func titleString(size: CGFloat) -> AttributedString {
        var title = AttributedString(display.primitiveTitle)
        title.font = TronTypography.sans(size: size, weight: .bold)
        title.foregroundColor = .tronTextPrimary

        let detail = display.commandText.nilIfEmpty.map { " \($0)" } ?? ""
        var detailText = AttributedString(detail)
        detailText.font = TronTypography.sans(size: size, weight: .medium)
        detailText.foregroundColor = .tronTextSecondary
        return title + detailText
    }

    @ViewBuilder
    private var statusAccessory: some View {
        if data.status == .running || data.status == .generating {
            ProgressView()
                .controlSize(.small)
                .tint(tint)
        } else {
            Image(systemName: data.status.iconName)
                .font(TronTypography.sans(size: TronTypography.sizeBodyLG, weight: .semibold))
                .foregroundStyle(statusTint)
        }
    }

    private var statusTint: Color {
        switch data.status {
        case .success: .tronSuccess
        case .error, .unavailable: .tronError
        case .approvalRequired: .tronAmber
        case .generating, .running: tint
        }
    }
}

@available(iOS 26.0, *)
struct CapabilityInvocationDetailSheet: View {
    let data: CapabilityInvocationData

    @Environment(\.colorScheme) private var colorScheme

    private var display: CapabilityInvocationDisplayModel { data.display }
    private var accent: Color { CapabilityPresentation.color(for: data.identity) }
    private var tint: TintedColors { TintedColors(accent: accent, colorScheme: colorScheme) }

    var body: some View {
        CapabilityDetailSheetContainer(
            modelPrimitiveName: display.primitiveTitle,
            iconName: CapabilityPresentation.symbol(for: data.identity),
            accent: accent
        ) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 20) {
                    CapabilityDetailHeader(data: data)
                        .sheetSection()

                    requestSection
                    resultSection
                    logsSection
                    technicalSection
                }
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
        }
    }

    @ViewBuilder
    private var requestSection: some View {
        if !display.requestRows.isEmpty || display.prettyArguments != nil {
            CapabilityDetailSection(title: "Request", accent: accent, tint: tint) {
                VStack(alignment: .leading, spacing: 12) {
                    CapabilityReadableRows(rows: display.requestRows, tint: tint)

                    if let prettyArguments = display.prettyArguments {
                        CapabilityRawDisclosure(title: "Raw arguments", text: prettyArguments, tint: tint)
                    }
                }
            }
            .sheetSection()
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        if let result = data.result, !result.isEmpty {
            CapabilityDetailSection(title: data.status == .error ? "Failure" : "Result", accent: resultAccent, tint: resultTint) {
                CapabilityResultRenderer(
                    content: result,
                    details: data.details,
                    identity: data.identity
                )
            }
            .sheetSection()
        }
    }

    @ViewBuilder
    private var logsSection: some View {
        if !data.logs.isEmpty {
            CapabilityDetailSection(title: "Logs", accent: .tronSlate, tint: tint) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(data.logs.enumerated()), id: \.offset) { _, line in
                        CapabilityInvocationCodeBlock(text: line)
                    }
                }
            }
            .sheetSection()
        }
    }

    @ViewBuilder
    private var technicalSection: some View {
        if !display.technicalRows.isEmpty {
            CapabilityDetailSection(title: "Technical", accent: .tronSlate, tint: tint) {
                CapabilityReadableRows(rows: display.technicalRows, tint: tint)
            }
            .sheetSection()
        }
    }

    private var resultAccent: Color {
        data.status == .error ? .tronError : .tronSuccess
    }

    private var resultTint: TintedColors {
        TintedColors(accent: resultAccent, colorScheme: colorScheme)
    }
}

@available(iOS 26.0, *)
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

@available(iOS 26.0, *)
private struct CapabilityDetailHeader: View {
    let data: CapabilityInvocationData

    @Environment(\.colorScheme) private var colorScheme

    private var display: CapabilityInvocationDisplayModel { data.display }
    private var accent: Color { CapabilityPresentation.color(for: data.identity) }
    private var tint: TintedColors { TintedColors(accent: accent, colorScheme: colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: CapabilityPresentation.symbol(for: data.identity))
                    .font(TronTypography.sans(size: 28, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 5) {
                    Text(titleString(size: TronTypography.sizeBodyLG))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(display.statusWithDuration)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                        .foregroundStyle(tint.secondary)
                }

                Spacer(minLength: 8)

                CapabilityStatusBadge(status: data.status)
            }

            if let progressMessage = data.progressMessage?.nilIfEmpty {
                Text(progressMessage)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.clear)
                .glassEffect(
                    .regular.tint(accent.opacity(0.14)),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
        }
    }

    private func titleString(size: CGFloat) -> AttributedString {
        var title = AttributedString(display.primitiveTitle)
        title.font = TronTypography.sans(size: size, weight: .bold)
        title.foregroundColor = .tronTextPrimary

        let detail = display.commandText.nilIfEmpty.map { " \($0)" } ?? ""
        var detailText = AttributedString(detail)
        detailText.font = TronTypography.sans(size: size, weight: .medium)
        detailText.foregroundColor = .tronTextSecondary
        return title + detailText
    }
}

@available(iOS 26.0, *)
private struct CapabilityReadableRows: View {
    let rows: [CapabilityDisplayRow]
    let tint: TintedColors

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(rows) { row in
                CapabilityReadableRow(row: row, tint: tint)
            }
        }
    }
}

@available(iOS 26.0, *)
private struct CapabilityReadableRow: View {
    let row: CapabilityDisplayRow
    let tint: TintedColors

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.label)
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(tint.subtle)
            Text(row.value)
                .font(row.isTechnical ? TronTypography.code(size: TronTypography.sizeCaption, weight: .regular) : TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(row.isTechnical ? tint.body : .tronTextPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@available(iOS 26.0, *)
private struct CapabilityRawDisclosure: View {
    let title: String
    let text: String
    let tint: TintedColors

    var body: some View {
        DisclosureGroup {
            CapabilityInvocationCodeBlock(text: text)
                .padding(.top, 8)
        } label: {
            Text(title)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                .foregroundStyle(tint.heading)
        }
    }
}

@available(iOS 26.0, *)
struct CapabilityResultRenderer: View {
    let content: String
    let details: [String: AnyCodable]?
    let identity: CapabilityIdentity

    @Environment(\.colorScheme) private var colorScheme

    private var tint: TintedColors {
        TintedColors(accent: CapabilityPresentation.color(for: identity), colorScheme: colorScheme)
    }

    var body: some View {
        if identity.modelPrimitiveName == "search", let details {
            CapabilitySearchResultSummary(details: details, tint: tint)
        } else if identity.modelPrimitiveName == "inspect", let details {
            CapabilityInspectionResultSummary(details: details, tint: tint)
        } else if let details, let pretty = Self.prettyJSON(details), !pretty.isEmpty {
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

@available(iOS 26.0, *)
private struct CapabilitySearchResultSummary: View {
    let details: [String: AnyCodable]
    let tint: TintedColors

    private var results: [[String: Any]] {
        details["results"]?.arrayValue?.compactMap { $0 as? [String: Any] } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let mode = details.anyCodableDict("searchMode"),
               let state = mode.string("state") {
                CapabilityInfoPill(
                    icon: state == "ready" ? "checkmark.circle" : "exclamationmark.triangle",
                    label: searchModeLabel(mode: mode),
                    color: state == "ready" ? .tronSuccess : .tronAmber
                )
            }

            if results.isEmpty {
                Text(emptyMessage)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(results.prefix(8).enumerated()), id: \.offset) { _, result in
                        CapabilitySearchResultRow(result: result, tint: tint)
                    }
                }
            }
        }
    }

    private var emptyMessage: String {
        if let query = details.string("query")?.nilIfEmpty {
            return "No capabilities matched “\(query)”."
        }
        return "No capabilities matched this search."
    }

    private func searchModeLabel(mode: [String: AnyCodable]) -> String {
        if let degraded = mode.string("degradedReason")?.nilIfEmpty {
            return "Degraded: \(degraded)"
        }
        if mode.bool("localVector") == true {
            return "Hybrid local search ready"
        }
        if mode.bool("lexical") == true {
            return "Lexical search"
        }
        return mode.string("state") ?? "Search status unknown"
    }
}

@available(iOS 26.0, *)
private struct CapabilitySearchResultRow: View {
    let result: [String: Any]
    let tint: TintedColors

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if let subtitle {
                Text(subtitle)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                    .foregroundStyle(tint.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                ForEach(badges, id: \.self) { badge in
                    Text(badge)
                        .font(TronTypography.badge)
                        .foregroundStyle(tint.heading)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(tint.accent.opacity(0.12)))
                }
            }
        }
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.tronTextMuted.opacity(0.18))
                .frame(height: 1)
        }
    }

    private var title: String {
        string(["contractId", "implementationId", "functionId", "id", "name"]) ?? "Capability"
    }

    private var subtitle: String? {
        string(["description", "reason", "pluginId"])
    }

    private var badges: [String] {
        ["kind", "health", "trustTier", "riskLevel"]
            .compactMap { key in string([key]) }
            .filter { !$0.isEmpty }
    }

    private func string(_ keys: [String]) -> String? {
        for key in keys {
            if let value = result[key] as? String, !value.isEmpty {
                return value
            }
            if let value = result[key] as? NSNumber {
                return value.stringValue
            }
        }
        return nil
    }
}

@available(iOS 26.0, *)
private struct CapabilityInspectionResultSummary: View {
    let details: [String: AnyCodable]
    let tint: TintedColors

    var body: some View {
        let contract = details.anyCodableDict("contract")
        let implementation = details.anyCodableDict("implementation")
        let requirements = details.anyCodableDict("executionRequirements")

        VStack(alignment: .leading, spacing: 12) {
            CapabilityReadableRows(
                rows: inspectionRows(contract: contract, implementation: implementation, requirements: requirements),
                tint: tint
            )

            if requirements?.bool("freshInspectionRequired") == true {
                CapabilityInfoPill(icon: "lock.shield", label: "Fresh inspection required", color: .tronAmber)
            }
        }
    }

    private func inspectionRows(
        contract: [String: AnyCodable]?,
        implementation: [String: AnyCodable]?,
        requirements: [String: AnyCodable]?
    ) -> [CapabilityDisplayRow] {
        var rows: [CapabilityDisplayRow] = []
        func append(_ label: String, _ value: String?, technical: Bool = false) {
            guard let value = value?.nilIfEmpty else { return }
            rows.append(CapabilityDisplayRow(label: label, value: value, isTechnical: technical))
        }
        append("Contract", contract?.string("contractId"), technical: true)
        append("Function", implementation?.string("functionId"), technical: true)
        append("Risk", contract?.string("riskLevel"))
        append("Effect", contract?.string("effectClass"))
        append("Expected revision", requirements?.uint64("expectedRevision").map(String.init), technical: true)
        append("Schema digest", requirements?.string("expectedSchemaDigest"), technical: true)
        append("Inspection handle", requirements?.string("inspectionHandle"), technical: true)
        return rows
    }
}

@available(iOS 26.0, *)
private struct CapabilityInvocationCodeBlock: View {
    let text: String

    var body: some View {
        Text(text)
            .font(TronTypography.code(size: TronTypography.sizeCaption, weight: .regular))
            .foregroundStyle(.tronTextSecondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.tronSurface.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
