import SwiftUI

struct ToolDetailSheet: View {
    let tool: ChatToolPresentation
    let density: ToolDetailDisplayDensity
    @State private var showingTechnicalDetails = false
    @State private var showingChanges = false

    private var accent: Color { tool.error ? .tronError : ChatSemanticPillRole.tool.accent }

    var body: some View {
        let presentation = ToolDetailPresentation(tool: tool)
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                chipSection(presentation)
                primarySection(presentation)
                resultSection(presentation)
                diffSection(presentation)
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
        .tronManagedSheet(
            isPresented: $showingChanges,
            identity: "chat.tool.changes.\(tool.id)"
        ) {
            if let diff = presentation.diff {
                ToolChangesSheet(diff: diff, accent: accent)
            }
        }
        .tronManagedSheet(
            isPresented: $showingTechnicalDetails,
            identity: "chat.tool.technical.\(tool.id)"
        ) {
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
                Group {
                    if presentation.sheetTitleIcon != nil {
                        primaryValue(presentation, preview: preview)
                    } else {
                        HStack(alignment: .center, spacing: 10) {
                            Image(systemName: presentation.icon)
                                .font(TronTypography.sans(
                                    size: TronTypography.sizeBody,
                                    weight: .semibold
                                ))
                                .foregroundStyle(accent)
                                .frame(width: 22)
                            primaryValue(presentation, preview: preview)
                        }
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

    @ViewBuilder
    private func primaryValue(
        _ presentation: ToolDetailPresentation,
        preview: ToolTextPreview
    ) -> some View {
        if let path = presentation.primaryPath {
            pathText(path)
        } else if presentation.kind == .bash {
            Text(verbatim: preview.text)
                .font(primaryValueFont)
                .foregroundStyle(Color.tronTextSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(preview.text)
                .font(primaryValueFont)
                .foregroundStyle(Color.tronTextSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func pathText(_ path: ToolPathPresentation) -> some View {
        let text = path.directory.map {
            let directory = Text($0).foregroundColor(Color.tronTextSecondary)
            let basename = Text(path.basename).foregroundColor(accent)
            return Text("\(directory)\(basename)")
        } ?? Text(path.basename).foregroundColor(accent)
        return text
            .font(primaryValueFont)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func diffSection(_ presentation: ToolDetailPresentation) -> some View {
        if let diff = presentation.diff {
            if diff.showsInline {
                VStack(alignment: .leading, spacing: 7) {
                    sectionLabel("Change")
                    ToolDiffView(lines: diff.visibleLines(for: density))
                    fullDiffButton(diff)
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

    private func fullDiffButton(_ diff: ToolDiffPresentation) -> some View {
        changesButton(diff, title: "View full diff")
    }

    private func changesButton(
        _ diff: ToolDiffPresentation,
        title: String? = nil
    ) -> some View {
        Button { showingChanges = true } label: {
            HStack(spacing: 11) {
                Image(systemName: "rectangle.stack.badge.plus")
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title ?? diff.changesTitle)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(Color.tronTextPrimary)
                    Text(diff.changesSubtitle)
                        .font(TronTypography.caption)
                        .foregroundStyle(Color.tronTextSecondary)
                }
                Spacer(minLength: 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tronGlassSurface(accent: accent, tintOpacity: 0.08, interactive: true)
        .accessibilityHint("Opens all file changes")
    }

    @ViewBuilder private func resultSection(_ presentation: ToolDetailPresentation) -> some View {
        if presentation.prefersStructuredResult,
           let structured = presentation.structuredResult,
           presentation.diff == nil {
            structuredResultSection(structured)
        } else if let preview = presentation.readableResultPreview, !preview.text.isEmpty {
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
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .tronGlassSurface(accent: accent, tintOpacity: 0.07)
                }
            }
        } else if let structured = presentation.structuredResult, presentation.diff == nil {
            structuredResultSection(structured)
        } else if presentation.diff == nil {
            Text(tool.isRunning ? "Waiting for the first runtime result." : "Completed without output.")
                .font(TronTypography.bodySM)
                .foregroundStyle(Color.tronTextSecondary)
        }
    }

    private func structuredResultSection(_ structured: JSONValue) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionLabel(tool.isRunning ? "Current result" : "Result")
            TronStructuredJSONView(
                value: structured,
                title: "Result",
                accent: accent,
                showsRawDisclosure: false
            )
        }
    }

    private var primaryValueFont: Font {
        TronTypography.code(size: TronTypography.sizeBodySM, weight: .semibold)
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

enum ToolChipFlowLayoutPolicy {
    static func frames(
        for sizes: [CGSize],
        availableWidth: CGFloat,
        spacing: CGFloat
    ) -> [CGRect] {
        let width = availableWidth.isFinite ? max(1, availableWidth) : 1
        let gap = spacing.isFinite ? max(0, spacing) : 0
        var frames: [CGRect] = []
        frames.reserveCapacity(sizes.count)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for measured in sizes {
            let size = CGSize(
                width: measured.width.isFinite ? min(width, max(1, measured.width)) : width,
                height: measured.height.isFinite ? max(1, measured.height) : 1
            )
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + gap
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + gap
            rowHeight = max(rowHeight, size.height)
        }
        return frames
    }
}

struct ToolChipFlowLayout: Layout {
    struct Cache {
        var availableWidth: CGFloat = 0
        var sizes: [CGSize] = []
    }

    let spacing: CGFloat

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = Cache()
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        let availableWidth = max(1, proposal.width ?? 320)
        measure(subviews, availableWidth: availableWidth, cache: &cache)
        let frames = ToolChipFlowLayoutPolicy.frames(
            for: cache.sizes,
            availableWidth: availableWidth,
            spacing: spacing
        )
        return CGSize(
            width: min(availableWidth, frames.map(\.maxX).max() ?? 0),
            height: frames.map(\.maxY).max() ?? 0
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        let availableWidth = max(1, bounds.width)
        if abs(cache.availableWidth - availableWidth) > 0.5
            || cache.sizes.count != subviews.count {
            measure(subviews, availableWidth: availableWidth, cache: &cache)
        }
        let frames = ToolChipFlowLayoutPolicy.frames(
            for: cache.sizes,
            availableWidth: availableWidth,
            spacing: spacing
        )
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    private func measure(
        _ subviews: Subviews,
        availableWidth: CGFloat,
        cache: inout Cache
    ) {
        cache.availableWidth = availableWidth
        cache.sizes = subviews.map { constrainedSize(of: $0, availableWidth: availableWidth) }
    }

    private func constrainedSize(of subview: LayoutSubview, availableWidth: CGFloat) -> CGSize {
        let ideal = subview.sizeThatFits(.unspecified)
        if ideal.width.isFinite, ideal.height.isFinite,
           ideal.width > 0, ideal.height > 0,
           ideal.width <= availableWidth {
            return ideal
        }
        let constrained = subview.sizeThatFits(ProposedViewSize(width: availableWidth, height: nil))
        return CGSize(
            width: constrained.width.isFinite ? min(availableWidth, max(1, constrained.width)) : availableWidth,
            height: constrained.height.isFinite ? max(1, constrained.height) : 1
        )
    }
}

private struct ToolStatusChip: View {
    let tool: ChatToolPresentation
    let accent: Color
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false

    var body: some View {
        Group {
            if tool.isRunning {
                if PresentationClockPolicy.runs(
                    surfaceActive: presentationActivity.allowsContinuousAnimation,
                    sceneActive: scenePhase == .active,
                    viewportVisible: isVisible
                ) {
                    TimelineView(.periodic(from: ToolTiming.date(tool.startedAt) ?? .now, by: 0.5)) { context in
                        content(ToolStatusChipPresentation.make(tool: tool, at: context.date), showsSpinner: true)
                    }
                } else {
                    content(ToolStatusChipPresentation.make(tool: tool, at: .now), showsSpinner: true)
                }
            } else {
                content(ToolStatusChipPresentation.make(tool: tool, at: .now), showsSpinner: false)
            }
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
    }

    private func content(_ presentation: ToolStatusChipPresentation, showsSpinner: Bool) -> some View {
        HStack(spacing: ChatCompactPillLayoutPolicy.itemSpacing) {
            ChatCompactPillLeadingIcon(
                icon: presentation.icon,
                accent: accent,
                showsProgress: showsSpinner,
                iconSize: ChatCompactPillLayoutPolicy.standardIconSize
            )
            Text(presentation.text)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .monospacedDigit()
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .layoutPriority(1)
        }
        .foregroundStyle(accent)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .glassEffect(.regular.tint(accent.opacity(0.12)), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

private struct ToolMetadataChip: View {
    let item: ToolDetailMetadata

    var body: some View {
        HStack(spacing: ChatCompactPillLayoutPolicy.itemSpacing) {
            ChatCompactPillLeadingIcon(
                icon: item.icon,
                accent: .tronTextSecondary,
                iconSize: ChatCompactPillLayoutPolicy.standardIconSize
            )
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
        HStack(spacing: ChatCompactPillLayoutPolicy.itemSpacing) {
            ChatCompactPillLeadingIcon(
                icon: icon,
                accent: accent,
                iconSize: ChatCompactPillLayoutPolicy.standardIconSize
            )
            Text(text)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .foregroundStyle(accent)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .glassEffect(.regular.tint(accent.opacity(0.10)), in: Capsule())
    }
}

private struct ToolActivityChip: View {
    let tool: ChatToolPresentation
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false

    var body: some View {
        Group {
            if PresentationClockPolicy.runs(
                surfaceActive: presentationActivity.allowsContinuousAnimation,
                sceneActive: scenePhase == .active,
                viewportVisible: isVisible
            ) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    activityContent(at: context.date)
                }
            } else {
                activityContent(at: .now)
            }
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
    }

    @ViewBuilder
    private func activityContent(at date: Date) -> some View {
            if let update = ToolTiming.date(tool.lastProgressAt) {
                let age = max(0, Int(date.timeIntervalSince(update)))
                ToolStaticChip(
                    icon: "waveform.path.ecg",
                    text: age < 2 ? "Updated now" : "Updated \(ageLabel(age)) ago",
                    accent: .tronAmber
                )
            }
    }

    private func ageLabel(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }
}
