import SwiftUI
import TronMobileCore

/// Shared by canonical chat chips, push review and Changes. A dismissal never
/// decides; only a toolbar tap submits the displayed request's exact digest.
@MainActor
struct SettingsApprovalSheet: View {
    let selection: SettingsApprovalSelection
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tronPresentationActivity) private var activity
    @PresentationState private var state: ContentState = .loading
    @PresentationState private var technical = false
    @PresentationState private var selectedReference: SettingsApprovalReference?
    @PresentationState private var deciding = false
    @PresentationState private var loadGeneration = 0

    private enum ContentState {
        case loading
        case pending([SettingsApprovalRequest])
        case outcomes([SettingsApprovalOutcome])
        case history([SettingsChangeHistoryEntry])
        case unavailable(String)
    }
    private struct LoadID: Hashable {
        let selection: String
        let selectedReference: SettingsApprovalReference?
        let revision: Int
        let foreground: Int
        let identity: KnowledgePresentationIdentity
    }
    private var pendingRequest: SettingsApprovalRequest? {
        guard case .pending(let requests) = state, requests.count == 1 else { return nil }
        return requests[0]
    }
    private var isPending: Bool {
        if case .pending = state { return true }
        return false
    }
    private var accent: Color {
        let statuses: Set<String>
        switch state {
        case .outcomes(let requests): statuses = Set(requests.map(\.status))
        case .history(let entries): statuses = Set(entries.map(\.status))
        default: return .tronAmber
        }
        if statuses.contains("failed") { return .tronError }
        return statuses == ["approved"] ? .tronSuccess : .tronSlate
    }
    private var title: String {
        if technical { return "Technical details" }
        switch state {
        case .pending: return "Approve"
        case .outcomes(let requests): return Set(requests.map(\.status)).count == 1 ? requests[0].title : "Outcomes"
        case .history(let entries): return Set(entries.map(\.status)).count == 1 ? outcomeTitle(entries.first?.status) : "Outcomes"
        default: return "Approval"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch state {
                    case .loading:
                        TronLoadingState(label: "Loading request…")
                    case .pending(let requests):
                        if requests.count == 1, let request = requests.first {
                            pendingDetails(request)
                        } else {
                            TronSettingsCaption("Choose a request to review. Nothing is decided until you tap Approve or Decline.")
                            ForEach(requests) { request in
                                Button { selectedReference = SettingsApprovalReference(requestID: request.requestId, changeIDs: request.changes.map(\.changeId)) } label: { SettingsApprovalRequestSummary(request: request) }
                                    .buttonStyle(.plain)
                            }
                        }
                    case .outcomes(let requests):
                        ForEach(requests) { outcomeDetails($0) }
                        if technical, case .outcomes(let message) = selection {
                            TronTechnicalJSONRow(value: message.raw, title: "Canonical outcome", sheetTitle: "Canonical outcome")
                        }
                    case .history(let entries):
                        ForEach(entries) { entry in historyDetails(entry) }
                    case .unavailable(let message):
                        TronSettingsNotice(message: message, title: "Status unavailable", retry: { Task { await load(force: true) } })
                    }
                }.padding(18)
            }
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { technical.toggle() } label: {
                        Image(systemName: technical ? "chevron.left" : "info.circle")
                            .font(TronTypography.buttonSM).tronToolbarAction(accent: accent)
                    }.accessibilityLabel(technical ? "Back" : "Technical details")
                }
                ToolbarItem(placement: .principal) { TronSheetTitle(title: title, accent: accent) }
                ToolbarItemGroup(placement: .confirmationAction) {
                    if let request = pendingRequest {
                        if deciding { ProgressView().accessibilityLabel("Submitting decision") }
                        if !technical {
                            Button(role: .destructive) { decide(request, approved: false) } label: {
                                Image(systemName: "xmark").font(TronTypography.buttonSM).tronToolbarAction(accent: .tronError)
                            }
                            .accessibilityLabel("Decline \(countLabel(request))")
                            .accessibilityIdentifier("settings-approval-decline-\(request.requestId)")
                            Button { decide(request, approved: true) } label: {
                                Image(systemName: "checkmark").font(TronTypography.buttonSM).tronToolbarAction(accent: .tronSuccess)
                            }
                            .accessibilityLabel("Approve \(countLabel(request))")
                            .accessibilityIdentifier("settings-approval-approve-\(request.requestId)")
                        }
                    } else if !isPending {
                        Button { dismiss() } label: {
                            Image(systemName: "checkmark").font(TronTypography.buttonSM).tronToolbarAction(accent: .tronPrimary)
                        }.accessibilityLabel("Done")
                    }
                }
            }
            .disabled(deciding)
        }
        .tronTopBlur(.sheet)
        .tronPresentation()
        .tronSettingsLayout()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .accessibilityIdentifier("settings-approval-sheet")
        .task(id: PresentationActivityTaskID(
            source: LoadID(selection: selection.id, selectedReference: selectedReference,
                           revision: model.settingsApprovalsRevision, foreground: model.foregroundReconciliationGeneration,
                           identity: model.knowledgePresentationIdentity),
            presentationActive: activity.allowsPresentationPublication
        )) {
            guard activity.allowsPresentationPublication else { return }
            await load()
        }
        .onChange(of: activity.allowsPresentationPublication) { _, active in if !active { loadGeneration &+= 1 } }
        .onDisappear { loadGeneration &+= 1 }
        .onChange(of: model.selectedGatewayProfileID()) { _, _ in dismiss() }
    }

    private func itemCount(_ request: SettingsApprovalRequest) -> Int { max(1, request.changes.count) }
    private func countLabel(_ request: SettingsApprovalRequest) -> String {
        let count = itemCount(request)
        return "\(count) \(count == 1 ? "change" : "changes")"
    }

    private func pendingDetails(_ request: SettingsApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(countLabel(request)) · Asked by \(request.requester)")
                .font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextSecondary)
            if let reason = request.reason { prose(reason) }
            valueCard("Applies to", value: targetLabel(request.target), detail: request.target.sessionId ?? request.target.cwd)
            if let action = request.action {
                Text(action.title).font(TronTypography.headline)
                ForEach(Array(action.items.enumerated()), id: \.offset) { _, item in
                    valueCard(item.label, value: item.value, detail: item.detail)
                }
            }
            ForEach(request.changes) { change in
                valueCard(change.label,
                          value: change.redacted == true ? "New value hidden" : change.display.map { "\($0.before) → \($0.after)" } ?? "Exact values in technical details",
                          detail: settingsLayerLabel(change.layer))
                if let confirm = change.confirm { prose(confirm) }
                if technical, change.redacted != true {
                    TronTechnicalJSONRow(value: .object(["before": change.before ?? .null, "after": change.after ?? .null]),
                                         title: "Exact values", sheetTitle: change.label)
                }
            }
            if let expiry = request.expiryDate {
                Text("Expires \(expiry, format: .relative(presentation: .named))")
                    .font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextSecondary)
            }
            if technical {
                valueCard("Request", value: request.requestId, detail: "Digest: \(request.digest)")
            }
        }
    }

    private func outcomeDetails(_ request: SettingsApprovalOutcome) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.title).font(TronTypography.headline)
            prose(outcomeSummary(request.status))
            Text("Asked by \(request.requester.label)").font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextSecondary)
            valueCard("Applies to", value: targetLabel(request.target), detail: request.target.sessionId ?? request.target.cwd)
            if let reason = request.reason { prose(reason) }
            if let action = request.action {
                valueCard(action.title, value: action.summary ?? outcomeSummary(request.status), detail: nil)
            }
            ForEach(Array(request.items.enumerated()), id: \.offset) { _, item in
                valueCard(item.label, value: item.redacted == true ? "Value hidden" : "\(item.before ?? "Not set") → \(item.after ?? "Not set")",
                          detail: settingsLayerLabel(item.layer))
            }
            if let failure = request.failure { prose(failure) }
            if technical { valueCard("Request", value: request.requestId, detail: request.requester.taskId) }
        }
    }

    private func historyDetails(_ entry: SettingsChangeHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(outcomeTitle(entry.status)).font(TronTypography.headline)
            prose(outcomeSummary(entry.status))
            valueCard(entry.title, value: entry.redacted == true ? "Value hidden" : entry.presentation.map { "\($0.display.before) → \($0.display.after)" } ?? "Recorded outcome",
                      detail: entry.presentation?.actor)
            if let failure = entry.failure { prose(failure) }
            if technical, entry.redacted != true {
                TronTechnicalJSONRow(value: .object(["before": entry.before ?? .null, "after": entry.after ?? .null]), title: "Recorded values", sheetTitle: entry.title)
            }
        }
    }

    private func valueCard(_ title: String, value: String, detail: String?) -> some View {
        TronGlassCard(accent: accent) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(TronTypography.headline)
                prose(value)
                if let detail { Text(detail).font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextSecondary).fixedSize(horizontal: false, vertical: true) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
    }
    private func prose(_ value: String) -> some View {
        Text(value).font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextPrimary)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }
    private func targetLabel(_ target: SettingsApprovalRequest.Target) -> String {
        switch target.kind {
        case "global": "Global"
        case "home": "Home"
        case "session": "Session"
        case "project": "Project"
        default: target.kind
        }
    }
    private func outcomeTitle(_ status: String?) -> String {
        switch status {
        case "approved": "Applied"
        case "declined": "Declined"
        case "failed": "Failed"
        case "expired": "Expired"
        case "superseded": "Superseded"
        default: "Outcome"
        }
    }
    private func outcomeSummary(_ status: String) -> String {
        switch status {
        case "approved": "Approved and applied."
        case "declined": "Declined; it was not applied."
        case "expired": "Expired before approval; it was not applied."
        case "superseded": "The request was replaced or the affected state changed."
        case "failed": "Inspect the affected state before retrying; effects may have completed."
        default: "No terminal result is available."
        }
    }

    private func load(force: Bool = false) async {
        if case .outcomes(let value) = selection { state = .outcomes(value.requests); return }
        if !force, case .outcomes = state { return }
        guard activity.allowsPresentationPublication, !Task.isCancelled, !deciding else { return }
        loadGeneration &+= 1
        let ticket = loadGeneration, identity = model.knowledgePresentationIdentity
        let foreground = model.foregroundReconciliationGeneration, admittedActivity = activity
        @MainActor func admits() -> Bool {
            ticket == loadGeneration && !Task.isCancelled && identity == model.knowledgePresentationIdentity
                && foreground == model.foregroundReconciliationGeneration && admittedActivity == activity
                && activity.allowsPresentationPublication
        }
        do {
            let requests = try await model.allSettingsApprovals()
            guard admits() else { return }
            let matches = requests.filter { request in
                if let selectedReference { return request.requestId == selectedReference.requestID }
                switch selection {
                case .request(let reference): return request.requestId == reference.requestID
                case .session(let id): return request.actor.sessionId == id
                case .outcomes: return false
                }
            }
            if !matches.isEmpty { state = .pending(matches); return }
            let reference: SettingsApprovalReference? = selectedReference ?? {
                if case .request(let value) = selection { return value }
                return nil
            }()
            if let reference {
                // Bounded history only; never infer a terminal status from disappearance.
                var cursor: String?, entries: [SettingsChangeHistoryEntry] = []
                let wanted = Set(reference.changeIDs.isEmpty ? [reference.requestID] : reference.changeIDs)
                var seen: Set<String> = []
                for _ in 0..<10 {
                    let page = try await model.settingsHistory(cursor: cursor, actor: nil, layer: nil, section: nil, key: nil, status: nil)
                    guard admits() else { return }
                    for entry in page.entries where entry.requestId == reference.requestID && SettingsApprovalOutcome.terminalStatuses.contains(entry.status) {
                        if let original = entry.refersTo, wanted.contains(original), seen.insert(original).inserted { entries.append(entry) }
                    }
                    cursor = page.nextCursor
                    if seen == wanted {
                        state = .history(entries); return
                    }
                    if cursor == nil { break }
                }
            }
            state = .unavailable("This request is no longer waiting. Its complete terminal result is not available in this bounded history window.")
        } catch is CancellationError {
        } catch {
            guard admits() else { return }
            state = .unavailable(error.localizedDescription)
        }
    }

    private func decide(_ request: SettingsApprovalRequest, approved: Bool) {
        guard !deciding, activity.allowsDataPublication else { return }
        deciding = true; loadGeneration &+= 1
        selectedReference = SettingsApprovalReference(requestID: request.requestId, changeIDs: request.changes.map(\.changeId))
        let identity = model.knowledgePresentationIdentity
        // The receipt coordinator, not this presentation task, owns accepted work.
        Task { @MainActor in
            defer { deciding = false }
            do {
                let result = try await model.decideSettingsApproval(request, approved: approved)
                guard identity == model.knowledgePresentationIdentity, activity.allowsDataPublication else { return }
                loadGeneration &+= 1
                if let status = result.status, ["approved", "declined"].contains(status) {
                    state = .outcomes([SettingsApprovalOutcome(request: request, status: status)])
                } else { state = .unavailable("The decision returned no proven terminal result. Refresh before retrying.") }
            } catch {
                guard identity == model.knowledgePresentationIdentity, activity.allowsDataPublication else { return }
                loadGeneration &+= 1
                state = .unavailable("\(error.localizedDescription)\nDecision status is not proven here. Refresh or inspect the affected state before retrying.")
            }
        }
    }
}

struct SettingsApprovalRequestSummary: View {
    let request: SettingsApprovalRequest
    var body: some View {
        TronGlassCard(accent: .tronAmber) {
            VStack(alignment: .leading, spacing: 8) {
                Text(request.action?.title ?? request.changes.map(\.label).joined(separator: ", "))
                    .font(TronTypography.headline).lineLimit(2)
                Text("Asked by \(request.requester) · Review request")
                    .font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextSecondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }.accessibilityIdentifier("settings-approval-\(request.requestId)")
    }
}
