import SwiftUI

@available(iOS 26.0, *)
struct CapabilityInvocationChip: View {
    let data: CapabilityInvocationData
    var onTap: (() -> Void)?
    var onCancel: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    private var display: CapabilityInvocationDisplayModel { data.display }
    private var accent: Color {
        CapabilityPresentation.statusColor(
            for: data.status,
            identity: data.identity,
            targetId: display.targetId
        )
    }

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(spacing: 7) {
                leadingAccessory

                Text(display.chipTitle)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .bold))
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(2)

                if !display.commandText.isEmpty {
                    Text(display.commandText)
                        .font(TronTypography.code(size: TronTypography.sizeCaption - 1, weight: .regular))
                        .foregroundStyle(textColor.opacity(0.68))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(0)
                }

                inlineStatusView

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
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(accessibilityLabel)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: data.status)
        .animation(.easeInOut(duration: 0.18), value: data.formattedDuration)
    }

    @ViewBuilder
    private var leadingAccessory: some View {
        Image(systemName: CapabilityPresentation.symbol(for: data.identity, targetId: display.targetId))
            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
            .foregroundStyle(textColor)
            .frame(width: 18, height: 18)
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

    @ViewBuilder
    private var inlineStatusView: some View {
        if data.status == .running || data.status == .generating {
            TimelineView(.periodic(from: data.startedAt ?? data.generatedAt ?? Date(), by: 0.25)) { context in
                if let elapsed = data.formattedElapsed(at: context.date) {
                    inlineStatusText(elapsed)
                }
            }
        } else if let duration = data.formattedDuration {
            inlineStatusText(duration)
        } else if let status = terminalStatusText {
            inlineStatusText(status)
        }
    }

    private func inlineStatusText(_ text: String) -> some View {
        Text(text)
            .font(TronTypography.code(size: TronTypography.sizeCaption, weight: .semibold))
            .foregroundStyle(textColor.opacity(0.68))
            .lineLimit(1)
            .monospacedDigit()
            .frame(minWidth: 38, alignment: .trailing)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var terminalStatusText: String? {
        switch data.status {
        case .error:
            return "failed"
        case .unavailable:
            return "unavailable"
        case .approvalRequired:
            return "approval"
        case .paused:
            return "paused"
        case .generating, .running, .success:
            return nil
        }
    }

    private var chipTint: Color {
        accent
    }

    private var textColor: Color {
        accent
    }

    private var accessibilityLabel: String {
        [
            display.primitiveTitle,
            display.chipTitle,
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
    private var accent: Color {
        CapabilityPresentation.statusColor(
            for: data.status,
            identity: data.identity,
            targetId: display.targetId
        )
    }
    private var tint: TintedColors { TintedColors(accent: accent, colorScheme: colorScheme) }
    private var primitive: String { CapabilityPresentation.primitiveName(for: data.identity) }

    var body: some View {
        CapabilityDetailSheetContainer(
            modelPrimitiveName: display.sheetTitle,
            iconName: CapabilityPresentation.symbol(for: data.identity, targetId: display.targetId),
            accent: accent
        ) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 20) {
                    CapabilityDetailHeader(data: data)
                        .sheetSection()

                    progressSection
                    requestSection
                    executionSection
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
            CapabilityDetailSection(title: "Request", accent: accent, tint: tint) {
                VStack(alignment: .leading, spacing: 12) {
                    CapabilityReadableRows(rows: display.requestRows, tint: tint)
                }
            }
            .sheetSection()
        }
    }

    @ViewBuilder
    private var executionSection: some View {
        if !display.executionGroups.isEmpty {
            CapabilityDetailSection(title: "Execution Path", accent: accent, tint: tint) {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(display.executionGroups) { group in
                        CapabilityExecutionGroupView(group: group, tint: tint)
                    }
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
        if display.resultPreview?.nilIfEmpty != nil || data.result?.nilIfEmpty != nil || !display.resultRows.isEmpty {
            CapabilityDetailSection(title: data.status == .error ? "Failure" : "Result", accent: accent, tint: tint) {
                VStack(alignment: .leading, spacing: 12) {
                    if primitive == "execute" {
                        if !display.resultRows.isEmpty {
                            CapabilityReadableRows(rows: display.resultRows, tint: tint)
                        }
                        if let preview = display.resultPreview?.nilIfEmpty {
                            CapabilityInvocationCodeBlock(text: preview)
                        } else if data.result?.nilIfEmpty != nil {
                            CapabilityResultNote(
                                text: "Structured output is available in Metadata.",
                                tint: tint
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
            CapabilityDetailSection(title: "Metadata", accent: .tronSlate, tint: tint) {
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
                    Text("Audit metadata and raw payloads")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                        .foregroundStyle(tint.heading)
                }
            }
            .sheetSection()
        }
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
