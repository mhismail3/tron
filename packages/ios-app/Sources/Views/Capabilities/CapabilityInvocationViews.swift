import SwiftUI

@available(iOS 26.0, *)
struct CapabilityInvocationChip: View {
    let data: CapabilityInvocationData
    var onTap: (() -> Void)?
    var onCancel: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    private var display: CapabilityInvocationDisplayModel { data.display }

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(spacing: 7) {
                leadingAccessory

                Text(titleString(size: TronTypography.sizeBodySM))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)

                if let inlineStatusText {
                    Text(inlineStatusText)
                        .font(TronTypography.code(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(textColor.opacity(0.68))
                        .lineLimit(1)
                }

                trailingAccessory
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .chipStyle(chipTint, tintOpacity: colorScheme == .light ? 0.30 : 0.38)
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
        .accessibilityLabel(accessibilityLabel)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: data.status)
        .animation(.easeInOut(duration: 0.18), value: inlineStatusText)
    }

    private func titleString(size: CGFloat) -> AttributedString {
        var title = AttributedString(display.primitiveTitle)
        title.font = TronTypography.sans(size: size, weight: .bold)
        title.foregroundColor = textColor

        let detail = display.commandText.nilIfEmpty.map { " \($0)" } ?? ""
        var detailText = AttributedString(detail)
        detailText.font = TronTypography.code(size: size, weight: .regular)
        detailText.foregroundColor = textColor.opacity(0.70)
        return title + detailText
    }

    @ViewBuilder
    private var leadingAccessory: some View {
        Image(systemName: CapabilityPresentation.symbol(for: data.identity))
            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
            .foregroundStyle(textColor)
    }

    @ViewBuilder
    private var trailingAccessory: some View {
        if data.status == .running || data.status == .generating {
            ProgressView()
                .controlSize(.small)
                .tint(textColor.opacity(0.72))
        } else {
            Image(systemName: "chevron.right")
                .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                .foregroundStyle(textColor.opacity(0.56))
        }
    }

    private var inlineStatusText: String? {
        if let duration = data.formattedDuration {
            return duration
        }
        switch data.status {
        case .error:
            return "failed"
        case .unavailable:
            return "unavailable"
        case .approvalRequired:
            return "approval"
        case .generating, .running, .success:
            return nil
        }
    }

    private var chipTint: Color {
        CapabilityPresentation.statusColor(for: data.status, identity: data.identity)
    }

    private var textColor: Color {
        CapabilityPresentation.statusColor(for: data.status, identity: data.identity)
    }

    private var accessibilityLabel: String {
        [
            display.primitiveTitle,
            display.commandText.nilIfEmpty,
            display.statusWithDuration
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }
}

@available(iOS 26.0, *)
struct CapabilityInvocationDetailSheet: View {
    let data: CapabilityInvocationData

    @Environment(\.colorScheme) private var colorScheme

    private var display: CapabilityInvocationDisplayModel { data.display }
    private var accent: Color { CapabilityPresentation.statusColor(for: data.status, identity: data.identity) }
    private var sourceAccent: Color { CapabilityPresentation.sourceColor(for: data.identity) }
    private var tint: TintedColors { TintedColors(accent: accent, colorScheme: colorScheme) }
    private var sourceTint: TintedColors { TintedColors(accent: sourceAccent, colorScheme: colorScheme) }
    private var primitive: String { CapabilityPresentation.primitiveName(for: data.identity) }

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

                    progressSection
                    requestSection
                    approvalSection
                    resultSection
                    artifactsSection
                    logsSection
                    errorSection
                    technicalSection
                }
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
        }
    }

    @ViewBuilder
    private var progressSection: some View {
        if shouldShowProgressSection {
            CapabilityDetailSection(title: "Status", accent: accent, tint: tint) {
                VStack(alignment: .leading, spacing: 12) {
                    CapabilityReadableRows(rows: statusRows, tint: tint)

                    if data.status == .running || data.status == .generating || data.progressPercent != nil {
                        if let progress = boundedProgress {
                            ProgressView(value: progress)
                                .tint(accent)
                            Text("\(Int((progress * 100).rounded()))%")
                                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                                .foregroundStyle(tint.secondary)
                        } else {
                            ProgressView()
                                .tint(accent)
                        }
                    }
                }
            }
            .sheetSection()
        }
    }

    @ViewBuilder
    private var requestSection: some View {
        if !display.requestRows.isEmpty {
            CapabilityDetailSection(title: "Request", accent: sourceAccent, tint: sourceTint) {
                VStack(alignment: .leading, spacing: 12) {
                    CapabilityReadableRows(rows: display.requestRows, tint: sourceTint)
                }
            }
            .sheetSection()
        }
    }

    @ViewBuilder
    private var approvalSection: some View {
        if let approvalState = data.approvalState, !approvalState.isEmpty {
            CapabilityDetailSection(title: "Approval", accent: .tronAmber, tint: TintedColors(accent: .tronAmber, colorScheme: colorScheme)) {
                CapabilityInvocationCodeBlock(text: prettyJSON(approvalState))
            }
            .sheetSection()
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        if data.result?.nilIfEmpty != nil || !display.resultRows.isEmpty {
            CapabilityDetailSection(title: data.status == .error ? "Failure" : "Result", accent: resultAccent, tint: resultTint) {
                VStack(alignment: .leading, spacing: 12) {
                    if primitive == "execute" {
                        if !display.resultRows.isEmpty {
                            CapabilityReadableRows(rows: display.resultRows, tint: resultTint)
                        }
                        if let preview = display.resultPreview?.nilIfEmpty {
                            CapabilityInvocationCodeBlock(text: preview)
                        } else if data.result?.nilIfEmpty != nil {
                            CapabilityResultNote(
                                text: "Structured output is available in Technical.",
                                tint: resultTint
                            )
                        }
                    } else if let result = data.result, !result.isEmpty {
                        CapabilityResultRenderer(
                            content: result,
                            details: data.details,
                            identity: data.identity
                        )
                    }
                }
            }
            .sheetSection()
        }
    }

    @ViewBuilder
    private var artifactsSection: some View {
        if !data.artifacts.isEmpty {
            CapabilityDetailSection(title: "Artifacts", accent: .tronPurple, tint: TintedColors(accent: .tronPurple, colorScheme: colorScheme)) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(data.artifacts, id: \.id) { artifact in
                        CapabilityArtifactRow(artifact: artifact)
                    }
                }
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
    private var errorSection: some View {
        if let errorClassification = data.errorClassification {
            CapabilityDetailSection(title: "Error", accent: .tronError, tint: TintedColors(accent: .tronError, colorScheme: colorScheme)) {
                CapabilityReadableRows(rows: errorRows(errorClassification), tint: TintedColors(accent: .tronError, colorScheme: colorScheme))
            }
            .sheetSection()
        }
    }

    @ViewBuilder
    private var technicalSection: some View {
        if !display.technicalRows.isEmpty || display.prettyArguments != nil || display.prettyResult != nil {
            CapabilityDetailSection(title: "Technical", accent: .tronSlate, tint: tint) {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 14) {
                        if !display.technicalRows.isEmpty {
                            CapabilityReadableRows(rows: display.technicalRows, tint: tint)
                        }
                        if let prettyArguments = display.prettyArguments {
                            CapabilityRawDisclosure(title: "Raw request", text: prettyArguments, tint: tint)
                        }
                        if let prettyResult = display.prettyResult {
                            CapabilityRawDisclosure(title: "Raw result", text: prettyResult, tint: tint)
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Text("Metadata and raw payloads")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                        .foregroundStyle(tint.heading)
                }
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

    private var shouldShowProgressSection: Bool {
        data.status == .running
            || data.status == .generating
            || data.progressMessage?.nilIfEmpty != nil
            || data.progressPercent != nil
    }

    private var boundedProgress: Double? {
        guard let progress = data.progressPercent else { return nil }
        return min(max(progress, 0), 1)
    }

    private var statusRows: [CapabilityDisplayRow] {
        var rows = [CapabilityDisplayRow(label: "State", value: display.statusText)]
        if let progressMessage = data.progressMessage?.nilIfEmpty {
            rows.append(CapabilityDisplayRow(label: "Update", value: progressMessage))
        }
        if let duration = data.formattedDuration {
            rows.append(CapabilityDisplayRow(label: "Duration", value: duration))
        }
        return rows
    }

    private func errorRows(_ error: CapabilityErrorClassification) -> [CapabilityDisplayRow] {
        var rows: [CapabilityDisplayRow] = []
        func append(_ label: String, _ value: String?, technical: Bool = false) {
            guard let value = value?.nilIfEmpty else { return }
            rows.append(CapabilityDisplayRow(label: label, value: value, isTechnical: technical))
        }
        append("Message", error.message)
        append("Code", error.code, technical: true)
        append("Category", error.category)
        if let recoverable = error.recoverable {
            rows.append(CapabilityDisplayRow(label: "Recoverable", value: recoverable ? "Yes" : "No"))
        }
        return rows
    }

    private func prettyJSON(_ value: [String: AnyCodable]) -> String {
        let raw = value.mapValues(\.value)
        guard JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]),
              let pretty = String(data: data, encoding: .utf8)
        else { return "{}" }
        return pretty
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
    private var accent: Color { CapabilityPresentation.statusColor(for: data.status, identity: data.identity) }
    private var sourceAccent: Color { CapabilityPresentation.sourceColor(for: data.identity) }
    private var tint: TintedColors { TintedColors(accent: accent, colorScheme: colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                CapabilitySourceBadge(label: CapabilityPresentation.sourceLabel(for: data.identity), color: sourceAccent)
                Spacer(minLength: 8)
                CapabilityStatusBadge(status: data.status)
            }

            CapabilityReadableRows(rows: display.capabilityRows, tint: tint)
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
}

@available(iOS 26.0, *)
private struct CapabilitySourceBadge: View {
    let label: String
    let color: Color

    var body: some View {
        Text(label)
            .font(TronTypography.badge)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background {
                Capsule()
                    .fill(color.opacity(0.14))
            }
    }
}

@available(iOS 26.0, *)
private struct CapabilityArtifactRow: View {
    let artifact: CapabilityArtifactData

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: artifactIcon)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(.tronPurple)

                Text(artifact.label?.nilIfEmpty ?? artifact.id)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(.tronTextPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let mimeType = artifact.mimeType?.nilIfEmpty {
                Text(mimeType)
                    .font(TronTypography.code(size: TronTypography.sizeCaption, weight: .regular))
                    .foregroundStyle(.tronTextSecondary)
            }

            if let url = artifact.url?.nilIfEmpty {
                Text(url)
                    .font(TronTypography.code(size: TronTypography.sizeCaption, weight: .regular))
                    .foregroundStyle(.tronTextMuted)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .truncationMode(.middle)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.tronSurface.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var artifactIcon: String {
        if artifact.mimeType?.hasPrefix("image/") == true { return "photo" }
        if artifact.mimeType?.contains("json") == true { return "curlybraces" }
        if artifact.mimeType?.contains("text") == true { return "doc.text" }
        return "paperclip"
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
        TintedColors(accent: CapabilityPresentation.primitiveColor(for: identity), colorScheme: colorScheme)
    }

    var body: some View {
        let primitive = CapabilityPresentation.primitiveName(for: identity)
        if primitive == "search", let details {
            CapabilitySearchResultSummary(details: details, tint: tint)
        } else if primitive == "inspect", let details {
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
            CapabilityReadableRows(rows: summaryRows, tint: tint)

            if let mode = details.anyCodableDict("searchMode"),
               let state = mode.string("state") {
                CapabilityInfoPill(
                    icon: state == "ready" ? "checkmark.circle" : "exclamationmark.triangle",
                    label: searchModeLabel(mode: mode),
                    color: state == "ready" ? .tronSuccess : .tronAmber
                )
            }

            if let nextCursor = details.string("nextCursor")?.nilIfEmpty {
                CapabilityInfoPill(icon: "arrow.forward.circle", label: "More results available: \(nextCursor)", color: .tronInfo)
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

    private var summaryRows: [CapabilityDisplayRow] {
        var rows: [CapabilityDisplayRow] = []
        func append(_ label: String, _ value: String?, technical: Bool = false) {
            guard let value = value?.nilIfEmpty else { return }
            rows.append(CapabilityDisplayRow(label: label, value: value, isTechnical: technical))
        }

        append("Query", details.string("query"))
        append("Results", String(results.count))
        append("Catalog", details.uint64("catalogRevision").map(String.init), technical: true)

        if let mode = details.anyCodableDict("searchMode") {
            append("Index", mode.string("state"))
            append("Vector", mode.bool("localVector").map { $0 ? "Ready" : "Unavailable" })
            append("Lexical", mode.bool("lexical").map { $0 ? "Enabled" : "Disabled" })
            append("Embedding", mode.string("embeddingModel"), technical: true)
            append("Vector store", mode.string("vectorStore"), technical: true)
        }

        return rows
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
                    CapabilitySourceBadge(label: badge, color: tint.accent)
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
        let binding = details.anyCodableDict("bindingDecision")
        let provenance = details.anyCodableDict("pluginProvenance") ?? details.anyCodableDict("provenance")

        VStack(alignment: .leading, spacing: 14) {
            CapabilityReadableRows(
                rows: inspectionRows(
                    contract: contract,
                    implementation: implementation,
                    requirements: requirements,
                    binding: binding,
                    provenance: provenance
                ),
                tint: tint
            )

            if requirements?.bool("freshInspectionRequired") == true {
                CapabilityInfoPill(icon: "lock.shield", label: "Fresh inspection required", color: .tronAmber)
            }

            if let approval = approvalRequirement(requirements: requirements, contract: contract) {
                CapabilityInfoPill(icon: "checkmark.shield", label: approval, color: .tronAmber)
            }

            if let examples = contract?.array("examples"), !examples.isEmpty {
                CapabilityRawDisclosure(title: "Examples", text: prettyJSONArray(examples), tint: tint)
            }
        }
    }

    private func inspectionRows(
        contract: [String: AnyCodable]?,
        implementation: [String: AnyCodable]?,
        requirements: [String: AnyCodable]?,
        binding: [String: AnyCodable]?,
        provenance: [String: AnyCodable]?
    ) -> [CapabilityDisplayRow] {
        var rows: [CapabilityDisplayRow] = []
        func append(_ label: String, _ value: String?, technical: Bool = false) {
            guard let value = value?.nilIfEmpty else { return }
            rows.append(CapabilityDisplayRow(label: label, value: value, isTechnical: technical))
        }
        append("Contract", contract?.string("contractId"), technical: true)
        append("Display", contract?.string("displayName"))
        append("Description", contract?.string("description"))
        append("Implementation", implementation?.string("implementationId"), technical: true)
        append("Function", implementation?.string("functionId"), technical: true)
        append("Plugin", implementation?.string("pluginId") ?? provenance?.string("pluginId"), technical: true)
        append("Worker", implementation?.string("workerId"), technical: true)
        append("Trust", implementation?.string("trustTier"))
        append("Health", implementation?.string("health"))
        append("Risk", contract?.string("riskLevel"))
        append("Effect", contract?.string("effectClass"))
        append("Binding", binding?.string("bindingDecisionId") ?? binding?.string("id"), technical: true)
        append("Selection", binding?.string("selectionPolicy") ?? binding?.string("policy"))
        append("Expected revision", requirements?.uint64("expectedRevision").map(String.init), technical: true)
        append("Schema digest", requirements?.string("expectedSchemaDigest"), technical: true)
        append("Inspection handle", requirements?.string("inspectionHandle"), technical: true)
        return rows
    }

    private func approvalRequirement(
        requirements: [String: AnyCodable]?,
        contract: [String: AnyCodable]?
    ) -> String? {
        if requirements?.bool("approvalRequired") == true {
            return "Approval required before execution"
        }
        if let approval = contract?.anyCodableDict("approvalContract"),
           approval.bool("required") == true {
            return "Approval required by contract"
        }
        return nil
    }

    private func prettyJSONArray(_ value: [Any]) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let pretty = String(data: data, encoding: .utf8)
        else { return "[]" }
        return pretty
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
