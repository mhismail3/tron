import SwiftUI
import TronMobileCore

/// The one approval sheet (#2050), shared by the chat's approval chip, a waiting
/// request's own presentation, push review and Changes. It reads the open-request
/// projection, and once the request settles shows its decided state in the same
/// layout. A dismissal never decides; only a toolbar tap submits the exact digest.
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
        /// More than one open request matched a push: choose one.
        case choose([SettingsApprovalRequest])
        case review(SettingsApprovalReview, SettingsApprovalRequest?)
        case outcomes([SettingsApprovalReview])
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
        guard case .review(_, let request?) = state else { return nil }
        return request
    }
    private var reviews: [SettingsApprovalReview] {
        switch state {
        case .review(let review, _): [review]
        case .outcomes(let reviews): reviews
        default: []
        }
    }
    private var isWaiting: Bool {
        if case .choose = state { return true }
        return pendingRequest != nil
    }
    private var title: String {
        if technical { return "Technical details" }
        switch state {
        case .choose: return "Approve"
        case .review(let review, _): return review.isPending ? "Approve" : SettingsApprovalReview.statusLabel(review.status)
        case .outcomes(let reviews): return Set(reviews.map(\.status)).count == 1 ? SettingsApprovalReview.statusLabel(reviews[0].status) : "Outcomes"
        default: return "Approval"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                TronSettingsSections(alignment: .leading, spacing: 18) {
                    switch state {
                    case .loading:
                        TronLoadingState(label: "Loading request…").frame(maxWidth: .infinity)
                    case .choose(let requests):
                        TronSettingsCaption("Choose a request to review. Nothing is decided until you tap Approve or Decline.")
                        ForEach(requests) { request in
                            SettingsApprovalChip(review: SettingsApprovalReview(request: request), identifier: "settings-approval-\(request.requestId)") {
                                selectedReference = SettingsApprovalReference(requestID: request.requestId, changeIDs: request.changes.map(\.changeId))
                            }
                        }
                    case .review, .outcomes:
                        ForEach(reviews, id: \.requestID) { review in SettingsApprovalReviewContent(review: review, technical: technical) }
                        if technical, case .outcomes(let message) = selection {
                            TronTechnicalJSONRow(value: message.raw, title: "Canonical outcome", sheetTitle: "Canonical outcome")
                        }
                    case .unavailable(let message):
                        TronSettingsNotice(message: message, title: "Status unavailable", retry: { Task { await load() } })
                    }
                }
                .padding(18)
            }
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { technical.toggle() } label: {
                        Image(systemName: technical ? "chevron.left" : "info.circle")
                            .font(TronTypography.buttonSM).tronToolbarAction(accent: .tronPrimary)
                    }.accessibilityLabel(technical ? "Back" : "Technical details")
                }
                ToolbarItem(placement: .principal) { TronSheetTitle(title: title) }
                ToolbarItemGroup(placement: .confirmationAction) {
                    if let request = pendingRequest {
                        if deciding { ProgressView().accessibilityLabel("Submitting decision") }
                        if !technical {
                            Button(role: .destructive) { decide(request, approved: false) } label: {
                                Image(systemName: "xmark").font(TronTypography.buttonSM).tronToolbarAction(accent: .tronError)
                            }
                            .accessibilityLabel("Decline")
                            .accessibilityIdentifier("settings-approval-decline-\(request.requestId)")
                            Button { decide(request, approved: true) } label: {
                                Image(systemName: "checkmark").font(TronTypography.buttonSM).tronToolbarAction(accent: .tronSuccess)
                            }
                            .accessibilityLabel("Approve")
                            .accessibilityIdentifier("settings-approval-approve-\(request.requestId)")
                        }
                    } else if !isWaiting {
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

    private func load() async {
        if case .outcomes(let message) = selection { state = .outcomes(message.requests.map(SettingsApprovalReview.init(outcome:))); return }
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
            try await model.refreshSettingsApprovals()
            guard admits() else { return }
            let open = model.openSettingsApprovals ?? []
            let reference: SettingsApprovalReference? = selectedReference ?? {
                if case .request(let value) = selection { return value }
                return nil
            }()
            let matches = open.filter { request in
                if let reference { return request.requestId == reference.requestID }
                if case .session(let id) = selection { return request.actor.sessionId == id }
                return false
            }
            if matches.count == 1, let request = matches.first { state = .review(SettingsApprovalReview(request: request), request); return }
            if matches.count > 1 { state = .choose(matches); return }
            guard let reference else {
                state = .unavailable("No request from this chat is waiting for you.")
                return
            }
            // Bounded history only; never infer a terminal status from disappearance.
            // A chip knows only its request: its facts are one decision's write,
            // so the page holding the first of them holds them all.
            var cursor: String?, entries: [SettingsChangeHistoryEntry] = []
            let wanted = Set(reference.changeIDs)
            var seen: Set<String> = []
            for _ in 0..<10 {
                let page = try await model.settingsHistory(cursor: cursor, actor: nil, layer: nil, section: nil, key: nil, status: nil)
                guard admits() else { return }
                for entry in page.entries where entry.requestId == reference.requestID && SettingsApprovalOutcome.terminalStatuses.contains(entry.status) {
                    if let original = entry.refersTo, wanted.isEmpty || wanted.contains(original), seen.insert(original).inserted { entries.append(entry) }
                }
                cursor = page.nextCursor
                if !seen.isEmpty, wanted.isEmpty || seen == wanted, let review = SettingsApprovalReview(history: entries) {
                    state = .review(review, nil); return
                }
                if cursor == nil { break }
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
            do {
                _ = try await model.decideSettingsApproval(request, approved: approved)
                deciding = false
                guard identity == model.knowledgePresentationIdentity, activity.allowsDataPublication else { return }
                // The decided state is read back like any settled request.
                await load()
            } catch {
                deciding = false
                guard identity == model.knowledgePresentationIdentity, activity.allowsDataPublication else { return }
                loadGeneration &+= 1
                state = .unavailable("\(error.localizedDescription)\nDecision status is not proven here. Refresh or inspect the affected state before retrying.")
            }
        }
    }
}

/// One request's body in standard settings rows: who asks and why, what it
/// applies to, then each change. Waiting and decided states share it.
struct SettingsApprovalReviewContent: View {
    let review: SettingsApprovalReview
    let technical: Bool

    private var accent: Color { SettingsApprovalChip.accent(review.status) }

    var body: some View {
        TronGlassCard(accent: .tronPrimary) {
            VStack(alignment: .leading, spacing: 0) {
                TronSettingsRow(icon: "person.crop.circle", title: "\(review.requester) \(review.isPending ? "asks" : "asked")", subtitle: review.reason.map { "“\($0)”" },
                                subtitleLineLimit: nil) {
                    TronStatusPill(text: SettingsApprovalReview.statusLabel(review.status), accent: accent)
                }
                .textSelection(.enabled)
                TronSettingsDivider()
                TronSettingsRow(icon: "scope", title: "Applies to", subtitle: targetLabel, subtitleLineLimit: nil)
                if review.isPending, let expiry = review.expiresAt {
                    TronSettingsDivider()
                    TronSettingsRow(icon: "hourglass", title: "Expires",
                                    subtitle: "\(expiry.formatted(.relative(presentation: .named))) · \(expiry.formatted(date: .omitted, time: .shortened))")
                }
                if let summary = review.summary {
                    TronSettingsDivider()
                    TronSettingsRow(icon: "checkmark.circle", title: "Result", subtitle: summary, subtitleLineLimit: nil)
                }
                if let failure = review.failure {
                    TronSettingsDivider()
                    TronSettingsRow(icon: "exclamationmark.triangle", title: "Why", subtitle: failure, subtitleLineLimit: nil)
                }
            }
        }
        if !review.rows.isEmpty {
            TronSettingsGroup(review.heading) {
                VStack(spacing: 0) {
                    ForEach(Array(review.rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 { TronSettingsDivider() }
                        TronSettingsRow(icon: nil, title: row.title, subtitle: row.value, subtitleLineLimit: nil)
                            .textSelection(.enabled)
                        if let detail = row.detail, !detail.isEmpty {
                            // A wrapping note under its row, in the rows' own muted subtext.
                            Text(detail)
                                .font(TronTypography.settingsSubtext(adjustment: 0))
                                .foregroundStyle(Color.tronTextMuted)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, TronSettingsLayoutPolicy.rowHorizontalPadding)
                                .padding(.top, -TronSpacing.md)
                                .padding(.bottom, TronSpacing.xl)
                        }
                        if technical, let exact = row.exact {
                            TronTechnicalJSONRow(value: exact, title: "Exact identity", sheetTitle: row.title)
                        }
                    }
                }
            }
        }
        if review.isPending {
            TronSettingsCaption("Approving applies exactly this request once. Only your tap decides; closing this sheet leaves it waiting.")
        }
        if technical {
            TronSettingsGroup("Request") {
                TronSettingsRow(icon: "number", title: "Request", subtitle: review.requestID, subtitleLineLimit: nil,
                                footnote: review.digest.map { "Digest \($0)" }, footnoteIsIdentifier: true) { EmptyView() }
                    .textSelection(.enabled)
            }
        }
    }

    private var targetLabel: String {
        switch review.target.kind {
        case "global": "Global"
        case "home": "Home"
        case "session": "Session"
        case "project": review.target.cwd.map { "Project · \($0)" } ?? "Project"
        default: review.target.kind.capitalized
        }
    }
}
