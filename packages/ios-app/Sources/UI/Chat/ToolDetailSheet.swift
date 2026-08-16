import SwiftUI

struct ToolDetailSheet: View {
    let tool: ChatToolPresentation
    let density: ToolDetailDisplayDensity
    @State private var showingTechnicalDetails = false
    @State private var showingChanges = false

    private var accent: Color { tool.error ? .tronError : .tronEmerald }

    var body: some View {
        let presentation = ToolDetailPresentation(tool: tool)
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                chipSection(presentation)
                primarySection(presentation)
                diffSection(presentation)
                resultSection(presentation)
                technicalDetailsButton
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .defaultScrollAnchor(.top, for: .initialOffset)
        .defaultScrollAnchor(.top, for: .alignment)
        .defaultScrollAnchor(.top, for: .sizeChanges)
        .tronScrollEdgeChrome()
        .sheet(isPresented: $showingChanges) {
            if let diff = presentation.diff {
                ToolChangesSheet(diff: diff, accent: accent)
            }
        }
        .sheet(isPresented: $showingTechnicalDetails) {
            ToolTechnicalDetailsSheet(tool: tool, presentation: presentation)
        }
    }

    private func chipSection(_ presentation: ToolDetailPresentation) -> some View {
        ToolChipFlowLayout(spacing: 7) {
            ToolStatusChip(tool: tool, accent: accent)
            ForEach(presentation.metadata) { item in
                ToolMetadataChip(item: item)
            }
            if tool.outputTruncated {
                ToolStaticChip(icon: "text.badge.minus", text: "Bounded output", accent: .tronAmber)
            }
            if tool.isRunning {
                ToolActivityChip(tool: tool)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func primarySection(_ presentation: ToolDetailPresentation) -> some View {
        if let label = presentation.primaryLabel,
           let preview = presentation.primaryPreview,
           !preview.text.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                sectionLabel(label)
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: presentation.icon)
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(width: 22)
                    if let path = presentation.primaryPath {
                        pathText(path)
                    } else if presentation.kind == .bash {
                        Text(verbatim: preview.text)
                            .font(TronTypography.codeContent)
                            .foregroundStyle(Color.tronTextSecondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(preview.text)
                            .font(TronTypography.code(size: TronTypography.sizeBodySM, weight: .semibold))
                            .foregroundStyle(Color.tronTextSecondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
                .tronGlassSurface(accent: accent, tintOpacity: 0.10)
                if preview.isBounded, presentation.kind != .bash {
                    boundedPreviewNote("Complete \(label.lowercased()) is available in Technical details.")
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    private func pathText(_ path: ToolPathPresentation) -> some View {
        let text = path.directory.map {
            let directory = Text($0).foregroundColor(Color.tronTextSecondary)
            let basename = Text(path.basename).foregroundColor(accent)
            return Text("\(directory)\(basename)")
        } ?? Text(path.basename).foregroundColor(accent)
        return text
            .font(TronTypography.code(size: TronTypography.sizeBodySM, weight: .semibold))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func diffSection(_ presentation: ToolDetailPresentation) -> some View {
        if let diff = presentation.diff {
            if diff.showsInline {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline) {
                        sectionLabel("Change")
                        Spacer()
                        Button("Open full diff") { showingChanges = true }
                            .font(TronTypography.caption)
                            .foregroundStyle(accent)
                            .buttonStyle(.plain)
                    }
                    ToolDiffView(lines: diff.visibleLines(for: density))
                    if density == .glance, diff.compactLines != diff.lines {
                        Text("Pull up for more context, or open the full diff.")
                            .font(TronTypography.caption)
                            .foregroundStyle(Color.tronTextMuted)
                    }
                }
            } else {
                changesButton(diff)
            }
        }
    }

    private func changesButton(_ diff: ToolDiffPresentation) -> some View {
        Button { showingChanges = true } label: {
            HStack(spacing: 11) {
                Image(systemName: "rectangle.stack.badge.plus")
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(diff.changesTitle)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(Color.tronTextPrimary)
                    Text(diff.changesSubtitle)
                        .font(TronTypography.caption)
                        .foregroundStyle(Color.tronTextSecondary)
                }
                Spacer(minLength: 8)
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tronGlassSurface(accent: accent, tintOpacity: 0.08, interactive: true)
        .accessibilityHint("Opens all file changes")
    }

    @ViewBuilder private func resultSection(_ presentation: ToolDetailPresentation) -> some View {
        if let preview = presentation.readableResultPreview, !preview.text.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                sectionLabel(tool.isRunning ? "Live output" : "Result")
                if presentation.usesCodeResult {
                    Text(preview.text)
                        .font(TronTypography.code(size: TronTypography.sizeBodySM))
                        .foregroundStyle(Color.tronTextSecondary)
                        .textSelection(.enabled)
                        .padding(12)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .tronGlassSurface(accent: accent, tintOpacity: 0.07)
                } else {
                    TronMarkdownView(text: preview.text, streaming: tool.isRunning)
                        .padding(12)
                        .tronGlassSurface(accent: accent, tintOpacity: 0.07)
                }
                if preview.isBounded {
                    boundedPreviewNote(
                        tool.outputTruncated
                            ? "Complete available result data is in Technical details; Gateway marked the output truncated."
                            : "Complete result data is available in Technical details."
                    )
                }
            }
        } else if let structured = presentation.structuredResult, presentation.diff == nil {
            VStack(alignment: .leading, spacing: 7) {
                sectionLabel(tool.isRunning ? "Current result" : "Result")
                TronStructuredJSONView(
                    value: structured,
                    title: "Result",
                    accent: accent,
                    showsRawDisclosure: false
                )
            }
        } else if presentation.diff == nil {
            Text(tool.isRunning ? "Waiting for the first runtime result." : "Completed without output.")
                .font(TronTypography.bodySM)
                .foregroundStyle(Color.tronTextSecondary)
        }
    }

    private var technicalDetailsButton: some View {
        Button { showingTechnicalDetails = true } label: {
            TronSettingsRow(
                icon: "slider.horizontal.3",
                title: "Technical details",
                subtitle: "Execution metadata and request/result JSON",
                accent: .tronSlate
            ) { EmptyView() }
        }
        .buttonStyle(.plain)
        .tronGlassSurface(accent: .tronSlate, tintOpacity: 0.08, interactive: true)
        .accessibilityHint("Opens protocol and timing details")
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
            .foregroundStyle(Color.tronTextMuted)
    }

    private func boundedPreviewNote(_ text: String) -> some View {
        Label(text, systemImage: "text.badge.minus")
            .font(TronTypography.caption)
            .foregroundStyle(Color.tronAmber)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ToolChipFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let availableWidth = max(1, proposal.width ?? 320)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var measuredWidth: CGFloat = 0
        for subview in subviews {
            let size = constrainedSize(of: subview, availableWidth: availableWidth)
            if x > 0, x + size.width > availableWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            measuredWidth = max(measuredWidth, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(availableWidth, measuredWidth), height: y + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let availableWidth = max(1, bounds.width)
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = constrainedSize(of: subview, availableWidth: availableWidth)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: size.width, height: nil)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }

    private func constrainedSize(of subview: LayoutSubview, availableWidth: CGFloat) -> CGSize {
        let ideal = subview.sizeThatFits(.unspecified)
        guard ideal.width > availableWidth else { return ideal }

        let constrained = subview.sizeThatFits(ProposedViewSize(width: availableWidth, height: nil))
        return CGSize(width: min(availableWidth, constrained.width), height: constrained.height)
    }
}

private struct ToolStatusChip: View {
    let tool: ChatToolPresentation
    let accent: Color

    var body: some View {
        if tool.isRunning {
            TimelineView(.periodic(from: ToolTiming.date(tool.startedAt) ?? .now, by: 0.5)) { context in
                content(ToolStatusChipPresentation.make(tool: tool, at: context.date), showsSpinner: true)
            }
        } else {
            content(ToolStatusChipPresentation.make(tool: tool), showsSpinner: false)
        }
    }

    private func content(_ presentation: ToolStatusChipPresentation, showsSpinner: Bool) -> some View {
        HStack(spacing: 6) {
            if showsSpinner {
                ProgressView().controlSize(.small).tint(accent)
            } else {
                Image(systemName: presentation.icon)
                    .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .semibold))
            }
            Text(presentation.text)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .monospacedDigit()
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .layoutPriority(1)
        }
        .foregroundStyle(accent)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassEffect(.regular.tint(accent.opacity(0.12)), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

private struct ToolMetadataChip: View {
    let item: ToolDetailMetadata

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: item.icon)
                .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .semibold))
            Text(item.chipPreview.text)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .layoutPriority(1)
        }
        .foregroundStyle(Color.tronTextSecondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: 260, alignment: .leading)
        .glassEffect(.regular.tint(Color.tronSlate.opacity(0.09)), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.accessibilityLabel)
    }
}

private struct ToolStaticChip: View {
    let icon: String
    let text: String
    let accent: Color

    var body: some View {
        Label(text, systemImage: icon)
            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
            .foregroundStyle(accent)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .glassEffect(.regular.tint(accent.opacity(0.10)), in: Capsule())
    }
}

private struct ToolActivityChip: View {
    let tool: ChatToolPresentation

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let update = ToolTiming.date(tool.lastProgressAt) {
                let age = max(0, Int(context.date.timeIntervalSince(update)))
                ToolStaticChip(
                    icon: "waveform.path.ecg",
                    text: age < 2 ? "Updated now" : "Updated \(ageLabel(age)) ago",
                    accent: .tronAmber
                )
            }
        }
    }

    private func ageLabel(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }
}

private struct ToolChangesSheet: View {
    let diff: ToolDiffPresentation
    let accent: Color
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ToolChipFlowLayout(spacing: 7) {
                        if let count = diff.requestedChangeCount {
                            ToolStaticChip(
                                icon: "pencil",
                                text: "\(count) \(count == 1 ? "change" : "changes")",
                                accent: accent
                            )
                        }
                        if let count = diff.diffUnitCount {
                            ToolStaticChip(
                                icon: "rectangle.stack",
                                text: "\(count) diff \(count == 1 ? "section" : "sections")",
                                accent: .tronBlue
                            )
                        }
                    }
                    ToolDiffView(lines: diff.lines)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .defaultScrollAnchor(.top, for: .initialOffset)
            .defaultScrollAnchor(.top, for: .alignment)
            .defaultScrollAnchor(.top, for: .sizeChanges)
            .tronScrollEdgeChrome()
            .tronToolDetailNavigationChrome()
            .toolbar {
                ToolbarItem(placement: .principal) { TronSheetTitle(title: "Changes", accent: accent) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(Color.tronEmerald)
                    }
                    .accessibilityLabel("Done")
                }
            }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tronPresentation()
    }
}

private struct ToolDiffView: View {
    let lines: [ToolDiffLine]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(marker(for: line.kind))
                            .font(TronFont.mono(11, weight: .bold))
                            .foregroundStyle(foreground(for: line.kind))
                            .frame(width: 15, alignment: .center)
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(TronTypography.codeContent)
                            .foregroundStyle(foreground(for: line.kind))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, verticalPadding(for: line.kind))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(background(for: line.kind))
                }
            }
            .padding(.vertical, 7)
        }
        .tronGlassSurface(accent: .tronEmerald, tintOpacity: 0.07)
        .accessibilityLabel("File changes")
    }

    private func marker(for kind: ToolDiffLineKind) -> String {
        switch kind {
        case .addition: "+"
        case .removal: "−"
        case .hunk: "•"
        case .omitted: "…"
        case .context, .metadata: " "
        }
    }

    private func foreground(for kind: ToolDiffLineKind) -> Color {
        switch kind {
        case .addition: .tronEmerald
        case .removal: .tronError
        case .hunk: .tronBlue
        case .omitted: .tronAmber
        case .metadata: .tronTextMuted
        case .context: .tronTextSecondary
        }
    }

    private func background(for kind: ToolDiffLineKind) -> Color {
        switch kind {
        case .addition: .tronEmerald.opacity(0.10)
        case .removal: .tronError.opacity(0.10)
        case .hunk: .tronBlue.opacity(0.08)
        case .omitted: .tronAmber.opacity(0.08)
        case .context, .metadata: .clear
        }
    }

    private func verticalPadding(for kind: ToolDiffLineKind) -> CGFloat {
        switch kind {
        case .hunk, .omitted: 6
        default: 2
        }
    }
}

private struct ToolTechnicalDetailsSheet: View {
    let tool: ChatToolPresentation
    let presentation: ToolDetailPresentation
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPayload: ToolTechnicalPayload?

    private var accent: Color { tool.error ? .tronError : .tronSlate }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: TronSpacing.section) {
                    protocolMetadata
                    payload("Request", value: tool.request ?? .null)
                    payload("Result", value: ToolTechnicalResultResolver.resolve(tool))
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .defaultScrollAnchor(.top, for: .initialOffset)
            .defaultScrollAnchor(.top, for: .alignment)
            .defaultScrollAnchor(.top, for: .sizeChanges)
            .tronScrollEdgeChrome()
            .tronToolDetailNavigationChrome()
            .toolbar {
                ToolbarItem(placement: .principal) {
                    TronSheetTitle(title: "Technical details", accent: accent)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(Color.tronEmerald)
                    }
                    .accessibilityLabel("Done")
                }
            }
        }
        .sheet(item: $selectedPayload) { payload in
            ToolTechnicalPayloadSheet(payload: payload, accent: accent)
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tronPresentation()
    }

    private var protocolMetadata: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Execution")
            VStack(spacing: 0) {
                ForEach(Array(executionMetadata.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().overlay(accent.opacity(0.18)) }
                    compactMetadataRow(item)
                }
            }
            .tronGlassSurface(accent: accent, tintOpacity: 0.08)
        }
    }

    private var executionMetadata: [ToolTechnicalMetadataItem] {
        var items = [
            ToolTechnicalMetadataItem(title: "Tool", value: presentation.displayTitle, icon: presentation.icon),
            ToolTechnicalMetadataItem(
                title: "Status",
                value: tool.subtitle,
                icon: tool.error ? "exclamationmark.triangle.fill" : "waveform.path.ecg"
            ),
        ]
        if !tool.id.isEmpty {
            items.append(.init(title: "Call ID", value: tool.id, icon: "number"))
        }
        if let sequence = tool.progressSequence {
            items.append(.init(title: "Progress sequence", value: String(sequence), icon: "arrow.triangle.2.circlepath"))
        }
        if tool.outputTruncated {
            items.append(.init(title: "Readable output", value: "Bounded by Gateway", icon: "text.badge.minus"))
        }
        if presentation.kind == .bash, presentation.primaryPreview?.isBounded == true {
            items.append(.init(
                title: "Command preview",
                value: "Bounded; complete command is in Request JSON below",
                icon: "text.badge.minus"
            ))
        }
        if let startedAt = tool.startedAt {
            items.append(.init(title: "Started", value: startedAt, icon: "play"))
        }
        if let lastProgressAt = tool.lastProgressAt {
            items.append(.init(title: "Last update", value: lastProgressAt, icon: "clock.arrow.circlepath"))
        }
        if let completedAt = tool.completedAt {
            items.append(.init(title: "Completed", value: completedAt, icon: "checkmark"))
        }
        if let duration = tool.elapsedMilliseconds() {
            items.append(.init(
                title: "Duration",
                value: ToolTiming.format(milliseconds: duration),
                icon: "timer"
            ))
        }
        return items
    }

    private func compactMetadataRow(_ item: ToolTechnicalMetadataItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: item.icon)
                .font(TronTypography.sans(size: TronTypography.sizeBody2, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 16)
            Text(item.title)
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(Color.tronTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text(item.value)
                .font(TronTypography.code(size: TronTypography.sizeBody2))
                .foregroundStyle(Color.tronTextSecondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title), \(item.value)")
    }

    private func payload(_ title: String, value: JSONValue) -> some View {
        let summary = ToolTechnicalPayloadSummary.summary(for: value)
        return VStack(alignment: .leading, spacing: 8) {
            sectionLabel("\(title) JSON")
            Button {
                selectedPayload = ToolTechnicalPayload(title: title, value: value)
            } label: {
                TronSettingsRow(
                    icon: "curlybraces",
                    title: "Inspect \(title) JSON",
                    subtitle: summary,
                    accent: accent
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Inspect \(title) JSON, \(summary)")
            .tronGlassSurface(accent: accent, tintOpacity: 0.08, interactive: true)
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
            .foregroundStyle(Color.tronTextMuted)
    }
}

enum ToolTechnicalPayloadSummary {
    static func summary(for value: JSONValue) -> String {
        if let object = value.objectValue {
            return "\(object.count) top-level field\(object.count == 1 ? "" : "s")"
        }
        if let array = value.arrayValue {
            return "\(array.count) top-level item\(array.count == 1 ? "" : "s")"
        }
        return "Scalar protocol value"
    }
}

private struct ToolTechnicalPayload: Identifiable {
    let title: String
    let value: JSONValue

    var id: String { title }
}

private struct ToolTechnicalPayloadSheet: View {
    let payload: ToolTechnicalPayload
    let accent: Color
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                TronStructuredJSONView(
                    value: payload.value,
                    title: "\(payload.title) JSON",
                    accent: accent
                )
                .padding(18)
            }
            .defaultScrollAnchor(.top)
            .tronScrollEdgeChrome()
            .tronToolDetailNavigationChrome()
            .toolbar {
                ToolbarItem(placement: .principal) {
                    TronSheetTitle(title: "\(payload.title) JSON", accent: accent)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(Color.tronEmerald)
                    }
                    .accessibilityLabel("Done")
                }
            }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tronPresentation()
    }
}

extension View {
    /// Tool-owned sheets use principal toolbar titles. Explicit inline mode
    /// prevents NavigationStack from reserving an empty large-title region
    /// above the first scroll row on physical devices.
    func tronToolDetailNavigationChrome() -> some View {
        navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ToolTechnicalMetadataItem: Identifiable {
    let title: String
    let value: String
    let icon: String

    var id: String { title }
}
