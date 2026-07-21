import SwiftUI

struct CapabilityInvocationChip: View {
    let data: CapabilityInvocationData
    var onTap: (() -> Void)?
    var onCancel: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    private var display: CapabilityInvocationDisplayModel { data.display }
    private var evidence: CapabilityEvidencePresentation { CapabilityEvidencePresentation(data: data) }
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

                Text(evidence.chipText)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .bold))
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

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
        if data.status == .running || data.status == .generating {
            ProgressView()
                .controlSize(.small)
                .tint(textColor.opacity(0.72))
                .frame(width: 18, height: 18)
        } else {
            Image(systemName: data.status.iconName)
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(textColor)
                .frame(width: 18, height: 18)
        }
    }

    @ViewBuilder
    private var trailingAccessory: some View {
        Image(systemName: "chevron.right")
            .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
            .foregroundStyle(textColor.opacity(0.56))
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
            evidence.title,
            evidence.qualifier,
            evidence.statusLabel,
            evidence.duration
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }
}

struct CapabilityInvocationGroupChip: View {
    let data: CapabilityInvocationGroupData
    var onTap: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    private var accent: Color {
        switch data.displayStatus {
        case .error, .unavailable:
            return .tronError
        default:
            return .tronEmerald
        }
    }

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(spacing: 7) {
                leadingAccessory

                Text(data.title)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .bold))
                    .foregroundStyle(accent)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                if let status = data.inlineStatusText {
                    Text(status)
                        .font(TronTypography.code(size: TronTypography.sizeCaption, weight: .semibold))
                        .foregroundStyle(accent.opacity(0.68))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }

                Image(systemName: "chevron.right")
                    .font(TronTypography.sans(size: TronTypography.sizeSM, weight: .semibold))
                    .foregroundStyle(accent.opacity(0.56))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .chipStyle(accent, tintOpacity: colorScheme == .light ? 0.30 : 0.38)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(accessibilityLabel)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: data.displayStatus)
        .animation(.easeInOut(duration: 0.18), value: data.count)
        .animation(.easeInOut(duration: 0.18), value: data.runningCount)
        .animation(.easeInOut(duration: 0.18), value: data.failedCount)
    }

    @ViewBuilder
    private var leadingAccessory: some View {
        if data.isActive {
            ProgressView()
                .controlSize(.small)
                .tint(accent.opacity(0.72))
                .frame(width: 18, height: 18)
        } else {
            Image(systemName: data.displayStatus.iconName)
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 18, height: 18)
        }
    }

    private var accessibilityLabel: String {
        [
            data.title,
            data.inlineStatusText
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }
}

struct CapabilityInvocationGroupDetailSheet: View {
    let data: CapabilityInvocationGroupData

    @State private var selectedInvocation: CapabilityInvocationData?
    @Environment(\.colorScheme) private var colorScheme

    private var accent: Color {
        switch data.displayStatus {
        case .error, .unavailable:
            return .tronError
        default:
            return .tronSuccess
        }
    }

    private var tint: TintedColors {
        TintedColors(accent: accent, colorScheme: colorScheme)
    }

    private var failedInvocations: [CapabilityInvocationData] {
        data.invocations.filter { $0.status == .error || $0.status == .unavailable }
    }

    private var activeInvocations: [CapabilityInvocationData] {
        data.invocations.filter { $0.status == .running || $0.status == .generating }
    }

    private var completedInvocations: [CapabilityInvocationData] {
        data.invocations.filter { invocation in
            !(failedInvocations.contains(where: { $0.id == invocation.id }) ||
              activeInvocations.contains(where: { $0.id == invocation.id }))
        }
    }

    var body: some View {
        CapabilityDetailSheetContainer(
            modelPrimitiveName: "Capabilities",
            iconName: "square.stack.3d.up",
            accent: accent
        ) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 20) {
                    summarySection
                        .sheetSection()

                    if !failedInvocations.isEmpty {
                        invocationSection(
                            title: "Needs attention",
                            invocations: failedInvocations,
                            sectionAccent: .tronError
                        )
                        .sheetSection()
                    }

                    if !activeInvocations.isEmpty {
                        invocationSection(
                            title: "Still running",
                            invocations: activeInvocations,
                            sectionAccent: .tronBlue
                        )
                        .sheetSection()
                    }

                    if !completedInvocations.isEmpty {
                        invocationSection(
                            title: failedInvocations.isEmpty ? "Invocations" : "Completed",
                            invocations: completedInvocations,
                            sectionAccent: .tronSuccess
                        )
                        .sheetSection()
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
        }
        .sheet(item: $selectedInvocation) { invocation in
            CapabilityInvocationDetailSheet(data: invocation)
        }
    }

    private var summarySection: some View {
        CapabilityDetailSection(title: "What happened", accent: accent, tint: tint) {
            VStack(alignment: .leading, spacing: 14) {
                Text(groupNarrative)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.body)
                    .fixedSize(horizontal: false, vertical: true)

                CapabilityMetricStrip(
                    rows: [
                        CapabilityDisplayRow(label: "Used", value: "\(data.count)"),
                        CapabilityDisplayRow(label: "Finished", value: "\(data.completedCount)"),
                        CapabilityDisplayRow(label: "Failed", value: "\(data.failedCount)")
                    ],
                    tint: tint
                )
            }
        }
    }

    private var groupNarrative: String {
        if data.isActive {
            return "Tron is using \(data.count) capabilities in this batch. Completed calls will stay inspectable as the rest finish."
        }
        if data.failedCount > 0 {
            return "Tron used \(data.count) capabilities. \(data.failedCount) need attention and are listed first with safe failure details."
        }
        return "Tron used \(data.count) capabilities and all completed. Open any invocation for request, result, and evidence details."
    }

    private func invocationSection(
        title: String,
        invocations: [CapabilityInvocationData],
        sectionAccent: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(TintedColors(accent: sectionAccent, colorScheme: colorScheme).heading)
                Spacer()
                Text("\(invocations.count)")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .bold))
                    .countBadge(sectionAccent)
            }

            VStack(spacing: 0) {
                ForEach(invocations.indices, id: \.self) { index in
                    if index > 0 {
                        Divider()
                            .overlay(sectionAccent.opacity(colorScheme == .light ? 0.18 : 0.20))
                            .padding(.leading, 44)
                    }
                    invocationRow(invocations[index])
                }
            }
            .sectionFill(sectionAccent, cornerRadius: 12, subtle: true, interactive: false)
        }
    }

    private func invocationRow(_ invocation: CapabilityInvocationData) -> some View {
        let brief = CapabilityInvocationBriefPresentation(data: invocation)
        let rowAccent = CapabilityPresentation.statusColor(
            for: invocation.status,
            identity: invocation.identity,
            targetId: invocation.display.targetId
        )
        return Button {
            selectedInvocation = invocation
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: invocation.status.iconName)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(rowAccent)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 4) {
                    Text(brief.title)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .bold))
                        .foregroundStyle(.tronTextPrimary)
                        .lineLimit(1)

                    if let qualifier = brief.subtitle {
                        Text(qualifier)
                            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                            .foregroundStyle(.tronTextSecondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(invocation.formattedDuration ?? invocation.display.statusText)
                    .font(TronTypography.code(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(.tronTextSecondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(brief.title), \(invocation.display.statusText)")
    }
}

struct CapabilityInvocationDetailSheet: View {
    let data: CapabilityInvocationData

    @Environment(\.colorScheme) private var colorScheme

    private var display: CapabilityInvocationDisplayModel { data.display }
    private var evidence: CapabilityEvidencePresentation { CapabilityEvidencePresentation(data: data) }
    private var brief: CapabilityInvocationBriefPresentation {
        CapabilityInvocationBriefPresentation(data: data)
    }
    private var accent: Color {
        CapabilityPresentation.statusColor(
            for: data.status,
            identity: data.identity,
            targetId: display.targetId
        )
    }
    private var tint: TintedColors { TintedColors(accent: accent, colorScheme: colorScheme) }

    var body: some View {
        CapabilityDetailSheetContainer(
            modelPrimitiveName: evidence.title,
            iconName: CapabilityPresentation.symbol(for: data.identity, targetId: display.targetId),
            accent: accent
        ) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 20) {
                    whatHappenedSection
                        .sheetSection()

                    if let issue = brief.issue {
                        issueSection(issue)
                            .sheetSection()
                    }

                    if !brief.resultRows.isEmpty || brief.resultBody != nil {
                        resultSection
                            .sheetSection()
                    }

                    if !brief.requestRows.isEmpty {
                        rowsSection(title: "Request", rows: brief.requestRows, accent: accent)
                            .sheetSection()
                    }

                    evidenceSection
                        .sheetSection()
                }
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
        }
    }

    private var whatHappenedSection: some View {
        CapabilityDetailSection(title: "What happened", accent: accent, tint: tint) {
            VStack(alignment: .leading, spacing: 12) {
                Text(brief.narrative)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.body)
                    .fixedSize(horizontal: false, vertical: true)

                CapabilityMetricStrip(rows: brief.factRows, tint: tint)
            }
        }
    }

    private func issueSection(_ issue: CapabilityInvocationBriefPresentation.Issue) -> some View {
        let issueTint = TintedColors(accent: .tronError, colorScheme: colorScheme)
        return CapabilityDetailSection(title: "Needs attention", accent: .tronError, tint: issueTint) {
            VStack(alignment: .leading, spacing: 12) {
                Text(issue.message)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(issueTint.body)
                    .fixedSize(horizontal: false, vertical: true)

                if let nextStep = issue.nextStep {
                    Label(nextStep, systemImage: "arrow.triangle.2.circlepath")
                        .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .bold))
                        .foregroundStyle(issueTint.accent)
                        .labelStyle(.titleAndIcon)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !issue.rows.isEmpty {
                    CapabilityMetricStrip(rows: issue.rows, tint: issueTint)
                }
            }
        }
    }

    private func rowsSection(title: String, rows: [CapabilityDisplayRow], accent: Color) -> some View {
        let sectionTint = TintedColors(accent: accent, colorScheme: colorScheme)
        return CapabilityDetailSection(title: title, accent: accent, tint: sectionTint) {
            CapabilityInlineRows(rows: rows, tint: sectionTint)
        }
    }

    private var resultSection: some View {
        CapabilityDetailSection(title: "Result", accent: accent, tint: tint) {
            VStack(alignment: .leading, spacing: 12) {
                if !brief.resultRows.isEmpty {
                    CapabilityMetricStrip(rows: brief.resultRows, tint: tint)
                }
                if let body = brief.resultBody {
                    CapabilityInvocationCodeBlock(text: body)
                }
            }
        }
    }

    private var evidenceSection: some View {
        let evidenceTint = TintedColors(accent: .tronSlate, colorScheme: colorScheme)
        return CapabilityDetailSection(title: "Evidence", accent: .tronSlate, tint: evidenceTint) {
            VStack(alignment: .leading, spacing: 12) {
                if !brief.evidenceRows.isEmpty {
                    CapabilityInlineRows(rows: brief.evidenceRows, tint: evidenceTint)
                }

                if !brief.technicalRows.isEmpty {
                    CapabilityRowsDisclosure(title: "Technical refs", rows: brief.technicalRows, tint: evidenceTint)
                }

                if let rawPayload = brief.rawPayload {
                    CapabilityRawDisclosure(title: "Raw payload", text: rawPayload, tint: evidenceTint)
                }
            }
        }
    }
}

private struct CapabilityRowsDisclosure: View {
    let title: String
    let rows: [CapabilityDisplayRow]
    let tint: TintedColors

    var body: some View {
        DisclosureGroup {
            CapabilityInlineRows(rows: rows, tint: tint)
                .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                Text(title)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(tint.heading)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

private struct CapabilityMetricStrip: View {
    let rows: [CapabilityDisplayRow]
    let tint: TintedColors

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(rows.indices, id: \.self) { index in
                if index > 0 {
                    Divider()
                        .overlay(tint.accent.opacity(0.18))
                        .padding(.vertical, 2)
                }
                CapabilityMetricStripItem(row: rows[index], tint: tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }
}

private struct CapabilityMetricStripItem: View {
    let row: CapabilityDisplayRow
    let tint: TintedColors

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.label)
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(tint.subtle)
                .lineLimit(1)
            Text(row.value)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .bold))
                .foregroundStyle(.tronTextPrimary)
                .lineLimit(2)
                .truncationMode(.middle)
                .minimumScaleFactor(0.82)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 10)
        .padding(.leading, 10)
    }
}

private struct CapabilityInlineRows: View {
    let rows: [CapabilityDisplayRow]
    let tint: TintedColors

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { index in
                if index > 0 {
                    Divider()
                        .overlay(tint.accent.opacity(0.14))
                }
                CapabilityInlineRow(row: rows[index], tint: tint)
            }
        }
    }
}

private struct CapabilityInlineRow: View {
    let row: CapabilityDisplayRow
    let tint: TintedColors

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.label)
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(tint.subtle)
            Text(row.value)
                .font(row.isTechnical ? TronTypography.code(size: TronTypography.sizeCaption, weight: .regular) : TronTypography.sans(size: TronTypography.sizeBodySM, weight: .bold))
                .foregroundStyle(row.isTechnical ? tint.body : .tronTextPrimary)
                .lineLimit(row.isTechnical ? 3 : 4)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 9)
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
