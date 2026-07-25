import SwiftUI

struct ToolInvocationChip: View {
    let data: ToolInvocationData
    var onTap: (() -> Void)?
    var onCancel: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    private var display: ToolInvocationDisplayModel { data.display }
    private var evidence: ToolEvidencePresentation { ToolEvidencePresentation(data: data) }
    private var brief: ToolInvocationBriefPresentation { ToolInvocationBriefPresentation(data: data) }
    private var accent: Color {
        ToolPresentation.statusColor(
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
        } else if brief.isBackgroundHandoff {
            Image(systemName: "arrow.up.forward.circle.fill")
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(textColor)
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
        } else if brief.isBackgroundHandoff {
            inlineStatusText("background")
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

struct ToolInvocationGroupChip: View {
    let data: ToolInvocationGroupData
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

struct ToolInvocationGroupDetailSheet: View {
    let data: ToolInvocationGroupData

    @State private var selectedInvocation: ToolInvocationData?
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

    private var failedInvocations: [ToolInvocationData] {
        data.invocations.filter { $0.status == .error || $0.status == .unavailable }
    }

    private var activeInvocations: [ToolInvocationData] {
        data.invocations.filter { $0.status == .running || $0.status == .generating }
    }

    private var completedInvocations: [ToolInvocationData] {
        data.invocations.filter { invocation in
            !(failedInvocations.contains(where: { $0.id == invocation.id }) ||
              activeInvocations.contains(where: { $0.id == invocation.id }))
        }
    }

    var body: some View {
        ToolDetailSheetContainer(
            toolName: "Tools",
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
            ToolInvocationDetailSheet(data: invocation)
        }
    }

    private var summarySection: some View {
        ToolDetailSection(title: data.isActive ? "Current state" : "Outcome", accent: accent, tint: tint) {
            VStack(alignment: .leading, spacing: 14) {
                Text(groupNarrative)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.body)
                    .fixedSize(horizontal: false, vertical: true)

                ToolMetricStrip(
                    rows: [
                        ToolDisplayRow(label: "Used", value: "\(data.count)"),
                        ToolDisplayRow(label: "Finished", value: "\(data.completedCount)"),
                        ToolDisplayRow(label: "Failed", value: "\(data.failedCount)")
                    ],
                    tint: tint
                )
            }
        }
    }

    private var groupNarrative: String {
        if data.isActive {
            return "Tron is using \(data.count) tools in this batch. Completed calls will stay inspectable as the rest finish."
        }
        if data.failedCount > 0 {
            return "Tron used \(data.count) tools. \(data.failedCount) need attention and are listed first with safe failure details."
        }
        return "Tron used \(data.count) tools and all completed. Open any invocation for request, result, and evidence details."
    }

    private func invocationSection(
        title: String,
        invocations: [ToolInvocationData],
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

    private func invocationRow(_ invocation: ToolInvocationData) -> some View {
        let brief = ToolInvocationBriefPresentation(data: invocation)
        let rowAccent = ToolPresentation.statusColor(
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

struct ToolInvocationDetailSheet: View {
    let data: ToolInvocationData

    @Environment(\.colorScheme) private var colorScheme
    @State private var showTechnicalDetails = false

    private var display: ToolInvocationDisplayModel { data.display }
    private var evidence: ToolEvidencePresentation { ToolEvidencePresentation(data: data) }
    private var brief: ToolInvocationBriefPresentation {
        ToolInvocationBriefPresentation(data: data)
    }
    private var surface: ToolInvocationSurface {
        ToolInvocationSurface(identity: data.identity)
    }
    private var structuredRequest: ToolStructuredDocument? {
        ToolStructuredDocument.request(from: data)
    }
    private var structuredResult: ToolStructuredDocument? {
        ToolStructuredDocument.result(from: data)
    }
    private var isActive: Bool {
        data.status == .generating || data.status == .running
    }
    private var showsLiveActivity: Bool {
        !surface.isWorker && isActive
    }
    private var accent: Color {
        ToolPresentation.statusColor(
            for: data.status,
            identity: data.identity,
            targetId: display.targetId
        )
    }
    private var tint: TintedColors { TintedColors(accent: accent, colorScheme: colorScheme) }
    private var hasTechnicalDetails: Bool {
        !brief.evidenceRows.isEmpty
            || !brief.technicalRows.isEmpty
            || brief.rawRequest != nil
            || brief.rawResult != nil
    }

    var body: some View {
        ToolDetailSheetContainer(
            toolName: evidence.title,
            iconName: ToolPresentation.symbol(for: data.identity, targetId: display.targetId),
            accent: accent
        ) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 20) {
                    if surface.isWorker {
                        WorkerToolRunGraphView(
                            invocationId: brief.backgroundInvocationId,
                            modelToolInvocationId: data.id
                        )
                        .sheetSection()
                    } else if showsLiveActivity {
                        progressSection
                            .sheetSection()
                    }

                    if !surface.isWorker {
                        whatHappenedSection
                            .sheetSection()
                    }

                    if let issue = brief.issue {
                        issueSection(issue)
                            .sheetSection()
                    }

                    if !surface.isWorker,
                       !brief.resultRows.isEmpty || brief.resultBody != nil || structuredResult != nil {
                        resultSection
                            .sheetSection()
                    }

                    if !surface.isWorker,
                       !brief.requestRows.isEmpty || structuredRequest != nil {
                        requestSection
                            .sheetSection()
                    }

                    if !data.artifacts.isEmpty {
                        artifactsSection
                            .sheetSection()
                    }

                    if hasTechnicalDetails {
                        technicalDetailsSection
                            .sheetSection()
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
        }
        .sheet(isPresented: $showTechnicalDetails) {
            ToolTechnicalDetailsSheet(
                title: evidence.title,
                evidenceRows: brief.evidenceRows,
                technicalRows: brief.technicalRows,
                rawRequest: brief.rawRequest,
                rawResult: brief.rawResult,
                accent: .tronSlate
            )
        }
    }

    private var progressSection: some View {
        ToolDetailSection(title: "Live activity", accent: accent, tint: tint) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(currentProgressMessage)
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .bold))
                            .foregroundStyle(.tronTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(progressSupportText)
                            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                            .foregroundStyle(tint.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    TimelineView(.periodic(from: data.startedAt ?? data.generatedAt ?? Date(), by: 0.25)) { context in
                        Text(data.formattedElapsed(at: context.date) ?? "Running")
                            .font(TronTypography.code(size: TronTypography.sizeCaption, weight: .semibold))
                            .foregroundStyle(tint.accent)
                            .monospacedDigit()
                    }
                }

                if let progressFraction {
                    ProgressView(value: progressFraction)
                        .tint(tint.accent)
                        .accessibilityLabel("Worker progress")
                        .accessibilityValue("\(Int((progressFraction * 100).rounded())) percent")
                } else {
                    ProgressView()
                        .tint(tint.accent)
                        .controlSize(.small)
                }

                ToolProgressJourneyView(
                    steps: display.progressSteps,
                    activity: data.logs,
                    isActive: isActive || brief.isBackgroundHandoff,
                    tint: tint
                )
            }
        }
    }

    private var currentProgressMessage: String {
        data.progressMessage?.nilIfEmpty
            ?? (brief.isBackgroundHandoff ? "Continuing in the background" : nil)
            ?? (surface.isAgentWorker ? "Agent worker is running" : "\(brief.title) is running")
    }

    private var progressSupportText: String {
        if brief.isBackgroundHandoff {
            return "The foreground turn has been released. Session Context owns current status, nested work, cancellation, and the eventual result."
        }
        if surface.isAgentWorker {
            return "Current steps and streamed output update here as the child agent reports them."
        }
        if surface.isWorker {
            return "Durable worker status and output update here from the canonical invocation stream."
        }
        return "Execution status updates here from the canonical tool lifecycle."
    }

    private var progressFraction: Double? {
        guard let percent = data.progressPercent, percent.isFinite else { return nil }
        let fraction = percent > 1 ? percent / 100 : percent
        return min(max(fraction, 0), 1)
    }

    private var whatHappenedSection: some View {
        ToolDetailSection(
            title: showsLiveActivity ? "Current state" : "Outcome",
            accent: accent,
            tint: tint
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text(brief.narrative)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                    .foregroundStyle(tint.body)
                    .fixedSize(horizontal: false, vertical: true)

                ToolMetricStrip(rows: brief.factRows, tint: tint)
            }
        }
    }

    private func issueSection(_ issue: ToolInvocationBriefPresentation.Issue) -> some View {
        let issueTint = TintedColors(accent: .tronError, colorScheme: colorScheme)
        return ToolDetailSection(title: "Needs attention", accent: .tronError, tint: issueTint) {
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
                    ToolMetricStrip(rows: issue.rows, tint: issueTint)
                }
            }
        }
    }

    private var resultSection: some View {
        ToolDetailSection(title: surface.resultTitle, accent: accent, tint: tint) {
            VStack(alignment: .leading, spacing: 12) {
                if !brief.resultRows.isEmpty {
                    ToolMetricStrip(rows: brief.resultRows, tint: tint)
                }
                if let structuredResult {
                    ToolStructuredDocumentView(document: structuredResult, tint: tint)
                } else if let body = brief.resultBody {
                    ToolReadableResultText(text: body, tint: tint)
                }
            }
        }
    }

    private var requestSection: some View {
        ToolDetailSection(title: "Request", accent: accent, tint: tint) {
            if surface.isWorker, let structuredRequest {
                ToolStructuredDocumentView(document: structuredRequest, tint: tint)
            } else if !brief.requestRows.isEmpty {
                ToolInlineRows(rows: brief.requestRows, tint: tint)
            } else if let structuredRequest {
                ToolStructuredDocumentView(document: structuredRequest, tint: tint)
            }
        }
    }

    private var artifactsSection: some View {
        ToolDetailSection(title: "Artifacts", accent: .tronPurple, tint: tint) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(data.artifacts, id: \.id) { artifact in
                    ToolArtifactRow(artifact: artifact)
                }
            }
        }
    }

    private var technicalDetailsSection: some View {
        let evidenceTint = TintedColors(accent: .tronSlate, colorScheme: colorScheme)
        return ToolDetailSection(title: "Technical details", accent: .tronSlate, tint: evidenceTint) {
            Button {
                showTechnicalDetails = true
            } label: {
                HStack(alignment: .center, spacing: 11) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .foregroundStyle(evidenceTint.accent)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Open technical details")
                            .font(TronTypography.sans(
                                size: TronTypography.sizeBodySM,
                                weight: .semibold
                            ))
                            .foregroundStyle(.tronTextPrimary)
                        Text("Identifiers, protocol references, and raw request or result payloads.")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

private struct ToolTechnicalDetailsSheet: View {
    let title: String
    let evidenceRows: [ToolDisplayRow]
    let technicalRows: [ToolDisplayRow]
    let rawRequest: String?
    let rawResult: String?
    let accent: Color

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !evidenceRows.isEmpty {
                        ToolDetailSection(
                            title: "Run identifiers",
                            accent: accent,
                            tint: tint
                        ) {
                            ToolInlineRows(rows: evidenceRows, tint: tint)
                        }
                        .sheetSection()
                    }

                    if !technicalRows.isEmpty {
                        ToolDetailSection(
                            title: "Protocol references",
                            accent: accent,
                            tint: tint
                        ) {
                            ToolInlineRows(rows: technicalRows, tint: tint)
                        }
                        .sheetSection()
                    }

                    if rawRequest != nil || rawResult != nil {
                        ToolDetailSection(
                            title: "Raw protocol",
                            accent: accent,
                            tint: tint
                        ) {
                            VStack(alignment: .leading, spacing: 8) {
                                if let rawRequest {
                                    ToolRawDetailLink(
                                        title: "Raw request",
                                        text: rawRequest,
                                        tint: tint
                                    )
                                }
                                if let rawResult {
                                    ToolRawDetailLink(
                                        title: "Raw result",
                                        text: rawResult,
                                        tint: tint
                                    )
                                }
                            }
                        }
                        .sheetSection()
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
            .scrollContentBackground(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: "\(title) Details", color: accent)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SheetDismissButton(color: accent)
                }
            }
        }
        .adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)
        .tint(accent)
    }

    @Environment(\.colorScheme) private var colorScheme
    private var tint: TintedColors {
        TintedColors(accent: accent, colorScheme: colorScheme)
    }
}

private struct ToolMetricStrip: View {
    let rows: [ToolDisplayRow]
    let tint: TintedColors

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(rows.indices, id: \.self) { index in
                if index > 0 {
                    Divider()
                        .overlay(tint.accent.opacity(0.18))
                        .padding(.vertical, 2)
                }
                ToolMetricStripItem(row: rows[index], tint: tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }
}

private struct ToolMetricStripItem: View {
    let row: ToolDisplayRow
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

private struct ToolInlineRows: View {
    let rows: [ToolDisplayRow]
    let tint: TintedColors

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { index in
                if index > 0 {
                    Divider()
                        .overlay(tint.accent.opacity(0.14))
                }
                ToolInlineRow(row: rows[index], tint: tint)
            }
        }
    }
}

private struct ToolInlineRow: View {
    let row: ToolDisplayRow
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

struct ToolInvocationResultView: View {
    let result: ToolInvocationResultData

    var body: some View {
        ToolResultRenderer(
            content: result.content,
            details: result.details,
            identity: result.identity
        )
    }
}
