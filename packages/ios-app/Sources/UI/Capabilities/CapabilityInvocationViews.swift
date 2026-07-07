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
            return .tronSuccess
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

                    CapabilityDetailSection(title: "Invocations", accent: accent, tint: tint) {
                        VStack(spacing: 10) {
                            ForEach(data.invocations) { invocation in
                                invocationRow(invocation)
                            }
                        }
                    }
                    .sheetSection()
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
        CapabilityDetailSection(title: "Summary", accent: accent, tint: tint) {
            CapabilityReadableRows(
                rows: [
                    CapabilityDisplayRow(label: "Status", value: data.isActive ? "Running" : "Completed"),
                    CapabilityDisplayRow(label: "Capabilities", value: "\(data.count)"),
                    CapabilityDisplayRow(label: "Finished", value: "\(data.completedCount)"),
                    CapabilityDisplayRow(label: "Failed", value: "\(data.failedCount)")
                ],
                tint: tint
            )
        }
    }

    private func invocationRow(_ invocation: CapabilityInvocationData) -> some View {
        let evidence = CapabilityEvidencePresentation(data: invocation)
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
                    Text(evidence.title)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .bold))
                        .foregroundStyle(.tronTextPrimary)
                        .lineLimit(1)

                    if let qualifier = evidence.qualifier {
                        Text(qualifier)
                            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                            .foregroundStyle(.tronTextSecondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(invocation.formattedDuration ?? evidence.statusLabel)
                    .font(TronTypography.code(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(.tronTextSecondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(Color.tronSurface.opacity(colorScheme == .light ? 0.78 : 0.58))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityLabel("\(evidence.title), \(evidence.statusLabel)")
    }
}

struct CapabilityInvocationDetailSheet: View {
    let data: CapabilityInvocationData

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
    private var tint: TintedColors { TintedColors(accent: accent, colorScheme: colorScheme) }

    var body: some View {
        CapabilityDetailSheetContainer(
            modelPrimitiveName: evidence.title,
            iconName: CapabilityPresentation.symbol(for: data.identity, targetId: display.targetId),
            accent: accent
        ) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(evidence.sections) { section in
                        evidenceSection(section)
                            .sheetSection()
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
        }
    }

    @ViewBuilder
    private func evidenceSection(_ section: CapabilityEvidencePresentation.Section) -> some View {
        let sectionTint = TintedColors(accent: sectionAccent(section.kind), colorScheme: colorScheme)
        CapabilityDetailSection(title: section.title, accent: sectionTint.accent, tint: sectionTint) {
            VStack(alignment: .leading, spacing: 12) {
                if !section.rows.isEmpty {
                    CapabilityReadableRows(rows: section.rows, tint: sectionTint)
                }

                if let body = section.body?.nilIfEmpty {
                    if section.isDisclosure {
                        CapabilityRawDisclosure(title: "Raw payload", text: body, tint: sectionTint)
                    } else {
                        CapabilityInvocationCodeBlock(text: body)
                    }
                }
            }
        }
    }

    private func sectionAccent(_ kind: CapabilityEvidencePresentation.SectionKind) -> Color {
        switch kind {
        case .summary, .target, .input, .result:
            return accent
        case .error:
            return .tronError
        case .technical:
            return .tronSlate
        }
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
