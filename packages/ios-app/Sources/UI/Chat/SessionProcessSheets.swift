import Foundation
import SwiftUI

struct SessionProcessesSheet: View {
    let sessionID: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selectedProcess: SessionProcessActivity?
    @State private var detent: PresentationDetent = .medium

    var body: some View {
        NavigationStack {
            Group {
                let sections = SessionProcessProjection.sections(snapshot?.processActivities ?? [])
                if !sections.active.isEmpty || !sections.recent.isEmpty {
                    processList(activities: snapshot?.processActivities ?? [])
                } else {
                    SessionProcessPlaceholder(
                        title: "No active subagents",
                        detail: "Active and recently finished subagents appear here.",
                        icon: "person.2"
                    )
                    .padding(18)
                }
            }
            .tronNavigationTitle("Subagents")
            .toolbar { doneToolbar }
        }
        .tronManagedSheet(
            item: $selectedProcess,
            identity: { "process.\($0.id)" }
        ) { process in
            ReadOnlySubagentSessionSheet(parentSessionID: sessionID, process: process)
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.hidden)
        .tronPresentation()
        .accessibilityIdentifier("session-processes-sheet")
    }

    private var snapshot: SessionSnapshot? { model.authoritativeSnapshot(for: sessionID) }

    @ToolbarContentBuilder
    private var doneToolbar: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button { dismiss() } label: {
                Image(systemName: "checkmark")
                    .font(TronTypography.buttonSM)
                    .foregroundStyle(Color.tronEmerald)
            }
            .accessibilityLabel("Done")
        }
    }

    @ViewBuilder
    private func processList(activities: [SessionProcessActivity]) -> some View {
        let sections = SessionProcessProjection.sections(activities)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if !sections.active.isEmpty {
                    processSection("Active", processes: sections.active)
                }
                if !sections.recent.isEmpty {
                    processSection("Recently finished", processes: sections.recent)
                }
            }
            .padding(18)
        }
        .tronScrollEdgeChrome()
    }

    @ViewBuilder
    private func processSection(_ title: String, processes: [SessionProcessActivity]) -> some View {
        processSectionHeader(title)
        ForEach(processes) { process in
            SessionProcessRow(process: process, surfaceStyle: .glass) {
                selectedProcess = process
            }
        }
    }

    private func processSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(TronTypography.caption)
            .foregroundStyle(Color.tronTextMuted)
            .padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

struct ProcessHistorySheet: View {
    let sessionID: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @State private var store: SessionProcessHistoryStore?
    @State private var generation = 0
    @State private var selectedProcess: SessionProcessActivity?
    @State private var detent: PresentationDetent = .large

    var body: some View {
        NavigationStack {
            Group {
                if let store { history(store) }
                else { TronLoadingState(label: "Preparing subagent history…") }
            }
            .tronNavigationTitle("Subagent History")
            .toolbar { doneToolbar }
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
            store?.loadNext(sessionID: sessionID, presentationGeneration: target.generation)
        }
        .onChange(of: presentationActivity.allowsPresentationPublication) { _, active in
            if !active { store?.suspendPendingWork() }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.hidden)
        .tronPresentation()
        .accessibilityIdentifier("process-history-sheet")
    }

    @ToolbarContentBuilder
    private var doneToolbar: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button { dismiss() } label: {
                Image(systemName: "checkmark")
                    .font(TronTypography.buttonSM)
                    .foregroundStyle(Color.tronEmerald)
            }
            .accessibilityLabel("Done")
        }
    }

    private var mountedProcesses: [SessionProcessActivity] {
        guard let snapshot = model.authoritativeSnapshot(for: sessionID) else { return [] }
        return SessionProcessAdmissionPolicy.admitted(snapshot.processActivities ?? [])
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

                if store.nextCursor != nil {
                    Button("Load More") {
                        store.loadNext(sessionID: sessionID, presentationGeneration: generation)
                    }
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
            SessionProcessRow(process: process, surfaceStyle: .scrollOptimized) {
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

    init(
        title: String,
        detail: String,
        icon: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.detail = detail
        self.icon = icon
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        TronGlassCard(accent: .tronSlate) {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(TronTypography.sans(size: TronTypography.sizeXXL, weight: .semibold))
                    .foregroundStyle(Color.tronTextMuted)
                    .accessibilityHidden(true)
                Text(title)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(Color.tronTextPrimary)
                    .multilineTextAlignment(.center)
                Text(detail)
                    .font(TronTypography.bodySM)
                    .foregroundStyle(Color.tronTextSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(TronActionButtonStyle(expands: false))
                }
            }
            .padding(TronSpacing.xl)
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: action == nil ? .combine : .contain)
        .accessibilityLabel(action == nil ? "\(title). \(detail)" : title)
    }
}

private enum SessionProcessRowSurfaceStyle {
    case glass
    case scrollOptimized
}

private struct SessionProcessRow: View {
    let process: SessionProcessActivity
    let surfaceStyle: SessionProcessRowSurfaceStyle
    let openTranscript: () -> Void

    var body: some View {
        Button(action: openTranscript) { card }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(process.title)
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(accessibilityHint)
    }

    @ViewBuilder
    private var card: some View {
        switch surfaceStyle {
        case .glass:
            TronGlassCard(accent: cardAccent, cornerRadius: 14, interactive: false) {
                rowContent
            }
        case .scrollOptimized:
            rowContent
                .frame(maxWidth: .infinity, alignment: .leading)
                .tronScrollSurface(accent: cardAccent, cornerRadius: 12, tintOpacity: 0.10)
        }
    }

    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Text(process.title)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(Color.tronTextPrimary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let durationMs = process.durationMs {
                    Text(ToolTiming.format(milliseconds: durationMs))
                        .font(TronTypography.secondaryCodeDescription)
                        .foregroundStyle(Color.tronTextSecondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                if tone == .unsuccessful {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(TronTypography.caption2)
                        .foregroundStyle(Color.tronError)
                        .accessibilityHidden(true)
                }
            }

            ToolChipFlowLayout(spacing: 5) {
                if !process.executionMode.displayName.isEmpty {
                    SessionProcessPill(
                        icon: process.executionMode == .asynchronous ? "arrow.triangle.branch" : "arrow.right",
                        text: process.executionMode.displayName
                    )
                }
                if let toolCount = process.toolCount {
                    SessionProcessPill(
                        icon: "wrench.and.screwdriver",
                        text: SessionProcessRowPresentation.countLabel(toolCount, singular: "tool")
                    )
                }
                if let turnCount = process.turnCount {
                    SessionProcessPill(
                        icon: "arrow.triangle.2.circlepath",
                        text: SessionProcessRowPresentation.countLabel(turnCount, singular: "turn")
                    )
                }
            }

            if latestAction != nil || outputPreview != nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text(SessionProcessRowPresentation.activityLabel(for: process.lifecycle.state))
                        .font(TronTypography.caption)
                        .foregroundStyle(cardAccent)
                    if let latestAction {
                        Label(latestAction, systemImage: "hammer")
                            .font(TronTypography.code(size: TronTypography.sizeBody2, weight: .semibold))
                            .foregroundStyle(Color.tronTextSecondary)
                            .lineLimit(1)
                    }
                    if let outputPreview {
                        Text(outputPreview)
                            .font(TronTypography.code(size: TronTypography.sizeBody2, weight: .medium))
                            .foregroundStyle(Color.tronTextSecondary)
                            .lineLimit(SessionProcessRowPresentation.outputLineLimit)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var latestAction: String? {
        SessionProcessRowPresentation.latestAction(for: process)
    }

    private var outputPreview: String? {
        SessionProcessRowPresentation.outputPreview(process.outputTail)
    }

    private var tone: SessionProcessRowTone {
        SessionProcessRowPresentation.tone(for: process.lifecycle.state)
    }

    private var cardAccent: Color {
        switch tone {
        case .inProgress: .tronAmber
        case .succeeded: .tronSuccess
        case .unsuccessful: .tronError
        }
    }

    /// Lifecycle remains explicit for VoiceOver while container color is the
    /// sole visible status treatment.
    private var statusText: String {
        switch process.lifecycle.state {
        case .running: "Live"
        case .completed: "Completed"
        default: process.lifecycle.state.displayName
        }
    }

    private var summaryParts: [String] {
        [
            statusText,
            process.executionMode.displayName.isEmpty ? nil : process.executionMode.displayName,
            process.durationMs.map { ToolTiming.format(milliseconds: $0) },
            latestAction,
            process.toolCount.map { SessionProcessRowPresentation.countLabel($0, singular: "tool") },
            process.turnCount.map { SessionProcessRowPresentation.countLabel($0, singular: "turn") },
        ].compactMap { $0 }
    }

    private var accessibilityValue: String { summaryParts.joined(separator: ", ") }

    private var accessibilityHint: String {
        process.lifecycle.state.isActive
            ? "Opens the live read-only subagent session"
            : "Opens the completed read-only subagent session"
    }
}

private enum SessionProcessPillMetrics {
    static let iconWidth: CGFloat = 16
}

private struct SessionProcessPill: View {
    let icon: String
    let text: String

    var body: some View {
        ChatCompactPillSurface(tone: .neutral, material: .flat) {
            HStack(spacing: ChatCompactPillLayoutPolicy.itemSpacing) {
                ChatCompactPillLeadingIcon(
                    icon: icon,
                    accent: ChatNotificationTone.neutral.primaryColor,
                    iconSize: ChatCompactPillLayoutPolicy.standardIconSize
                )
                .frame(width: SessionProcessPillMetrics.iconWidth)
                Text(text)
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(ChatNotificationTone.neutral.primaryColor)
        }
        .accessibilityHidden(true)
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
    private static let maximumOutputLineCharacters = 180
    private static let absentValues: Set<String> = ["null", "undefined"]

    static func tone(for state: SessionProcessLifecycleState) -> SessionProcessRowTone {
        switch state {
        case .queued, .running, .paused: .inProgress
        case .completed: .succeeded
        case .failed, .stopped, .rejected, .interrupted, .unknown: .unsuccessful
        }
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

    static func outputPreview(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let lines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .suffix(outputLineLimit)
            .map { String($0.suffix(maximumOutputLineCharacters)) }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
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
                            .foregroundStyle(Color.tronEmerald)
                    }
                    .accessibilityLabel("Done")
                }
            }
        }
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
            activities: model.authoritativeSnapshot(for: parentSessionID)?.processActivities ?? []
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
                                accent: .tronAccentText,
                                showsProgress: store.status == .loadingEarlier
                            )
                            Text(store.status == .loadingEarlier
                                ? "Loading earlier…"
                                : "Load earlier messages")
                        }
                        .chatTranscriptPill()
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
        .defaultScrollAnchor(.top, for: .sizeChanges)
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
