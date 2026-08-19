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
    var timing: ChatToolDescriptor? = nil
    var onOpenDetails: ((String) -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var detailPresentation: ToolDetailRoute?
    @State private var detailDetent: PresentationDetent = .medium

    init(
        title: String,
        subtitle: String,
        content: String,
        error: Bool = false,
        request: JSONValue? = nil,
        response: JSONValue? = nil,
        fallbackContent: JSONValue? = nil,
        outputTruncated: Bool = false,
        timing: ChatToolDescriptor? = nil,
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
            timing: data.descriptor,
            onOpenDetails: onOpenDetails
        )
    }

    init(data: ChatToolDescriptor, onOpenDetails: @escaping (String) -> Void) {
        self.init(
            title: data.title,
            subtitle: data.subtitle,
            content: "",
            error: data.error,
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
                    showsProgress: isRunning,
                    iconSize: ChatCompactPillLayoutPolicy.toolIconSize
                ) {
                    if let timing {
                        ToolElapsedText(tool: timing, color: tone.secondaryColor)
                    }
                }
            }
            .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(
            cornerRadius: ChatCompactPillLayoutPolicy.cornerRadius(for: tone),
            style: .continuous
        ))
        .fixedSize(horizontal: false, vertical: true)
        .contentTransition(.interpolate)
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.18),
            value: visualSignature
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(title)
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
            outputTruncated: timing?.outputTruncated ?? outputTruncated,
            extensionOrigin: timing?.extensionOrigin
        )
    }

    private var visualSignature: String {
        "\(title)|\(subtitle)|\(error)"
    }

    private var accessibilityLabel: String {
        let duration = timing?.elapsedMilliseconds().map(ToolTiming.format(milliseconds:))
        return [displayTitle, subtitle, duration].compactMap { $0 }.joined(separator: ", ")
    }
    private var isRunning: Bool {
        subtitle == "Running" || subtitle == "Invocation"
    }

    private var tone: ChatNotificationTone {
        if error { return .error }
        return isRunning ? .warning : .accent
    }
    private var displayTitle: String {
        if timing?.extensionOrigin != nil { return "Extension activity" }
        return ToolDetailPresentation.displayTitle(for: title)
    }
    private var icon: String {
        error ? "exclamationmark.triangle.fill" : ToolDetailPresentation.icon(for: title)
    }
}

struct ToolRunView: View {
    let run: ChatToolRunPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let installationTag: ChatTranscriptProjectionTag
    let resolveDetails: ([String], ChatTranscriptProjectionTag) -> [ChatToolPresentation]?
    @State private var detailRoute: ToolDetailRoute?
    @State private var resolvedDetail: ChatToolPresentation?
    @State private var resolvedGroup: [ChatToolPresentation]?
    @State private var detailDetent: PresentationDetent = .medium

    var body: some View {
        ZStack(alignment: .leading) {
            if let tool = run.tools.first, run.tools.count == 1 {
                ToolCard(data: tool) { toolID in
                    guard let detail = resolveDetails([toolID], installationTag)?.first else { return }
                    detailDetent = .medium
                    resolvedDetail = detail
                    detailRoute = ToolDetailRoute(toolID: toolID)
                }
            } else {
                ToolRunChip(run: run) {
                    guard let details = resolveDetails(detailToolIDs, installationTag) else { return }
                    resolvedGroup = details
                }
            }
        }
        .toolDetailSheet(
            route: $detailRoute,
            detent: $detailDetent,
            tool: resolvedDetail
        )
        .sheet(isPresented: Binding(
            get: { resolvedGroup != nil },
            set: { if !$0 { resolvedGroup = nil } }
        )) {
            if let resolvedGroup {
                ToolRunDetailSheet(run: run, tools: resolvedGroup)
            }
        }
        .onChange(of: installationTag) { _, currentTag in
            refreshResolvedDetails(for: currentTag)
        }
        // Tool status/title changes are updates to one mounted chip, not a
        // remove-and-insert event. Interpolate the glyph/container content
        // locally while the row's explicit entrance transition owns layout.
        .contentTransition(.interpolate)
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.18),
            value: chipVisualSignature
        )
    }

    private var chipVisualSignature: String {
        "\(run.title)|\(run.status)|\(run.failureCount)"
    }

    private var detailToolIDs: [String] {
        run.reverseChronologicalTools.map(\.id)
    }

    private func refreshResolvedDetails(for tag: ChatTranscriptProjectionTag) {
        if let detailRoute {
            guard let detail = resolveDetails([detailRoute.toolID], tag)?.first else {
                self.detailRoute = nil
                resolvedDetail = nil
                resolvedGroup = nil
                return
            }
            resolvedDetail = detail
        }
        if resolvedGroup != nil {
            resolvedGroup = resolveDetails(detailToolIDs, tag)
        }
    }
}

private struct ToolRunChip: View {
    let run: ChatToolRunPresentation
    let onOpenDetails: () -> Void

    private var tone: ChatNotificationTone {
        if run.failureCount > 0 { return .error }
        return run.isRunning ? .warning : .accent
    }
    var body: some View {
        Button(action: onOpenDetails) {
            ChatCompactPillSurface(tone: tone, material: .glass, interactive: true) {
                ChatCompactPillLabel(
                    icon: run.failureCount > 0
                        ? "exclamationmark.triangle.fill" : "square.stack.3d.up",
                    title: run.title,
                    detail: run.status,
                    tone: tone,
                    showsProgress: run.isRunning,
                    iconSize: ChatCompactPillLayoutPolicy.toolIconSize
                ) {
                    ToolRunElapsedText(run: run, color: tone.secondaryColor)
                }
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel(runAccessibilityLabel)
    }

    private var runAccessibilityLabel: String {
        let duration = run.elapsedMilliseconds().map(ToolTiming.format(milliseconds:))
        return [run.title, run.status, duration].compactMap { $0 }.joined(separator: ", ")
    }

}

private struct ToolRunDetailSheet: View {
    let run: ChatToolRunPresentation
    let tools: [ChatToolPresentation]
    @Environment(\.dismiss) private var dismiss

    private var tone: ChatNotificationTone {
        if run.failureCount > 0 { return .error }
        return run.isRunning ? .warning : .accent
    }

    private var orderedTools: [ChatToolPresentation] {
        ChatToolInvocationOrdering.reverseChronological(tools)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(orderedTools) { tool in
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
                    TronSheetTitle(title: run.title, accent: tone.surfaceColor)
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

private struct ToolElapsedClock: Equatable {
    let baselineMilliseconds: Int
    let baselineUptime: TimeInterval

    func milliseconds(at uptime: TimeInterval) -> Int {
        let delta = (uptime - baselineUptime) * 1_000
        guard delta.isFinite, delta > 0 else { return baselineMilliseconds }
        let rounded = delta.rounded()
        guard rounded < Double(Int.max - baselineMilliseconds) else { return Int.max }
        return baselineMilliseconds + Int(rounded)
    }
}

private struct ToolElapsedText: View {
    let tool: ChatToolDescriptor
    let color: Color
    @State private var localClock: ToolElapsedClock?

    private var needsLocalClock: Bool { tool.isRunning && tool.durationMs == nil }

    var body: some View {
        Group {
            if needsLocalClock {
                // Compatibility fallback for older Gateways that do not send a
                // runtime duration sample while a tool is running. The normal
                // path renders Gateway-monotonic samples and never ticks from
                // the device wall clock.
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    elapsed(at: .now)
                }
            } else {
                elapsed(at: .now)
            }
        }
        .onAppear(perform: synchronizeLocalClock)
        .onChange(of: tool.id) { _, _ in synchronizeLocalClock() }
        .onChange(of: tool.startedAt) { _, _ in synchronizeLocalClock() }
        .onChange(of: tool.isRunning) { _, _ in synchronizeLocalClock() }
    }

    @ViewBuilder private func elapsed(at date: Date) -> some View {
        if let milliseconds = milliseconds(at: date) {
            Text(ToolTiming.format(milliseconds: milliseconds))
                .font(TronFont.mono(10, weight: .semibold))
                .foregroundStyle(color)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func milliseconds(at date: Date) -> Int? {
        guard needsLocalClock, let localClock else {
            return tool.elapsedMilliseconds(at: date)
        }
        return localClock.milliseconds(at: ProcessInfo.processInfo.systemUptime)
    }

    private func synchronizeLocalClock() {
        guard needsLocalClock,
              let baseline = tool.elapsedMilliseconds(at: .now) else {
            localClock = nil
            return
        }
        localClock = ToolElapsedClock(
            baselineMilliseconds: baseline,
            baselineUptime: ProcessInfo.processInfo.systemUptime
        )
    }
}

private struct ToolRunElapsedText: View {
    let run: ChatToolRunPresentation
    let color: Color
    @State private var localClocks: [String: ToolElapsedClock] = [:]

    private var needsLocalClocks: Bool {
        run.tools.contains { $0.isRunning && $0.durationMs == nil }
    }

    var body: some View {
        Group {
            if needsLocalClocks {
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    elapsed(at: .now)
                }
            } else {
                elapsed(at: .now)
            }
        }
        .onAppear(perform: synchronizeLocalClocks)
        .onChange(of: run.tools) { _, _ in synchronizeLocalClocks() }
    }

    @ViewBuilder private func elapsed(at date: Date) -> some View {
        if let milliseconds = milliseconds(at: date) {
            Text(ToolTiming.format(milliseconds: milliseconds))
                .font(TronFont.mono(10, weight: .semibold))
                .foregroundStyle(color)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func milliseconds(at date: Date) -> Int? {
        let uptime = ProcessInfo.processInfo.systemUptime
        let values = run.tools.compactMap { tool -> Int? in
            guard tool.isRunning, tool.durationMs == nil,
                  let localClock = localClocks[tool.id] else {
                return tool.elapsedMilliseconds(at: date)
            }
            return localClock.milliseconds(at: uptime)
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(into: 0) { total, value in
            total = total > Int.max - value ? Int.max : total + value
        }
    }

    private func synchronizeLocalClocks() {
        let uptime = ProcessInfo.processInfo.systemUptime
        let now = Date.now
        var updated = localClocks
        let liveIDs = Set(run.tools.map(\.id))
        updated = updated.filter { liveIDs.contains($0.key) }
        for tool in run.tools {
            guard tool.isRunning && tool.durationMs == nil else {
                updated.removeValue(forKey: tool.id)
                continue
            }
            guard updated[tool.id] == nil,
                  let baseline = tool.elapsedMilliseconds(at: now) else { continue }
            updated[tool.id] = ToolElapsedClock(
                baselineMilliseconds: baseline,
                baselineUptime: uptime
            )
        }
        localClocks = updated
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
