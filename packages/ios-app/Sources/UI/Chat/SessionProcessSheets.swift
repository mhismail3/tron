import SwiftUI

private enum SessionProcessDestination: Hashable {
    case transcript(SessionProcessActivity)
}

struct SessionProcessesSheet: View {
    let sessionID: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                let sections = SessionProcessProjection.sections(snapshot?.processActivities ?? [])
                if !sections.active.isEmpty || !sections.recent.isEmpty {
                    processList(activities: snapshot?.processActivities ?? [])
                } else {
                    ContentUnavailableView(
                        "No active subagents",
                        systemImage: "person.2",
                        description: Text("Active and recently finished subagents appear here.")
                    )
                }
            }
            .tronNavigationTitle("Subagents")
            .toolbar { doneToolbar }
            .navigationDestination(for: SessionProcessDestination.self) { destination in
                processDestination(destination)
            }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
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
            SessionProcessRow(process: process, accent: accent)
        }
    }

    private func processSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(TronTypography.caption)
            .foregroundStyle(Color.tronTextMuted)
            .padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func processDestination(_ destination: SessionProcessDestination) -> some View {
        switch destination {
        case .transcript(let process):
            ReadOnlySubagentSessionSheet(parentSessionID: sessionID, process: process)
        }
    }
}

struct ProcessHistorySheet: View {
    let sessionID: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var store: SessionProcessHistoryStore?
    @State private var generation = 0

    var body: some View {
        NavigationStack {
            Group {
                if let store { history(store) }
                else { TronLoadingState(label: "Preparing subagent history…") }
            }
            .tronNavigationTitle("Subagent History")
            .toolbar { doneToolbar }
            .navigationDestination(for: SessionProcessDestination.self) { destination in
                switch destination {
                case .transcript(let process): ReadOnlySubagentSessionSheet(parentSessionID: sessionID, process: process)
                }
            }
        }
        .task(id: model.presentationGeneration(for: sessionID)) {
            guard let target = model.presentationTarget(for: sessionID) else { return }
            generation = target.generation
            if store == nil { store = SessionProcessHistoryStore(client: model.client) }
            store?.reset(sessionID: sessionID, presentationGeneration: target.generation)
            store?.loadNext(sessionID: sessionID, presentationGeneration: target.generation)
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
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
                    ContentUnavailableView(
                        "History changed",
                        systemImage: "arrow.triangle.2.circlepath",
                        description: Text("Reload to continue from the latest canonical page.")
                    )
                    Button("Reload history") {
                        store.retryReload(sessionID: sessionID, presentationGeneration: generation)
                    }
                    .frame(maxWidth: .infinity)
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
                    ContentUnavailableView(
                        "No recorded subagents",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Completed subagent sessions will appear here.")
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
            SessionProcessRow(process: process, accent: accent)
        }
    }

    private func unavailable(_ title: String, detail: String, icon: String) -> some View {
        ContentUnavailableView(title, systemImage: icon, description: Text(detail))
    }
}

private struct SessionProcessRow: View {
    let process: SessionProcessActivity
    let accent: Color

    var body: some View {
        Group {
            if process.childSessionRef != nil {
                NavigationLink(value: SessionProcessDestination.transcript(process)) { rowContent }
                    .buttonStyle(.plain)
            } else {
                rowContent
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowTitle)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(accessibilityHint)
    }

    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(accent)
                    .frame(width: 22, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    Text(rowTitle)
                        .font(TronTypography.body)
                        .foregroundStyle(Color.tronTextPrimary)
                        .lineLimit(2)
                    Text(summary)
                        .font(TronTypography.caption)
                        .foregroundStyle(Color.tronTextMuted)
                }
                Spacer(minLength: 6)
            }
            if let output = process.outputTail, !output.isEmpty {
                Text(output)
                    .font(TronTypography.code(size: 12, weight: .semibold))
                    .foregroundStyle(Color.tronTextSecondary)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityHidden(true)
                if process.outputTruncated {
                    Text("Showing recent output")
                        .font(TronTypography.caption)
                        .foregroundStyle(Color.tronTextMuted)
                        .accessibilityHidden(true)
                }
            } else if process.childSessionRef == nil {
                Text(process.lifecycle.state.isActive ? "Session preparing" : "Session unavailable")
                    .font(TronTypography.caption)
                    .foregroundStyle(Color.tronTextMuted)
                    .accessibilityHidden(true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tronScrollSurface(accent: accent, tintOpacity: 0.08)
    }

    private var rowTitle: String { process.title }

    private var icon: String {
        if process.lifecycle.state.isProblem { return "exclamationmark.circle" }
        return process.lifecycle.state.isActive ? "circle.dotted" : "checkmark.circle"
    }

    private var summaryParts: [String] {
        [
            process.lifecycle.state.displayName,
            process.executionMode.displayName.isEmpty ? nil : process.executionMode.displayName,
            process.durationMs.map { ToolTiming.format(milliseconds: $0) },
            process.currentTool,
            process.toolCount.map { "\($0) tools" },
            process.turnCount.map { "\($0) turns" },
        ].compactMap { $0 }
    }

    private var summary: String { summaryParts.joined(separator: " · ") }
    private var accessibilityValue: String { summaryParts.joined(separator: ", ") }

    private var accessibilityHint: String {
        if process.childSessionRef != nil { return "Opens the read-only subagent session" }
        return process.lifecycle.state.isActive ? "Session is preparing" : "Session is unavailable"
    }
}

struct ReadOnlySubagentSessionSheet: View {
    let parentSessionID: String
    let process: SessionProcessActivity

    @Environment(AppModel.self) private var model
    @State private var store: ReadOnlySubagentSessionStore?
    @State private var scrollPosition = ScrollPosition(idType: String.self)
    @State private var isNearTail = true

    private let tailID = "read-only-subagent-tail"

    var body: some View {
        Group {
            if let store { content(store) }
            else { TronLoadingState(label: "Preparing subagent session…") }
        }
        .tronNavigationTitle(process.title)
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
            ContentUnavailableView(
                "Session unavailable",
                systemImage: "doc.text.magnifyingglass",
                description: Text("This subagent did not persist an authorized canonical session.")
            )
        case .failed(let message):
            ContentUnavailableView(
                "Unable to load session",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
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
                ForEach(store.items) { item in
                    TranscriptRow(item: item)
                        .id(item.id)
                        .frame(maxWidth: .infinity, alignment: item.role == .user ? .trailing : .leading)
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
                Text(tool).font(TronTypography.code(size: 12, weight: .semibold))
            }
            if let output = activity.outputTail, !output.isEmpty {
                Text(output)
                    .font(TronTypography.code(size: 12, weight: .semibold))
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tronScrollSurface(accent: .tronEmerald, tintOpacity: 0.07)
    }
}
