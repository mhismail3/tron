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
            .font(TronTypography.sheetSectionHeader)
            .foregroundStyle(Color.tronTextMuted)
    }

    private func boundedPreviewNote(_ text: String) -> some View {
        Label(text, systemImage: "text.badge.minus")
            .font(TronTypography.caption)
            .foregroundStyle(Color.tronAmber)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct ToolChipFlowLayout: Layout {
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

struct ToolStaticChip: View {
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
