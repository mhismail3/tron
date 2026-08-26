import SwiftUI

struct SessionProcessesSheet: View {
    let sessionID: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selectedProcess: SessionProcessActivity?
    @State private var detent: PresentationDetent = .large

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
        .sheet(item: $selectedProcess) { process in
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
            LazyVStack(alignment: .leading, spacing: 10) {
                if !sections.active.isEmpty {
                    processSection("Active", processes: sections.active, accent: .tronEmerald)
                }
                if !sections.recent.isEmpty {
                    processSection("Recently finished", processes: sections.recent, accent: .tronAmber)
                }
            }
            .padding(18)
        }
        .tronScrollEdgeChrome()
    }

    @ViewBuilder
    private func processSection(_ title: String, processes: [SessionProcessActivity], accent: Color) -> some View {
        processSectionHeader(title)
        ForEach(processes) { process in
            SessionProcessRow(process: process, accent: accent) {
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
        .sheet(item: $selectedProcess) { process in
            ReadOnlySubagentSessionSheet(parentSessionID: sessionID, process: process)
        }
        .task(id: model.presentationGeneration(for: sessionID)) {
            guard let target = model.presentationTarget(for: sessionID) else { return }
            generation = target.generation
            if store == nil { store = SessionProcessHistoryStore(client: model.client) }
            store?.reset(sessionID: sessionID, presentationGeneration: target.generation)
            store?.loadNext(sessionID: sessionID, presentationGeneration: target.generation)
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
            LazyVStack(alignment: .leading, spacing: 10) {
                if !sections.active.isEmpty {
                    section("Active", sections.active, accent: .tronEmerald)
                }
                if !sections.recent.isEmpty {
                    section("Recently finished", sections.recent, accent: .tronAmber)
                }
                if !earlier.isEmpty {
                    section("Earlier", earlier, accent: .tronCyan)
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
                case .idle, .loading where earlier.isEmpty && !hasMounted:
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
    private func section(_ title: String, _ processes: [SessionProcessActivity], accent: Color) -> some View {
        Text(title)
            .font(TronTypography.caption)
            .foregroundStyle(Color.tronTextMuted)
            .padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
        ForEach(processes) { process in
            SessionProcessRow(process: process, accent: accent) {
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

private struct SessionProcessRow: View {
    let process: SessionProcessActivity
    let accent: Color
    let openTranscript: () -> Void

    var body: some View {
        Group {
            if process.childSessionRef != nil {
                Button(action: openTranscript) { card }
                    .buttonStyle(.plain)
            } else {
                card
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(process.title)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(accessibilityHint)
    }

    private var card: some View {
        TronGlassCard(accent: cardAccent, cornerRadius: 18, interactive: process.childSessionRef != nil) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    ZStack(alignment: .bottomTrailing) {
                        ProcessActivityOrb(mode: orbMode, size: 36)
                            .frame(width: 40, height: 40)
                        if process.lifecycle.state.isProblem {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .semibold))
                                .foregroundStyle(Color.tronError)
                                .background(Color.tronSurfaceElevated, in: Circle())
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(process.title)
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                            .foregroundStyle(Color.tronTextPrimary)
                            .lineLimit(2)
                        Text(subtitle)
                            .font(TronTypography.caption)
                            .foregroundStyle(process.lifecycle.state.isActive ? cardAccent : Color.tronTextMuted)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    statusPill
                }

                ToolChipFlowLayout(spacing: 7) {
                    if !process.executionMode.displayName.isEmpty {
                        ToolStaticChip(
                            icon: process.executionMode == .asynchronous ? "arrow.triangle.branch" : "arrow.right",
                            text: process.executionMode.displayName,
                            accent: .tronTextSecondary
                        )
                    }
                    if let durationMs = process.durationMs {
                        ToolStaticChip(
                            icon: "clock",
                            text: ToolTiming.format(milliseconds: durationMs),
                            accent: .tronTextSecondary
                        )
                    }
                    if let currentTool = process.currentTool {
                        ToolStaticChip(
                            icon: "hammer",
                            text: currentTool,
                            accent: process.lifecycle.state.isActive ? .tronEmerald : .tronTextSecondary
                        )
                    }
                    if let path = process.currentPathBasename {
                        ToolStaticChip(icon: "doc", text: path, accent: .tronTextSecondary)
                    }
                    if let toolCount = process.toolCount {
                        ToolStaticChip(icon: "wrench.and.screwdriver", text: "\(toolCount) tools", accent: .tronTextSecondary)
                    }
                    if let turnCount = process.turnCount {
                        ToolStaticChip(icon: "arrow.triangle.2.circlepath", text: "\(turnCount) turns", accent: .tronTextSecondary)
                    }
                }

                if let output = process.outputTail, !output.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(process.lifecycle.state.isActive ? "LIVE OUTPUT" : "RECENT OUTPUT")
                            .font(TronTypography.sheetSectionHeader)
                            .foregroundStyle(process.lifecycle.state.isActive ? Color.tronEmerald : Color.tronTextMuted)
                        Text(output)
                            .font(TronTypography.code(size: 12, weight: .semibold))
                            .foregroundStyle(Color.tronTextSecondary)
                            .lineLimit(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if process.outputTruncated {
                            Label("Showing recent output", systemImage: "text.badge.minus")
                                .font(TronTypography.caption)
                                .foregroundStyle(Color.tronTextMuted)
                        }
                    }
                    .accessibilityHidden(true)
                } else if process.childSessionRef == nil {
                    Text(process.lifecycle.state.isActive ? "Canonical session is preparing…" : "Canonical session unavailable")
                        .font(TronTypography.caption)
                        .foregroundStyle(Color.tronTextMuted)
                        .accessibilityHidden(true)
                }
            }
            .padding(14)
        }
    }

    private var statusPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(cardAccent)
                .frame(width: 6, height: 6)
            Text(statusText)
                .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .semibold))
        }
        .foregroundStyle(cardAccent)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .glassEffect(.regular.tint(cardAccent.opacity(0.12)), in: Capsule())
        .accessibilityHidden(true)
    }

    private var orbMode: ProcessActivityOrbMode {
        process.lifecycle.state.isActive ? .solving : .thinking
    }

    private var cardAccent: Color {
        if process.lifecycle.state.isProblem { return .tronError }
        return process.lifecycle.state.isActive ? .tronEmerald : accent
    }

    private var statusText: String {
        if process.lifecycle.state.isActive { return "Live" }
        return process.lifecycle.state == .completed ? "Completed" : process.lifecycle.state.displayName
    }

    private var subtitle: String {
        if process.lifecycle.state.isActive {
            if let currentTool = process.currentTool { return "Working in \(currentTool) · updating live" }
            return "Working · updates appear live"
        }
        return process.lifecycle.state.isProblem ? "Finished with a problem" : "Canonical transcript ready"
    }

    private var summaryParts: [String] {
        [
            statusText,
            process.executionMode.displayName.isEmpty ? nil : process.executionMode.displayName,
            process.durationMs.map { ToolTiming.format(milliseconds: $0) },
            process.currentTool,
            process.currentPathBasename,
            process.toolCount.map { "\($0) tools" },
            process.turnCount.map { "\($0) turns" },
        ].compactMap { $0 }
    }

    private var accessibilityValue: String { summaryParts.joined(separator: ", ") }

    private var accessibilityHint: String {
        if process.childSessionRef != nil { return "Opens the read-only subagent session in a bottom sheet" }
        return process.lifecycle.state.isActive ? "Session is preparing" : "Session is unavailable"
    }
}

struct ReadOnlySubagentSessionSheet: View {
    let parentSessionID: String
    let process: SessionProcessActivity

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var store: ReadOnlySubagentSessionStore?
    @State private var scrollPosition = ScrollPosition(idType: String.self)
    @State private var isNearTail = true
    @State private var detent: PresentationDetent = .large

    private let tailID = "read-only-subagent-tail"

    var body: some View {
        NavigationStack {
            Group {
                if let store { content(store) }
                else { TronLoadingState(label: "Preparing subagent session…") }
            }
            .tronNavigationTitle(process.title)
            .toolbar {
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
        .task(id: model.presentationGeneration(for: parentSessionID)) {
            guard let target = model.presentationTarget(for: parentSessionID) else { return }
            if store == nil { store = ReadOnlySubagentSessionStore(client: model.client) }
            store?.open(
                parentSessionID: parentSessionID,
                processID: process.processId,
                presentationGeneration: target.generation
            )
            store?.updateLiveActivity(mountedActivity)
        }
        .onChange(of: model.processTranscriptInvalidation) { _, change in
            guard let change else { return }
            store?.invalidate(change)
        }
        .onChange(of: mountedActivity?.lifecycle.sequence) { _, _ in
            store?.updateLiveActivity(mountedActivity)
        }
        .onDisappear { store?.close() }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.hidden)
        .tronPresentation()
        .accessibilityIdentifier("read-only-subagent-session-sheet")
    }

    private var mountedActivity: SessionProcessActivity? {
        model.authoritativeSnapshot(for: parentSessionID)?.processActivities?
            .first(where: { $0.processId == process.processId })
    }

    @ViewBuilder
    private func content(_ store: ReadOnlySubagentSessionStore) -> some View {
        switch store.status {
        case .idle, .opening:
            TronLoadingState(label: "Opening read-only session…")
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
            LazyVStack(alignment: .leading, spacing: 16) {
                if store.transcriptStart > 0 {
                    Button(store.status == .loadingEarlier ? "Loading…" : "Load Earlier Messages") {
                        store.loadEarlier()
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(!store.canLoadEarlier)
                }
                if store.items.isEmpty {
                    let isActive = store.liveActivity?.lifecycle.state.isActive == true
                    SessionProcessPlaceholder(
                        title: isActive ? "Transcript starting" : "No transcript recorded",
                        detail: isActive
                            ? "Canonical messages will appear here as this subagent works."
                            : "This completed subagent session contains no presentable messages.",
                        icon: isActive ? "ellipsis.message" : "doc.text.magnifyingglass"
                    )
                } else {
                    ForEach(store.items) { item in
                        TranscriptRow(item: item)
                            .id(item.id)
                            .frame(maxWidth: .infinity, alignment: item.role == .user ? .trailing : .leading)
                    }
                }
                if store.status == .reconnecting {
                    TronLoadingState(label: "Updating canonical session…")
                }
                if let live = store.liveActivity,
                   live.lifecycle.state.isActive,
                   live.currentTool != nil || live.outputTail != nil {
                    liveActivity(live)
                }
                Color.clear.frame(height: 1).id(tailID)
            }
            .padding(18)
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

    private func liveActivity(_ activity: SessionProcessActivity) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Live activity", systemImage: "waveform.path")
                .font(TronTypography.caption)
                .foregroundStyle(Color.tronEmerald)
                .accessibilityAddTraits(.isHeader)
            if let tool = activity.currentTool {
                ToolStaticChip(icon: "hammer", text: tool, accent: .tronEmerald)
            }
            if let output = activity.outputTail, !output.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("CURRENT OUTPUT")
                        .font(TronTypography.sheetSectionHeader)
                        .foregroundStyle(Color.tronTextMuted)
                    Text(output)
                        .font(TronTypography.code(size: 12, weight: .semibold))
                        .foregroundStyle(Color.tronTextSecondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tronScrollSurface(accent: .tronEmerald, tintOpacity: 0.07)
    }
}
