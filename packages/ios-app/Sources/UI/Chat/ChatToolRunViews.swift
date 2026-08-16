import SwiftUI

struct ToolCard: View {
    let title: String
    let subtitle: String
    let content: String
    var error = false
    var request: JSONValue? = nil
    var response: JSONValue? = nil
    var fallbackContent: JSONValue? = nil
    var outputTruncated = false
    var timing: ChatToolPresentation? = nil
    var onOpenDetails: ((String) -> Void)? = nil
    @State private var detailPresentation: ToolDetailRoute?
    @State private var detailDetent: PresentationDetent = .medium
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        title: String,
        subtitle: String,
        content: String,
        error: Bool = false,
        request: JSONValue? = nil,
        response: JSONValue? = nil,
        fallbackContent: JSONValue? = nil,
        outputTruncated: Bool = false,
        timing: ChatToolPresentation? = nil,
        onOpenDetails: ((String) -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
        self.error = error
        self.request = request
        self.response = response
        self.fallbackContent = fallbackContent
        self.outputTruncated = outputTruncated
        self.timing = timing
        self.onOpenDetails = onOpenDetails
    }

    init(data: ChatToolPresentation, onOpenDetails: ((String) -> Void)? = nil) {
        self.init(
            title: data.title,
            subtitle: data.subtitle,
            content: data.content,
            error: data.error,
            request: data.request,
            response: data.response,
            fallbackContent: data.fallbackContent,
            outputTruncated: data.outputTruncated,
            timing: data,
            onOpenDetails: onOpenDetails
        )
    }

    var body: some View {
        Button {
            if let onOpenDetails {
                onOpenDetails(detailTool.id)
            } else {
                detailDetent = .medium
                detailPresentation = ToolDetailRoute(toolID: detailTool.id)
            }
        } label: {
            ChatCompactPillSurface(tone: tone, material: .glass, interactive: true) {
                ChatCompactPillLabel(
                    icon: icon,
                    title: displayTitle,
                    detail: subtitle.lowercased(),
                    tone: tone,
                    showsProgress: subtitle == "Running"
                ) {
                    if let timing {
                        ToolElapsedText(tool: timing, color: tone.secondaryColor)
                    }
                }
            }
            .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(title)
        .contentTransition(.opacity)
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: visualState)
        .toolDetailSheet(
            route: $detailPresentation,
            detent: $detailDetent,
            tool: detailPresentation?.resolve(in: [detailTool])
        )
    }

    private var detailTool: ChatToolPresentation {
        ChatToolPresentation(
            id: timing?.id ?? "",
            title: title,
            subtitle: subtitle,
            request: request,
            response: response,
            content: content,
            fallbackContent: fallbackContent,
            error: error,
            startedAt: timing?.startedAt,
            completedAt: timing?.completedAt,
            durationMs: timing?.durationMs,
            lastProgressAt: timing?.lastProgressAt,
            progressSequence: timing?.progressSequence,
            outputTruncated: timing?.outputTruncated ?? outputTruncated
        )
    }

    private var accessibilityLabel: String {
        let duration = timing?.elapsedMilliseconds().map(ToolTiming.format(milliseconds:))
        return [displayTitle, subtitle, duration].compactMap { $0 }.joined(separator: ", ")
    }
    private var visualState: ChatCompactPillVisualState {
        .init(
            id: timing?.id ?? title,
            title: displayTitle,
            detail: subtitle.lowercased(),
            icon: icon,
            tone: tone,
            material: .glass,
            showsProgress: subtitle == "Running",
            durationMilliseconds: timing?.isRunning == false ? timing?.durationMs : nil
        )
    }
    private var tone: ChatNotificationTone {
        if error { return .error }
        return subtitle == "Running" ? .warning : .accent
    }
    private var displayTitle: String { ToolDetailPresentation.displayTitle(for: title) }
    private var icon: String {
        error ? "exclamationmark.triangle.fill" : ToolDetailPresentation.icon(for: title)
    }
}

struct ToolRunView: View {
    let run: ChatToolRunPresentation
    @State private var detailRoute: ToolDetailRoute?
    @State private var detailDetent: PresentationDetent = .medium
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .leading) {
            if let tool = run.tools.first, run.tools.count == 1 {
                ToolCard(data: tool) { toolID in
                    detailDetent = .medium
                    detailRoute = ToolDetailRoute(toolID: toolID)
                }
                .transition(toolRunTransition)
            } else {
                ToolRunChip(run: run)
                    .transition(toolRunTransition)
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: run.tools.count == 1)
        .toolDetailSheet(
            route: $detailRoute,
            detent: $detailDetent,
            tool: detailRoute?.resolve(in: run.tools)
        )
    }

    private var toolRunTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.985, anchor: .leading))
    }
}

private struct ToolRunChip: View {
    let run: ChatToolRunPresentation
    @State private var showingDetails = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tone: ChatNotificationTone {
        if run.failureCount > 0 { return .error }
        return run.isRunning ? .warning : .accent
    }
    private var surfaceAccent: Color { tone.surfaceColor }

    var body: some View {
        Button { showingDetails = true } label: {
            ChatCompactPillSurface(tone: tone, material: .glass, interactive: true) {
                ChatCompactPillLabel(
                    icon: run.failureCount > 0
                        ? "exclamationmark.triangle.fill" : "square.stack.3d.up",
                    title: run.title,
                    detail: run.status,
                    tone: tone,
                    showsProgress: run.isRunning
                ) {
                    ToolRunElapsedText(run: run, color: tone.secondaryColor)
                }
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .contentTransition(.opacity)
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: visualState)
        .accessibilityLabel(runAccessibilityLabel)
        .sheet(isPresented: $showingDetails) {
            NavigationStack {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(run.tools) { tool in
                            ToolCard(data: tool)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 18)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .defaultScrollAnchor(.top, for: .initialOffset)
                .defaultScrollAnchor(.top, for: .alignment)
                .defaultScrollAnchor(.top, for: .sizeChanges)
                .tronScrollEdgeChrome()
                .tronToolDetailNavigationChrome()
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        TronSheetTitle(title: run.title, accent: surfaceAccent)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button { showingDetails = false } label: {
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

    private var runAccessibilityLabel: String {
        let duration = run.elapsedMilliseconds().map(ToolTiming.format(milliseconds:))
        return [run.title, run.status, duration].compactMap { $0 }.joined(separator: ", ")
    }

    private var visualState: ChatCompactPillVisualState {
        .init(
            id: run.id,
            title: run.title,
            detail: run.status,
            icon: run.failureCount > 0
                ? "exclamationmark.triangle.fill" : "square.stack.3d.up",
            tone: tone,
            material: .glass,
            showsProgress: run.isRunning,
            count: run.tools.count,
            durationMilliseconds: run.isRunning
                ? nil : run.tools.compactMap(\.durationMs).max()
        )
    }
}

private struct ToolElapsedText: View {
    let tool: ChatToolPresentation
    let color: Color

    var body: some View {
        if tool.isRunning {
            TimelineView(.periodic(from: ToolTiming.date(tool.startedAt) ?? .now, by: 0.5)) { context in
                elapsed(at: context.date)
            }
        } else {
            elapsed(at: .now)
        }
    }

    @ViewBuilder private func elapsed(at date: Date) -> some View {
        if let milliseconds = tool.elapsedMilliseconds(at: date) {
            Text(ToolTiming.format(milliseconds: milliseconds))
                .font(TronFont.mono(10, weight: .semibold))
                .foregroundStyle(color)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

private struct ToolRunElapsedText: View {
    let run: ChatToolRunPresentation
    let color: Color

    var body: some View {
        if run.isRunning {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in elapsed(at: context.date) }
        } else {
            elapsed(at: .now)
        }
    }

    @ViewBuilder private func elapsed(at date: Date) -> some View {
        if let milliseconds = run.elapsedMilliseconds(at: date) {
            Text(ToolTiming.format(milliseconds: milliseconds))
                .font(TronFont.mono(10, weight: .semibold))
                .foregroundStyle(color)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

struct ToolDetailRoute: Identifiable, Hashable {
    let toolID: String
    var id: String { toolID }

    func resolve(in tools: [ChatToolPresentation]) -> ChatToolPresentation? {
        tools.first { $0.id == toolID }
    }
}

private struct ToolDetailSheetHost: ViewModifier {
    @Binding var route: ToolDetailRoute?
    @Binding var detent: PresentationDetent
    let tool: ChatToolPresentation?

    func body(content: Content) -> some View {
        content.sheet(item: $route) { _ in
            if let tool {
                let accent: Color = tool.error ? .tronError : .tronEmerald
                NavigationStack {
                    ToolDetailSheet(
                        tool: tool,
                        density: detent == .large ? .expanded : .glance
                    )
                    .tronToolDetailNavigationChrome()
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            TronSheetTitle(
                                title: ToolDetailPresentation.displayTitle(for: tool.title),
                                accent: accent
                            )
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button { route = nil } label: {
                                Image(systemName: "checkmark")
                                    .font(TronTypography.buttonSM)
                                    .foregroundStyle(Color.tronEmerald)
                            }
                            .accessibilityLabel("Done")
                        }
                    }
                }
                .tronTopBlur(.sheet)
                .presentationDetents([.medium, .large], selection: $detent)
                .presentationDragIndicator(.hidden)
                .tronPresentation()
            }
        }
    }
}

private extension View {
    func toolDetailSheet(
        route: Binding<ToolDetailRoute?>,
        detent: Binding<PresentationDetent>,
        tool: ChatToolPresentation?
    ) -> some View {
        modifier(ToolDetailSheetHost(route: route, detent: detent, tool: tool))
    }
}
