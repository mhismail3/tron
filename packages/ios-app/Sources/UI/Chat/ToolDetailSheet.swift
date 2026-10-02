import SwiftUI
import TronMobileCore

struct ToolDetailSheet: View {
    let tool: ChatToolPresentation
    let density: ToolDetailDisplayDensity
    @State private var showingTechnicalDetails = false
    @State private var fullText: ToolFullText?
    @State private var showingChanges = false
    @State private var selectedNestedCall: NestedToolCallPresentation?
    @Environment(\.canonicalResourceSessionID) private var sessionID
    @Environment(\.displayPresentationHandler) private var presentDisplay

    private var accent: Color { tool.error ? .tronError : ChatSemanticPillRole.tool.accent }

    @ViewBuilder
    var body: some View {
        if let askUser = AskUserToolPresentation.completed(tool: tool) {
            AskUserCompletedFormView(presentation: askUser)
        } else {
            standardDetail(ToolDetailPresentation(tool: tool))
        }
    }

    private func standardDetail(_ presentation: ToolDetailPresentation) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                chipSection(presentation)
                if presentation.isCodemode {
                    codemodeTextSection(title: "Script", text: presentation.primaryValue)
                    codemodeTextSection(title: tool.isRunning ? "Live output" : "Result", text: presentation.readableResult)
                    if presentation.readableResult?.isEmpty ?? true {
                        Text(tool.isRunning ? "Waiting for the first runtime result." : "Completed without output.")
                            .font(TronTypography.bodySM)
                            .foregroundStyle(Color.tronTextSecondary)
                    }
                    callsSection(presentation)
                    attachmentSection(presentation)
                    classifyCostSection(presentation)
                } else {
                    primarySection(presentation)
                    resultSection(presentation)
                    diffSection(presentation)
                }
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
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                TronSheetInfoButton(accessibilityLabel: "Technical details", accent: accent) {
                    showingTechnicalDetails = true
                }
            }
        }
        .tronManagedSheet(
            isPresented: $showingChanges,
            identity: "chat.tool.changes.\(tool.id)"
        ) {
            if let diff = presentation.diff {
                ToolChangesSheet(diff: diff, accent: accent)
            }
        }
        .tronManagedSheet(item: $fullText, identity: { "chat.tool.full-text.\(tool.id).\($0.id)" }) { item in
            ToolTextSheet(title: item.title, text: item.text, accent: accent)
        }
        .tronManagedSheet(
            isPresented: $showingTechnicalDetails,
            identity: "chat.tool.technical.\(tool.id)"
        ) {
            ToolTechnicalDetailsSheet(tool: tool, presentation: presentation)
        }
        .tronManagedSheet(item: $selectedNestedCall, identity: { "chat.tool.nested.\(tool.id).\($0.id)" }) { nested in
            NestedToolCallDetailSheet(call: nested, accent: accent)
        }
    }

    private func chipSection(_ presentation: ToolDetailPresentation) -> some View {
        ToolChipFlowLayout(spacing: 7) {
            ToolStatusChip(tool: tool, accent: accent)
            ForEach(presentation.metadata) { item in
                ToolMetadataChip(item: item)
            }
            if let diff = presentation.diff {
                ToolDiffCountChip(diff: diff)
            }
            if tool.outputTruncated {
                ToolStaticChip(icon: "text.badge.minus", text: "Bounded output", accent: .tronSlate)
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
                VStack(alignment: .leading, spacing: 7) {
                    if presentation.sheetTitleIcon != nil || presentation.kind == .generic {
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
                    if preview.isBounded, presentation.kind != .bash {
                        boundedPreviewNote("Complete \(label.lowercased()) is available in Technical details.")
                    }
                }
                .padding(12)
                .tronGlassSurface(accent: accent, tintOpacity: 0.10)
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
                            .font(TronTypography.sans(size: TronTypography.sizeSecondary + TronSettingsLayoutPolicy.metadataSizeAdjustment))
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
            TronSettingsRow(
                icon: "rectangle.stack.badge.plus",
                title: title ?? diff.changesTitle,
                subtitle: diff.changesSubtitle,
                accent: accent,
                subtitleColor: Color.tronTextSecondary
            )
            .environment(\.tronSettingsSecondaryTextSizeAdjustment, TronSettingsLayoutPolicy.metadataSizeAdjustment)
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
                // Tool output is literal data, including extension/subagent
                // output. All tool result containers share the code typography.
                Text(verbatim: preview.text)
                    .font(TronTypography.code(size: TronTypography.sizeBodySM))
                    .foregroundStyle(Color.tronTextSecondary)
                    .textSelection(.enabled)
                    .padding(12)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tronGlassSurface(accent: accent, tintOpacity: 0.07)
            }
            if presentation.kind == .generic, let structured = presentation.structuredResult {
                structuredResultSection(structured, title: "Details")
            }
        } else if let structured = presentation.structuredResult, presentation.diff == nil {
            structuredResultSection(structured)
        } else if presentation.diff == nil, presentation.kind != .bash {
            Text(tool.isRunning ? "Waiting for the first runtime result." : "Completed without output.")
                .font(TronTypography.bodySM)
                .foregroundStyle(Color.tronTextSecondary)
        }
    }

    /// A codemode text (script or result): its opening lines, and a row that
    /// opens the whole text when the preview had to stop.
    @ViewBuilder
    private func codemodeTextSection(title: String, text: String?) -> some View {
        if let text, !text.isEmpty {
            let preview = ToolTextHeadPreview.make(text)
            VStack(alignment: .leading, spacing: 7) {
                sectionLabel(title)
                Text(verbatim: preview.text)
                    .font(TronTypography.code(size: TronTypography.sizeBodySM))
                    .foregroundStyle(Color.tronTextSecondary)
                    .padding(12)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tronGlassSurface(accent: accent, tintOpacity: 0.07)
                if preview.isTruncated {
                    Button { fullText = ToolFullText(title: title, text: text) } label: {
                        TronSettingsRow(
                            icon: title == "Script" ? "chevron.left.forwardslash.chevron.right" : "text.alignleft",
                            title: "View full \(title.lowercased())",
                            subtitle: "\(text.split(separator: "\n", omittingEmptySubsequences: false).count) lines",
                            accent: accent,
                            subtitleColor: Color.tronTextSecondary
                        )
                    }
                    .buttonStyle(.plain)
                    .tronGlassSurface(accent: accent, tintOpacity: 0.08, interactive: true)
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private func callsSection(_ presentation: ToolDetailPresentation) -> some View {
        if !presentation.nestedCalls.isEmpty {
        VStack(alignment: .leading, spacing: 7) {
            sectionLabel("Calls · \(presentation.nestedCalls.count)")
            // Up to 256 rows; only the visible ones are built.
            LazyVStack(alignment: .leading, spacing: 7) {
            ForEach(presentation.nestedCalls) { call in
                Button { selectedNestedCall = call } label: {
                    HStack(spacing: 9) {
                        Image(systemName: ToolDetailPresentation.icon(for: call.toolName))
                            .foregroundStyle(call.status == .failed ? Color.tronError : accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ToolDetailPresentation.displayTitle(for: call.toolName))
                                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
                                .lineLimit(1)
                            if let primary = call.primary {
                                Text(verbatim: primary.value)
                                    .font(TronTypography.code(size: TronTypography.sizeSecondary))
                                    .foregroundStyle(Color.tronTextSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        Spacer(minLength: 4)
                        Text([call.status.displayLabel, call.durationMs.map(ToolTiming.format(milliseconds:))].compactMap { $0 }.joined(separator: " · "))
                            .font(TronTypography.code(size: TronTypography.sizeSecondary))
                            .foregroundStyle(Color.tronTextSecondary)
                        Image(systemName: "chevron.right")
                            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                            .foregroundStyle(Color.tronTextMuted)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tronGlassSurface(accent: call.status == .failed ? .tronError : accent, tintOpacity: 0.06, interactive: true)
                }
                .buttonStyle(.plain)
            }
            }
            if !presentation.nestedCallsComplete {
                boundedPreviewNote("Some calls weren't fully recorded.")
            }
        }
        }
    }

    @ViewBuilder
    private func attachmentSection(_ presentation: ToolDetailPresentation) -> some View {
        if presentation.isCodemode,
           let nested = tool.details?.objectValue?["tronNested"]?.objectValue {
        let display = nested["display"]?.arrayValue ?? []
        let browsers = nested["browserLiveViews"]?.arrayValue ?? []
        if !display.isEmpty || !browsers.isEmpty {
        VStack(alignment: .leading, spacing: 7) {
            sectionLabel("Attachments")
            ForEach(Array(display.enumerated()), id: \.offset) { _, item in
                if let projection = item.objectValue?["display"],
                   let display = try? projection.decode(DisplayProjection.self),
                   let sessionID, let presentDisplay {
                    Button {
                        let route = DisplayRoute(sessionID: sessionID, display: display)
                        let command: DisplayPresentationCommand = DisplayPresentationPolicy.activationSurface(for: display) == .floating
                            ? .showFloating(route) : .showSheet(route)
                        presentDisplay(command)
                    } label: {
                        Label(display.title.isEmpty ? "Open display attachment" : display.title, systemImage: "rectangle.on.rectangle")
                            .font(TronTypography.secondaryDescription)
                            .foregroundStyle(Color.tronTextSecondary)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .tronGlassSurface(accent: accent, tintOpacity: 0.06, interactive: true)
                    }
                    .buttonStyle(.plain)
                } else {
                    Label("Display artifact attached", systemImage: "rectangle.on.rectangle")
                        .font(TronTypography.secondaryDescription)
                        .foregroundStyle(Color.tronTextSecondary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .tronGlassSurface(accent: accent, tintOpacity: 0.06)
                }
            }
            ForEach(Array(browsers.enumerated()), id: \.offset) { _, item in
                if let projection = item.objectValue?["display"],
                   let display = try? projection.decode(DisplayProjection.self),
                   let sessionID, let presentDisplay {
                    Button {
                        let route = DisplayRoute(sessionID: sessionID, display: display)
                        let command: DisplayPresentationCommand = DisplayPresentationPolicy.activationSurface(for: display) == .floating
                            ? .showFloating(route) : .showSheet(route)
                        presentDisplay(command)
                    } label: {
                        Label(display.title.isEmpty ? "Open browser view" : display.title, systemImage: "safari")
                            .font(TronTypography.secondaryDescription)
                            .foregroundStyle(Color.tronTextSecondary)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .tronGlassSurface(accent: accent, tintOpacity: 0.06, interactive: true)
                    }
                    .buttonStyle(.plain)
                } else {
                    Label("Browser live view attached", systemImage: "safari")
                        .font(TronTypography.secondaryDescription)
                        .foregroundStyle(Color.tronTextSecondary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .tronGlassSurface(accent: accent, tintOpacity: 0.06)
                }
            }
            if nested["complete"]?.boolValue == false {
                boundedPreviewNote("Some attachments were omitted.")
            }
        }
        }
        }
    }

    @ViewBuilder
    private func classifyCostSection(_ presentation: ToolDetailPresentation) -> some View {
        if let cost = presentation.classifyCostUSD {
            HStack {
                Label("Classification cost (estimated)", systemImage: "dollarsign.circle")
                    .font(TronTypography.secondaryDescription)
                Spacer()
                Text(cost.formatted(.currency(code: "USD").precision(.fractionLength(4...6))))
                    .font(TronTypography.code(size: TronTypography.sizeSecondary))
            }
            .foregroundStyle(Color.tronTextSecondary)
            .padding(10)
            .tronGlassSurface(accent: accent, tintOpacity: 0.06)
        }
    }

    private func structuredResultSection(_ structured: JSONValue, title: String? = nil) -> some View {
        TronStructuredJSONView(
            value: structured,
            title: title ?? (tool.isRunning ? "Live output" : "Result"),
            accent: accent,
            showsRawDisclosure: false
        )
    }

    private var primaryValueFont: Font {
        TronTypography.code(size: TronTypography.sizeBodySM, weight: .semibold)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(TronTypography.sheetSectionHeader)
            .foregroundStyle(Color.tronTextMuted)
    }

    private func boundedPreviewNote(_ text: String) -> some View {
        Text(text)
            .font(TronTypography.sans(size: TronTypography.sizeSecondary + TronSettingsLayoutPolicy.metadataSizeAdjustment))
            .foregroundStyle(Color.tronTextMuted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private func nestedStatusIcon(_ status: NestedToolCallPresentation.Status) -> String {
    switch status {
    case .running: "hourglass"
    case .completed: "checkmark.circle.fill"
    case .failed: "exclamationmark.triangle.fill"
    case .unfinished: "minus.circle"
    }
}

/// Section layout shared by the tool detail descendants so they read as
/// continuations of the parent sheet: same insets, labels and code surfaces.
private struct ToolDetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(TronTypography.sheetSectionHeader)
                .foregroundStyle(Color.tronTextMuted)
            content
        }
        .accessibilityElement(children: .contain)
    }
}

private struct ToolDetailCodeBlock: View {
    let text: String
    let accent: Color

    var body: some View {
        Text(verbatim: text)
            .font(TronTypography.code(size: TronTypography.sizeBodySM))
            .foregroundStyle(Color.tronTextSecondary)
            .textSelection(.enabled)
            .padding(12)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tronGlassSurface(accent: accent, tintOpacity: 0.07)
    }
}

/// Chrome shared by sheets a tool detail opens: inline principal title (no
/// reserved large-title region), Done, no drag indicator, parent insets.
private struct ToolDetailChildSheet<Content: View>: View {
    let title: String
    var icon: String?
    let accent: Color
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) { content }
                    .padding(.horizontal, 16)
                    .padding(.top, 2)
                    .padding(.bottom, 18)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .defaultScrollAnchor(.top, for: .initialOffset)
            .tronScrollEdgeChrome()
            .tronToolDetailNavigationChrome()
            .toolbar {
                ToolbarItem(placement: .principal) {
                    TronSheetTitle(title: title, accent: accent, icon: icon)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(accent)
                    }
                    .accessibilityLabel("Done")
                }
            }
        }
        .tronTopBlur(.toolDetail)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .tronPresentation()
    }
}

/// One full text a tool detail previews, opened in its own sheet.
struct ToolFullText: Identifiable, Hashable {
    let title: String
    let text: String
    var id: String { title }
}

/// The whole of a previewed tool text, titled by what it is and shown directly
/// in the same selectable, scrollable code view as the Request JSON sheet.
struct ToolTextSheet: View {
    let title: String
    let text: String
    let accent: Color
    @Environment(\.dismiss) private var dismiss
    @State private var detent: PresentationDetent = .large

    var body: some View {
        NavigationStack {
            TronReadOnlyTextView(text: text, style: .code)
                .tronDocumentTopBlurSurface()
                .ignoresSafeArea(.container, edges: .bottom)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        TronSheetTitle(title: title, accent: accent)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button { dismiss() } label: {
                            Image(systemName: "checkmark")
                                .font(TronTypography.buttonSM)
                                .foregroundStyle(accent)
                        }
                        .accessibilityLabel("Done")
                    }
                }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.hidden)
        .tint(accent)
    }
}

struct NestedToolCallDetailSheet: View {
    let call: NestedToolCallPresentation
    let accent: Color

    private var statusAccent: Color {
        switch call.status {
        case .failed: .tronError
        case .unfinished: .tronTextSecondary
        case .running, .completed: accent
        }
    }

    /// Arguments other than the one already shown as the primary value.
    private var remainingArguments: JSONValue? {
        guard let arguments = call.arguments else { return nil }
        guard let primary = call.primary, let object = arguments.objectValue else { return arguments }
        let rest = object.filter { $0.value.stringValue != primary.value }
        return rest.isEmpty ? nil : .object(rest)
    }

    var body: some View {
        ToolDetailChildSheet(
            title: ToolDetailPresentation.displayTitle(for: call.toolName),
            icon: ToolDetailPresentation.sheetTitleIcon(for: call.toolName),
            accent: accent
        ) {
            ToolChipFlowLayout(spacing: 7) {
                ToolStaticChip(
                    icon: nestedStatusIcon(call.status),
                    text: [call.status.displayLabel, call.durationMs.map(ToolTiming.format(milliseconds:))]
                        .compactMap { $0 }.joined(separator: " · "),
                    accent: statusAccent
                )
            }
            if let error = call.error, !error.isEmpty {
                ToolDetailSection(title: "Error") {
                    ToolDetailCodeBlock(text: error, accent: .tronError)
                }
            }
            if let primary = call.primary {
                ToolDetailSection(title: primary.label) {
                    ToolDetailCodeBlock(text: primary.value, accent: accent)
                }
            }
            if let remaining = remainingArguments {
                TronStructuredJSONView(
                    value: remaining,
                    title: call.primary == nil ? "Arguments" : "Other arguments",
                    accent: accent,
                    showsRawDisclosure: false
                )
            } else if call.arguments == nil, let bytes = call.argumentsBytes {
                Text("Arguments omitted (\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))).")
                    .font(TronTypography.secondaryDescription)
                    .foregroundStyle(Color.tronTextSecondary)
            }
            // Only each nested call's request, status and timing are recorded;
            // its output reaches the user through the script's own result.
            Text("This call's output is part of the codemode script's result.")
                .font(TronTypography.sans(size: TronTypography.sizeSecondary + TronSettingsLayoutPolicy.metadataSizeAdjustment))
                .foregroundStyle(Color.tronTextMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
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
    @State private var localClock: ToolElapsedClock?
    @State private var isVisible = false

    var body: some View {
        Group {
            if tool.isRunning {
                if tool.isActivelyExecuting, PresentationClockPolicy.runs(
                    surfaceActive: presentationActivity.allowsContinuousAnimation,
                    sceneActive: scenePhase == .active,
                    viewportVisible: isVisible
                ) {
                    TimelineView(timelineSchedule) { _ in
                        content(runningPresentation(), showsSpinner: true)
                    }
                } else {
                    content(runningPresentation(), showsSpinner: true)
                }
            } else {
                content(ToolStatusChipPresentation.make(tool: tool, at: .now), showsSpinner: false)
            }
        }
        .onAppear {
            isVisible = true
            synchronizeLocalClock()
        }
        .onDisappear { isVisible = false }
        .onChange(of: tool) { _, _ in synchronizeLocalClock() }
    }

    private func runningPresentation() -> ToolStatusChipPresentation {
        let elapsed = Self.milliseconds(
            tool: tool,
            localClock: localClock,
            at: .now,
            uptime: ProcessInfo.processInfo.systemUptime
        )
        return ToolStatusChipPresentation.make(tool: tool, elapsedMilliseconds: elapsed)
    }

    /// Only the chip's duration changes while it runs, so the schedule follows
    /// the elapsed value alone.
    private var timelineSchedule: ToolElapsedTimelineSchedule {
        let tool = tool
        let localClock = localClock
        return ToolElapsedTimelineSchedule(interval: 0.5) { date, uptime in
            Self.milliseconds(tool: tool, localClock: localClock, at: date, uptime: uptime)
        }
    }

    private static func milliseconds(
        tool: ChatToolPresentation,
        localClock: ToolElapsedClock?,
        at date: Date,
        uptime: TimeInterval
    ) -> Int? {
        localClock?.milliseconds(at: uptime) ?? tool.elapsedMilliseconds(at: date, uptime: uptime)
    }

    private func synchronizeLocalClock() {
        guard tool.isActivelyExecuting,
              let baseline = tool.elapsedMilliseconds(at: .now) else {
            localClock = nil
            return
        }
        localClock = ToolElapsedClock(
            baselineMilliseconds: baseline,
            baselineUptime: ProcessInfo.processInfo.systemUptime
        )
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
