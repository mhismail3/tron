import Foundation
import SwiftUI

struct ProcessHistorySheet: View {
    let sessionID: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @State private var store: SessionProcessHistoryStore?
    @State private var generation = 0
    @State private var selectedProcess: SessionProcessActivity?
    @State private var detent: PresentationDetent = .medium

    var body: some View {
        NavigationStack {
            Group {
                if let store { history(store) }
                else { TronLoadingState(label: "Preparing subagent history…", accent: .tronSubagent) }
            }
            // The history header inherits Manage Session; only its content is subagent themed.
            .tronSettingsVisualTheme(accent: .tronSubagent)
            .tronNavigationTitle("Subagent History", accent: .tronSessionTeal)
            .toolbar { doneToolbar }
            .tint(Color.tronSessionTeal)
        }
        .tronManagedSheet(
            item: $selectedProcess,
            identity: { "process-history.\($0.id)" }
        ) { process in
            ReadOnlySubagentSessionSheet(parentSessionID: sessionID, process: process)
        }
        .task(id: "\(model.presentationGeneration(for: sessionID) ?? -1):\(presentationActivity.allowsPresentationPublication)") {
            guard presentationActivity.allowsPresentationPublication,
                  let target = model.presentationTarget(for: sessionID) else { return }
            generation = target.generation
            if store == nil { store = SessionProcessHistoryStore(client: model.client) }
            if store?.sessionID != sessionID
                || store?.presentationGeneration != target.generation {
                store?.reset(sessionID: sessionID, presentationGeneration: target.generation)
            }
            store?.loadInitialPageIfNeeded(sessionID: sessionID, presentationGeneration: target.generation)
        }
        .onChange(of: presentationActivity.allowsPresentationPublication) { _, active in
            if !active { store?.suspendPendingWork() }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.hidden)
        .tronSettingsVisualTheme(accent: .tronSessionTeal)
        .tronPresentation()
        .accessibilityIdentifier("process-history-sheet")
    }

    @ToolbarContentBuilder
    private var doneToolbar: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button { dismiss() } label: {
                Image(systemName: "checkmark")
                    .font(TronTypography.buttonSM)
                    .foregroundStyle(Color.tronSessionTeal)
            }
            .accessibilityLabel("Done")
        }
    }

    private var mountedProcesses: [SessionProcessActivity] {
        SessionProcessAdmissionPolicy.admitted(
            model.sessionProcessPresentation(for: sessionID)?.activities ?? []
        )
    }

    @ViewBuilder
    private func history(_ store: SessionProcessHistoryStore) -> some View {
        let mounted = mountedProcesses
        let sections = SessionProcessProjection.sections(mounted)
        let mountedIDs = Set(mounted.map(\.processId))
        let earlier = store.processes.filter { !mountedIDs.contains($0.processId) }
        let hasMounted = !mounted.isEmpty

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                if !sections.active.isEmpty {
                    section("Active", sections.active)
                }
                if !sections.recent.isEmpty {
                    section("Recently finished", sections.recent)
                }
                if !earlier.isEmpty {
                    section("Earlier", earlier)
                }

                switch store.status {
                case .conflict:
                    SessionProcessPlaceholder(
                        title: "History changed",
                        detail: "Reload to continue from the latest canonical page.",
                        icon: "arrow.triangle.2.circlepath",
                        actionTitle: "Reload History"
                    ) {
                        store.retryReload(sessionID: sessionID, presentationGeneration: generation)
                    }
                case .unavailable:
                    unavailable(
                        "History unavailable",
                        detail: hasMounted
                            ? "Current and recent subagent activity remains available above."
                            : "Update Tron on your Mac to load canonical subagent history.",
                        icon: "externaldrive.badge.questionmark"
                    )
                case .disconnected:
                    unavailable(
                        "Gateway disconnected",
                        detail: "Reconnect to load canonical subagent history.",
                        icon: "wifi.slash"
                    )
                case .failed(let message):
                    unavailable("Unable to load history", detail: message, icon: "exclamationmark.triangle")
                case .idle where earlier.isEmpty && !hasMounted,
                     .loading where earlier.isEmpty && !hasMounted:
                    TronLoadingState(label: "Loading subagent history…")
                case .loaded where earlier.isEmpty && !hasMounted:
                    SessionProcessPlaceholder(
                        title: "No recorded subagents",
                        detail: "Completed subagent sessions will appear here.",
                        icon: "clock.arrow.circlepath"
                    )
                default:
                    EmptyView()
                }

                if store.nextCursor != nil, store.status != .conflict {
                    Button {
                        store.loadNext(sessionID: sessionID, presentationGeneration: generation)
                    } label: {
                        TronInlineActionLabel("Load More", accent: .tronSubagent)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .disabled(store.status == .loading)
                }
            }
            .padding(18)
        }
        .tronScrollEdgeChrome()
    }

    @ViewBuilder
    private func section(_ title: String, _ processes: [SessionProcessActivity]) -> some View {
        Text(title)
            .font(TronTypography.caption)
            .foregroundStyle(Color.tronTextMuted)
            .padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
        ForEach(processes) { process in
            SessionProcessRow(process: process, style: .history) {
                selectedProcess = process
            }
        }
    }

    private func unavailable(_ title: String, detail: String, icon: String) -> some View {
        SessionProcessPlaceholder(title: title, detail: detail, icon: icon)
    }
}

private struct SessionProcessPlaceholder: View {
    let title: String
    let detail: String
    let icon: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        TronGlassCard(accent: .tronSlate) {
            TronPlaceholderState(title: title, detail: detail, icon: icon, accent: .tronSubagent,
                                 actionTitle: actionTitle, action: action)
        }
    }
}

enum SessionProcessRowStyle {
    case activity
    case history

    @MainActor func accent(for state: SessionProcessLifecycleState) -> Color {
        let tone = SessionProcessRowPresentation.tone(for: state)
        // History keeps its neutral terminal theme, but active work must be
        // just as recognizable as it is in the activity sheet.
        if self == .history, tone != .inProgress { return .tronSubagent }
        return switch tone {
        case .inProgress: .tronAmber
        case .succeeded: .tronSuccess
        case .unsuccessful: .tronError
        }
    }
}

struct SessionProcessRow: View {
    let process: SessionProcessActivity
    let style: SessionProcessRowStyle
    var now = Date.now
    var uptime = ProcessInfo.processInfo.systemUptime
    let openTranscript: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button(action: openTranscript) { rowContent }
            // An inherited sheet theme must not replace this row's lifecycle color.
            .tronSettingsVisualTheme(accent: cardAccent)
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            // Label the native Button itself. An extra accessibility grouping
            // creates a non-button proxy and leaves a second actionable child.
            .accessibilityLabel(process.title)
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(accessibilityHint)
            .accessibilityIdentifier("subagent-row-\(process.id)")
    }

    private var heading: some View {
        // Keep large accessibility text readable rather than squeezing the
        // title between trailing status/timing text and the card edge.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        return layout {
            Text(process.title)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(Color.tronTextPrimary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(statusText)
                    .font(TronTypography.secondaryCodeDescription)
                    .foregroundStyle(cardAccent)
                    .lineLimit(1)
                if let elapsedMilliseconds {
                    Text("·")
                        .font(TronTypography.secondaryCodeDescription)
                        .foregroundStyle(Color.tronTextSecondary)
                    elapsedText(elapsedMilliseconds)
                }
            }
            .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: false)
        }
    }

    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading
            if let metadata {
                VStack(alignment: .leading, spacing: 4) {
                    Text("DETAILS")
                        .font(TronTypography.caption)
                        .foregroundStyle(Color.tronTextMuted)
                    Text(metadata)
                        .font(TronTypography.code(size: TronTypography.sizeBodySM, weight: .medium))
                        .foregroundStyle(Color.tronTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if currentAction != nil || outputPreview != nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text(outputLabel)
                        .font(TronTypography.caption)
                        .foregroundStyle(process.lifecycle.state == .running ? cardAccent : Color.tronTextMuted)
                    if let currentAction { activityLabel(currentAction) }
                    if let outputPreview {
                        // Keep the newest logical lines visible even when they wrap;
                        // use the tool cards' bounded tail and truncation treatment.
                        ToolRowPreviewViewport(
                            edge: .top,
                            sourceIsBounded: outputPreview.isBounded || process.outputTruncated,
                            maximumVisibleLines: nil
                        ) {
                            Text(outputPreview.text)
                                .font(TronTypography.code(size: TronTypography.sizeBody2, weight: .medium))
                                .foregroundStyle(Color.tronTextSecondary)
                        }
                    }
                }
                .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tronScrollSurface(accent: cardAccent, cornerRadius: 12, tintOpacity: 0.10)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func elapsedText(_ milliseconds: Int) -> some View {
        Text(SessionProcessRowPresentation.durationText(milliseconds))
            .font(TronTypography.secondaryCodeDescription)
            .foregroundStyle(Color.tronTextSecondary)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var currentAction: String? {
        SessionProcessRowPresentation.latestAction(for: process)
    }

    private func activityLabel(_ text: String) -> some View {
        Label(text, systemImage: "hammer")
            .font(TronTypography.code(size: TronTypography.sizeBody2, weight: .medium))
            .foregroundStyle(Color.tronTextSecondary)
            .lineLimit(1)
    }

    private var metadata: String? {
        let lines = [metadataLine, countsLine].compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private var metadataLine: String? {
        let parts = [
            process.model.map(SessionProcessRowPresentation.modelDisplayName),
            process.thinking.map { "\($0.capitalized) thinking" },
            startedText,
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var countsLine: String? {
        let parts = [
            process.toolCount.map { SessionProcessRowPresentation.countLabel($0, singular: "tool") },
            process.turnCount.map { SessionProcessRowPresentation.countLabel($0, singular: "turn") },
            process.childCount.map { SessionProcessRowPresentation.countLabel($0, singular: "child") },
            process.executionMode.displayName.isEmpty ? nil : process.executionMode.displayName,
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var outputPreview: ToolOutputTailPreview? {
        SessionProcessRowPresentation.outputPreview(process.outputTail)
    }

    private var outputLabel: String {
        switch process.lifecycle.state {
        case .running: "LIVE OUTPUT"
        case .queued, .paused: "LATEST OUTPUT"
        case .failed, .rejected, .interrupted: "ERROR"
        default: "RESULT"
        }
    }

    private var cardAccent: Color { style.accent(for: process.lifecycle.state) }

    /// Explicit lifecycle text accompanies color, including for VoiceOver.
    private var statusText: String {
        switch process.lifecycle.state {
        case .running: "Live"
        case .completed: "Completed"
        default: process.lifecycle.state.displayName
        }
    }

    private var startedText: String? {
        SessionProcessRowPresentation.startedText(for: process, relativeTo: now)
    }

    private var elapsedMilliseconds: Int? {
        SessionProcessRowPresentation.elapsedMilliseconds(for: process, at: now, uptime: uptime)
    }

    private var summaryParts: [String] {
        [
            statusText,
            elapsedMilliseconds.map(SessionProcessRowPresentation.durationText),
            metadataLine,
            countsLine,
            currentAction,
            outputPreview.map { "\(outputLabel): \($0.text)" },
        ].compactMap { $0 }
    }

    private var accessibilityValue: String { summaryParts.joined(separator: ", ") }

    private var accessibilityHint: String {
        process.lifecycle.state.isActive
            ? "Opens the live read-only subagent session"
            : "Opens the completed read-only subagent session"
    }
}

enum SessionProcessRowTone: Equatable, Sendable {
    case inProgress
    case succeeded
    case unsuccessful
}

enum SessionProcessRowPresentation {
    static let outputLineLimit = 3
    private static let maximumActionCharacters = 96
    private static let absentValues: Set<String> = ["null", "undefined"]

    static func tone(for state: SessionProcessLifecycleState) -> SessionProcessRowTone {
        switch state {
        case .queued, .running, .paused: .inProgress
        case .completed: .succeeded
        case .failed, .stopped, .rejected, .interrupted, .unknown: .unsuccessful
        }
    }

    static func durationText(_ milliseconds: Int) -> String {
        guard milliseconds >= 3_600_000 else { return ToolTiming.format(milliseconds: milliseconds) }
        // Keep the live tick visible even after a subagent has run for an hour.
        let seconds = milliseconds / 1_000
        return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m \(seconds % 60)s"
    }

    static func startedText(
        for process: SessionProcessActivity,
        relativeTo now: Date = .now,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String? {
        ToolInvocationTimestamp.text(for: process.startedAt, relativeTo: now, locale: locale, timeZone: timeZone)
            .map { "Started \($0)" }
    }

    static func completedText(
        for process: SessionProcessActivity,
        relativeTo now: Date = .now,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String? {
        guard !process.lifecycle.state.isActive else { return nil }
        return ToolInvocationTimestamp.text(for: process.lifecycle.terminalAt, relativeTo: now, locale: locale, timeZone: timeZone)
    }

    static func elapsedMilliseconds(
        for process: SessionProcessActivity,
        at now: Date = .now,
        uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Int? {
        if process.lifecycle.state == .running {
            return ToolTiming.runningDuration(
                sampledDuration: process.durationMs,
                sampleAnchor: process.durationSampleAnchor,
                startedAt: process.startedAt,
                at: now,
                uptime: uptime
            )
        }
        // Queued/paused samples and terminal results never accrue local runtime.
        return ToolTiming.resolvedDuration(
            startedAt: process.startedAt,
            completedAt: process.lifecycle.terminalAt,
            fallback: process.durationMs
        )
    }

    static func countLabel(_ count: Int, singular: String) -> String {
        "\(count) \(count == 1 ? singular : "\(singular)s")"
    }

    // Paused is a canonical resumable state and must not be labeled live.
    static func activityLabel(for state: SessionProcessLifecycleState) -> String {
        switch state {
        case .queued: "QUEUED"
        case .running: "LIVE ACTIVITY"
        case .paused: "PAUSED"
        default: "RECENT ACTIVITY"
        }
    }

    static func modelDisplayName(_ model: String) -> String {
        let value = model.split(separator: "/").last.map(String.init) ?? model
        return value
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map {
                if $0.lowercased() == "gpt" { return "GPT" }
                return $0.first?.isNumber == true ? String($0).uppercased() : $0.prefix(1).uppercased() + $0.dropFirst()
            }
            .joined(separator: " ")
    }

    static func latestAction(for process: SessionProcessActivity) -> String? {
        let tool = normalized(process.currentTool)
        let path = normalized(process.currentPathBasename)
        switch (tool, path) {
        case let (tool?, path?): return "\(tool) · \(path)"
        case let (tool?, nil): return tool
        case let (nil, path?): return path
        case (nil, nil): return nil
        }
    }

    static func outputPreview(_ raw: String?) -> ToolOutputTailPreview? {
        raw.flatMap { ToolOutputTailPreview.make($0, maximumLines: outputLineLimit) }
    }

    private static func normalized(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              !absentValues.contains(value.lowercased()) else { return nil }
        return String(value.prefix(maximumActionCharacters))
    }
}

enum ReadOnlySubagentStopControlPolicy {
    static func isVisible(
        lifecycleState: SessionProcessLifecycleState,
        supportsAbort: Bool
    ) -> Bool {
        lifecycleState.isActive && supportsAbort
    }

    static func isEnabled(
        lifecycleState: SessionProcessLifecycleState,
        hasAbortAuthority: Bool,
        supportsAbort: Bool,
        isConnected: Bool,
        stopRequested: Bool
    ) -> Bool {
        lifecycleState.isActive
            && hasAbortAuthority
            && supportsAbort
            && isConnected
            && !stopRequested
    }
}

private struct ReadOnlySubagentOpenIdentity: Hashable {
    let presentationGeneration: Int?
    let isConnected: Bool
}

struct ReadOnlySubagentSessionSheet: View {
    let parentSessionID: String
    let process: SessionProcessActivity

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var store: ReadOnlySubagentSessionStore?
    @State private var scrollPosition = ScrollPosition(idType: String.self)
    @State private var isNearTail = true
    @State private var detent: PresentationDetent = .medium
    @State private var stopRequested = false

    private let tailID = "read-only-subagent-tail"

    var body: some View {
        NavigationStack {
            Group {
                if let store { content(store) }
                else { TronLoadingState(label: "Preparing subagent session…") }
            }
            .tronNavigationTitle(process.title)
            .toolbar {
                if showsStopControl {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: requestStop) {
                            Image(systemName: "stop.fill")
                                .font(TronTypography.buttonSM)
                                .foregroundStyle(canStop ? Color.tronError : Color.tronTextMuted)
                                .animation(
                                    reduceMotion ? nil : .easeOut(duration: 0.2),
                                    value: canStop
                                )
                        }
                        .disabled(!canStop)
                        .accessibilityLabel("Stop Subagent")
                        .accessibilityHint("Stops this subagent execution")
                        .accessibilityIdentifier("stop-subagent-button")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                            .font(TronTypography.buttonSM)
                            .foregroundStyle(Color.tronSubagent)
                    }
                    .accessibilityLabel("Done")
                }
            }
        }
        .tronSettingsVisualTheme(accent: .tronSubagent)
        .task(id: openIdentity) {
            guard model.connectionState == .connected,
                  let target = model.presentationTarget(for: parentSessionID) else { return }
            if store == nil { store = ReadOnlySubagentSessionStore(client: model.client) }
            store?.open(
                parentSessionID: parentSessionID,
                processID: process.processId,
                presentationGeneration: target.generation,
                activity: mountedActivity ?? process
            )
        }
        .onChange(of: model.processTranscriptInvalidation) { _, change in
            guard let change else { return }
            store?.invalidate(change)
        }
        .onChange(of: mountedActivity) { _, activity in
            store?.updateLiveActivity(activity)
        }
        .onDisappear { store?.close() }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.hidden)
        .tronPresentation()
        .accessibilityIdentifier("read-only-subagent-session-sheet")
    }

    private var openIdentity: ReadOnlySubagentOpenIdentity {
        ReadOnlySubagentOpenIdentity(
            presentationGeneration: model.presentationGeneration(for: parentSessionID),
            isConnected: model.connectionState == .connected
        )
    }

    private var mountedActivity: SessionProcessActivity? {
        SessionProcessProjection.mountedActivity(
            selected: process,
            activities: model.sessionProcessPresentation(for: parentSessionID)?.activities ?? []
        )
    }

    private var currentActivity: SessionProcessActivity {
        mountedActivity ?? store?.liveActivity ?? process
    }

    private var supportsStop: Bool {
        model.gatewayInfo?.capabilities.contains(
            SessionProcessAdmissionPolicy.transcriptAbortCapability
        ) == true
    }

    private var hasAbortAuthority: Bool {
        store?.leaseID != nil
            && store?.canAbort == true
            && store?.liveActivity?.lifecycle.state.isActive == true
    }

    private var showsStopControl: Bool {
        ReadOnlySubagentStopControlPolicy.isVisible(
            lifecycleState: currentActivity.lifecycle.state,
            supportsAbort: supportsStop
        )
    }

    private var canStop: Bool {
        ReadOnlySubagentStopControlPolicy.isEnabled(
            lifecycleState: currentActivity.lifecycle.state,
            hasAbortAuthority: hasAbortAuthority,
            supportsAbort: supportsStop,
            isConnected: model.connectionState == .connected,
            stopRequested: stopRequested
        )
    }

    private func requestStop() {
        guard canStop, let leaseID = store?.leaseID else { return }
        stopRequested = true
        Task {
            let delivered = await model.abortSubagent(leaseID: leaseID)
            if !delivered { stopRequested = false }
        }
    }

    @ViewBuilder
    private func content(_ store: ReadOnlySubagentSessionStore) -> some View {
        switch store.status {
        case .idle, .opening:
            TronLoadingState(label: "Opening read-only session…")
        case .waiting:
            SessionProcessPlaceholder(
                title: "Session starting",
                detail: "Waiting for this live subagent to publish its canonical session.",
                icon: "ellipsis.message"
            )
            .padding(18)
        case .unavailable:
            SessionProcessPlaceholder(
                title: "Session unavailable",
                detail: "This subagent did not persist an authorized canonical session.",
                icon: "doc.text.magnifyingglass"
            )
            .padding(18)
        case .failed(let message):
            SessionProcessPlaceholder(
                title: "Unable to load session",
                detail: message,
                icon: "exclamationmark.triangle"
            )
            .padding(18)
        case .open, .loadingEarlier, .reconnecting:
            transcript(store)
        }
    }

    private func transcript(_ store: ReadOnlySubagentSessionStore) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if store.transcriptStart > 0 {
                    Button {
                        store.loadEarlier()
                    } label: {
                        HStack(spacing: ChatCompactPillLayoutPolicy.itemSpacing) {
                            ChatCompactPillLeadingIcon(
                                icon: "arrow.up",
                                accent: ChatNotificationTone.subagent.primaryColor,
                                showsProgress: store.status == .loadingEarlier
                            )
                            Text(store.status == .loadingEarlier
                                ? "Loading earlier…"
                                : "Load earlier messages")
                        }
                        .chatTranscriptPill(tone: .subagent)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.bottom, ChatTranscriptLayoutConstants.rowSpacing)
                    .disabled(!store.canLoadEarlier)
                    .accessibilityLabel(store.status == .loadingEarlier
                        ? "Loading earlier messages"
                        : "Load earlier messages")
                }
                if store.presentation.timeline.items.isEmpty {
                    let isActive = store.liveActivity?.lifecycle.state.isActive == true
                    SessionProcessPlaceholder(
                        title: isActive ? "Transcript starting" : "No transcript recorded",
                        detail: isActive
                            ? "Canonical messages will appear here as this subagent works."
                            : "This completed subagent session contains no presentable messages.",
                        icon: isActive ? "ellipsis.message" : "doc.text.magnifyingglass"
                    )
                    .padding(.bottom, ChatTranscriptLayoutConstants.rowSpacing)
                } else {
                    ForEach(store.presentation.timeline.items) { item in
                        ReadOnlySubagentTranscriptRow(
                            item: item,
                            preparedText: store.preparedText.slice(for: item),
                            toolPayloads: store.presentation.toolPayloads
                        )
                        // Transcript/tool semantics are not navigation chrome.
                        .environment(\.tronSettingsVisualTheme, nil)
                        .padding(.bottom, ChatTranscriptLayoutConstants.rowSpacing)
                        .id(item.id)
                    }
                }
                if store.status == .reconnecting {
                    TronLoadingState(label: "Updating canonical session…")
                        .padding(.bottom, ChatTranscriptLayoutConstants.rowSpacing)
                }
                Color.clear
                    .frame(height: ChatTranscriptLayoutConstants.tailAffordanceHeight)
                    .id(tailID)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .scrollTargetLayout()
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.top, for: .alignment)
        // Native tail anchoring must track lazy Markdown measurement and sheet
        // resizing. A top-owned size change can strand the opening offset below
        // the actual content, leaving a blank viewport until the user drags it.
        .defaultScrollAnchor(isNearTail ? .bottom : .top, for: .sizeChanges)
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.containerSize.height
                >= geometry.contentSize.height - 72
        } action: { _, nearTail in
            isNearTail = nearTail
        }
        .environment(\.canonicalResourceSessionID, store.childSessionRef)
        .onChange(of: store.transcriptTotal) { previous, current in
            guard current > previous, isNearTail else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                scrollPosition.scrollTo(id: tailID, anchor: .bottom)
            }
        }
        .tronScrollEdgeChrome()
    }

}

private struct ReadOnlySubagentTranscriptRow: View, Equatable {
    let item: ChatTranscriptRenderItem
    let preparedText: ChatTextPreparationSnapshot
    let toolPayloads: ChatToolPayloadIndex

    var body: some View {
        Group {
            switch item {
            case .transcript(let transcript):
                TranscriptRow(
                    item: transcript,
                    rendersToolCalls: false,
                    preparedText: preparedText
                )
            case .message(let message):
                TranscriptRow(
                    item: message.item,
                    streaming: false,
                    rendersToolCalls: false,
                    projectedMessageParts: message.parts,
                    preparedText: preparedText,
                    showsMessageFooter: message.showsFooter
                )
            case .toolRun(let run):
                ReadOnlyToolRunView(
                    run: run,
                    tools: run.tools.compactMap(toolPayloads.resolving)
                )
            case .notification(let notification):
                ChatNotificationView(presentation: notification)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
    }

    private var alignment: Alignment {
        switch item {
        case .transcript(let transcript):
            transcript.role == .user ? .trailing : .leading
        case .message(let message):
            message.item.role == .user ? .trailing : .leading
        case .toolRun, .notification:
            .leading
        }
    }
}
