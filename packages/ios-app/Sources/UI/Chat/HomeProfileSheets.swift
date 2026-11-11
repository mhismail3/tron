import SwiftUI
import TronMobileCore

extension HomeSheet {
    func profile(_ list: HomeProfileList) -> some View {
        let active = list.active
        let inactive = list.items.filter { $0.status != .active }
        return TronSettingsSections(alignment: .leading, spacing: 18) {
            profileHeader(list)
            if active.isEmpty { profileEmptyPlaceholder }
            if !list.items.isEmpty {
                TronListGroup(sections: HomeProfilePresentation.groups(active).map {
                    TronListSection(title: $0.title, rows: $0.items)
                } + [TronListSection(title: "No longer applied", rows: inactive)], identifier: "home-profile-items") { item in
                    TronListButton(HomeProfilePresentation.rowContent(item), identifier: "home-profile-item-\(item.id)") {
                        present(.profileItem(item))
                    }
                }
            }
            if !inactive.isEmpty {
                TronSettingsCaption("Superseded or retired items stay in Knowledge.").containerValue(\.tronSettingsSection, false)
            }
            if list.unclassified > 0 { profileUnclassifiedCaption(list) }
        }
    }

    func emptyProfile(_ list: HomeProfileList) -> some View {
        TronFeedEmptyState(identifier: "home-profile-viewport") {
            TronSettingsSections(alignment: .leading, spacing: 18) {
                profileHeader(list)
                if list.unclassified > 0 { profileUnclassifiedCaption(list) }
            }
        } placeholder: { profileEmptyPlaceholder }
    }

    @ViewBuilder private func profileHeader(_ list: HomeProfileList) -> some View {
        TronSettingsCaption("About you, organized by area. Confirmed by you and Inferred describe what you have reviewed. Home reads relevant notes; placement grants no execution permission. Unsorted notes await review.").containerValue(\.tronSettingsSection, false)
        profileEditNotices()
    }

    private var profileEmptyPlaceholder: some View {
        TronPlaceholderState(title: "Nothing learned yet",
                             detail: "Home saves durable preferences, decisions, delegation defaults and facts you state.",
                             icon: "person.text.rectangle")
    }

    private func profileUnclassifiedCaption(_ list: HomeProfileList) -> some View {
        TronSettingsCaption("\(list.unclassified) profile \(list.unclassified == 1 ? "note has" : "notes have") no single kind and \(list.unclassified == 1 ? "is" : "are") not applied.").containerValue(\.tronSettingsSection, false)
    }

    func profileItemDetail(_ item: HomeProfileListItem) -> some View {
        TronSettingsSections(alignment: .leading, spacing: 18) {
            profileEditNotices()
            TronGlassCard(accent: accent) {
                VStack(alignment: .leading, spacing: 0) {
                    TronSettingsRow(icon: HomeProfilePresentation.kindIcon(item.kind), title: HomeProfilePresentation.kindTitle(item.kind),
                                    subtitle: HomeProfilePresentation.stateLine(item), accent: accent) {
                        TronStatusPill(text: HomeProfilePresentation.stateLabel(item), accent: HomeProfilePresentation.stateAccent(item))
                            .accessibilityIdentifier("home-profile-item-state")
                    }
                    divider()
                    markdownText(item.text)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home-profile-item-detail")
            if item.status == .active, item.path != "prior" {
                profileItemActions(item)
            }
            if item.path == "prior" {
                TronSettingsCaption("Prior organization is read-only until its exact placement has been reviewed.").containerValue(\.tronSettingsSection, false)
            }
            TronSettingsGroup("Knowledge note", accent: accent) {
                VStack(spacing: 0) {
                    TronSettingsRow(icon: "number", title: "Note ID", subtitle: item.id, subtitleLineLimit: nil, accent: accent)
                        .accessibilityIdentifier("home-profile-item-note-id")
                    divider()
                    TronSettingsRow(icon: "calendar", title: "Learned", subtitle: HomeSheetTime.absolute(item.createdAt), accent: accent)
                    if item.updatedAt != item.createdAt {
                        divider()
                        TronSettingsRow(icon: "clock.arrow.circlepath", title: "Last changed", subtitle: HomeSheetTime.absolute(item.updatedAt),
                                        accent: accent)
                    }
                }
            }
        }
    }

    private func profileItemActions(_ item: HomeProfileListItem) -> some View {
        TronSettingsGroup("Change", accent: accent) {
            VStack(spacing: 0) {
                if !item.confirmed {
                    Button { confirm(item) } label: {
                        TronSettingsRow(icon: "checkmark.seal", title: "Confirm",
                                        subtitle: "Mark this exact note as confirmed by you", accent: accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(profileEdit.working)
                    .accessibilityIdentifier("home-profile-item-confirm")
                    divider()
                }
                TronProgressiveSheetLink(accessibilityLabel: "Edit", identity: "home.\(profileID).profile-edit.\(item.id)") {
                    HomeProfileItemEditor(item: item) { change, summary in changeProfile([change], done: summary) }
                } label: {
                    TronSettingsRow(icon: "pencil", title: "Edit",
                                    subtitle: "Change its text or kind, or replace it", accent: accent)
                }
                .disabled(profileEdit.working)
                .accessibilityIdentifier("home-profile-item-edit")
                divider()
                TronProgressiveSheetLink(accessibilityLabel: "Retire", identity: "home.\(profileID).profile-retire.\(item.id)") {
                    HomeProfileRetireEditor(item: item) { reason in
                        changeProfile([HomeProfileChange(action: .retire, id: item.id, expectedRevision: item.revisionId, reason: reason)],
                                      done: "Retired: \(HomeChapterPresentation.topicPreview(item.text, limit: 60))")
                    }
                } label: {
                    TronSettingsRow(icon: "archivebox", title: "Retire", subtitle: "Stop applying it",
                                    accent: .tronError, titleColor: .tronError, subtitleColor: .tronError)
                        .tronSettingsVisualTheme(accent: .tronError)
                }
                .disabled(profileEdit.working)
                .accessibilityIdentifier("home-profile-item-retire")
                .tronListMarkers("home-profile-item-retire")
            }
        }
    }

    @ViewBuilder func profileEditNotices() -> some View {
        if let undo = profileEdit.undo {
            TronGlassCard(accent: accent) {
                HStack(spacing: 0) {
                    TronSettingsRow(icon: "checkmark.circle", title: undo.summary,
                                    subtitle: "Applies from Home's next activation", accent: accent)
                    Button { undoProfileChange(undo) } label: {
                        TronInlineActionLabel("Undo", icon: "arrow.uturn.backward", isWorking: profileEdit.working, accent: accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(profileEdit.working)
                    .padding(.trailing, TronSpacing.section)
                    .accessibilityIdentifier("home-profile-undo")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home-profile-last-change")
        }
        if let failure = profileEdit.failure {
            TronSettingsNotice(message: failure.message, title: failure.title)
                .accessibilityIdentifier("home-profile-failure")
        }
    }

    private func confirm(_ item: HomeProfileListItem) {
        changeProfile([HomeProfileChange(action: .confirm, id: item.id, expectedRevision: item.revisionId)],
                      done: "Confirmed: \(HomeChapterPresentation.topicPreview(item.text, limit: 60))")
    }

    func changeProfile(_ changes: [HomeProfileChange], done summary: String) {
        guard let admission = profileAdmission() else { return }
        profileEdit.working = true
        profileEdit.failure = nil
        Task { @MainActor in
            do {
                let result = try await model.changeHomeProfile(changes, authority: admission.authority)
                guard publishes(admission) else { return }
                profileEdit.working = false
                profileEdit.undo = result.changes.first.map { HomeProfileEditState.Undo(changeID: $0.changeId, summary: summary) }
            } catch {
                guard publishes(admission) else { return }
                profileEdit.working = false
                if !(error is CancellationError) { profileEdit.failure = .init(title: "Profile not changed", error: error) }
            }
            refreshAfterMutation()
            onChanged?()
        }
    }

    private func undoProfileChange(_ undo: HomeProfileEditState.Undo) {
        guard let admission = profileAdmission() else { return }
        profileEdit.working = true
        profileEdit.failure = nil
        Task { @MainActor in
            do {
                try await model.undoHomeProfileChange(undo.changeID, authority: admission.authority)
                guard publishes(admission) else { return }
                profileEdit.working = false
                profileEdit.undo = nil
            } catch {
                guard publishes(admission) else { return }
                profileEdit.working = false
                if !(error is CancellationError) { profileEdit.failure = .init(title: "Undo not applied", error: error) }
            }
            refreshAfterMutation()
            onChanged?()
        }
    }

    private func profileAdmission() -> HomeControlAdmission? {
        guard let identity, let coordinator, coordinator.activity(for: identity.surfaceToken).allowsDataPublication,
              let authority = try? model.homeMutations.authority(profileID: profileID) else { return nil }
        return HomeControlAdmission(identity: identity, coordinator: coordinator, authority: authority)
    }

    private func publishes(_ admission: HomeControlAdmission) -> Bool {
        identity == admission.identity && admission.coordinator.activity(for: admission.identity.surfaceToken).allowsDataPublication
    }

    func loadedProfileItem(_ carried: HomeProfileListItem) -> HomeProfileListItem {
        switch owner.state {
        case .loaded(let read, .profile(let list)), .loading(let read, .some(.profile(let list))):
            guard read.identity == identity else { return carried }
            return list.items.first { $0.id == carried.id } ?? carried
        default:
            return carried
        }
    }
}

struct HomeProfileEditState {
    struct Undo: Equatable { let changeID: String; let summary: String }
    struct Failure: Equatable {
        let title: String
        let message: String
        init(title: String, error: any Error) {
            self.title = title
            if let failure = error as? GatewayFailure, failure.code == "conflict",
               case .object(let details)? = failure.details, case .object(let display)? = details["display"],
               case .string(let current)? = display["current"] {
                message = "\(failure.message). Now: \(current)"
            } else {
                message = error.localizedDescription
            }
        }
    }
    var working = false
    var undo: Undo?
    var failure: Failure?
}

struct HomeProfileItemEditor: View {
    let item: HomeProfileListItem
    let onSave: (HomeProfileChange, String) -> Void
    @PresentationState private var text: String
    @PresentationState private var kind: HomeProfileListItemKind
    @PresentationState private var replaces = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tronSettingsVisualTheme) private var theme
    private var accent: Color { theme?.accent ?? .tronPrimary }

    init(item: HomeProfileListItem, onSave: @escaping (HomeProfileChange, String) -> Void) {
        self.item = item
        self.onSave = onSave
        _text = PresentationState(wrappedValue: item.text)
        _kind = PresentationState(wrappedValue: item.kind)
    }

    private var line: String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
    private var changed: Bool { line != item.text || kind != item.kind }
    private var valid: Bool { !line.isEmpty && line.count <= 512 }

    var body: some View {
        ScrollView {
            TronSettingsSections(alignment: .leading, spacing: 18) {
                TronSettingsGroup("Text", detail: "One line, as Home applies it.", accent: accent) {
                    TextField("Item text", text: $text, axis: .vertical)
                        .lineLimit(2...8)
                        .tronTextEntryDone(keyboardToolbar: true)
                        .textFieldStyle(.plain)
                        .font(TronTypography.body)
                        .foregroundStyle(Color.tronTextPrimary)
                        .tint(accent)
                        .padding(.horizontal, TronSpacing.section)
                        .padding(.vertical, TronSpacing.md)
                        .frame(minHeight: 52)
                        .accessibilityIdentifier("home-profile-editor-text")
                }
                TronSettingsGroup("Kind", accent: accent) {
                    TronChoiceRow(icon: HomeProfilePresentation.kindIcon(kind), title: "Kind",
                                  choices: HomeProfileListItemKind.allCases.map { TronChoice(id: $0, label: HomeProfilePresentation.kindTitle($0)) },
                                  selected: kind, accent: accent) { kind = $0 }
                }
                TronSettingsGroup("Replace", accent: accent) {
                    TronToggleRow(icon: "arrow.triangle.2.circlepath", title: "Replace this item",
                                  detail: "Save a new item and keep this one as superseded. Use it when the meaning changes, not to fix wording.",
                                  accent: accent, isOn: $replaces)
                        .accessibilityIdentifier("home-profile-editor-replace")
                }
                TronSettingsCaption("Your edit is confirmed and applies from Home's next activation. You can undo it.").containerValue(\.tronSettingsSection, false)
            }
            .padding(18)
        }
        .scrollDismissesKeyboard(.interactively)
        .tronScrollEdgeChrome()
        .tronNavigationTitle(replaces ? "Replace item" : "Edit item")
        .tronSaveToolbar(enabled: valid && (changed || replaces)) {
            let preview = HomeChapterPresentation.topicPreview(line, limit: 60)
            if replaces {
                onSave(HomeProfileChange(action: .supersede, id: item.id, expectedRevision: item.revisionId, text: line, kind: kind.rawValue),
                       "Replaced with: \(preview)")
            } else {
                onSave(HomeProfileChange(action: .refine, id: item.id, expectedRevision: item.revisionId,
                                         text: line == item.text ? nil : line, kind: kind == item.kind ? nil : kind.rawValue),
                       "Edited: \(preview)")
            }
            dismiss()
        }
    }
}

struct HomeProfileRetireEditor: View {
    let item: HomeProfileListItem
    let onRetire: (String?) -> Void
    @PresentationState private var reason = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tronSettingsVisualTheme) private var theme
    private var accent: Color { theme?.accent ?? .tronPrimary }

    var body: some View {
        ScrollView {
            TronSettingsSections(alignment: .leading, spacing: 18) {
                TronSettingsGroup("Item", accent: accent) {
                    TronSettingsRow(icon: HomeProfilePresentation.kindIcon(item.kind), title: HomeProfilePresentation.kindTitle(item.kind),
                                    subtitle: item.text, subtitleLineLimit: 4, accent: accent)
                }
                TronSettingsGroup("Reason", detail: "Optional. Shown with the change in Changes.", accent: accent) {
                    TextField("Why it no longer holds", text: $reason, axis: .vertical)
                        .lineLimit(1...4)
                        .tronTextEntryDone(keyboardToolbar: true)
                        .textFieldStyle(.plain)
                        .font(TronTypography.body)
                        .foregroundStyle(Color.tronTextPrimary)
                        .tint(accent)
                        .padding(.horizontal, TronSpacing.section)
                        .padding(.vertical, TronSpacing.md)
                        .frame(minHeight: 52)
                        .accessibilityIdentifier("home-profile-retire-reason")
                }
                TronSettingsCaption("Home stops applying it from its next activation. It stays in Knowledge, and you can undo this.").containerValue(\.tronSettingsSection, false)
            }
            .padding(18)
        }
        .scrollDismissesKeyboard(.interactively)
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Retire item")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    let line = reason.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
                    onRetire(line.isEmpty ? nil : line)
                    dismiss()
                } label: {
                    Text("Retire").font(TronTypography.buttonSM).tronToolbarAction(role: .destructive)
                }
                .accessibilityIdentifier("home-profile-retire-confirm")
            }
        }
    }
}

enum HomeProfilePresentation {
    struct Group { let title: String; let items: [HomeProfileListItem] }

    private static let areas: [(String, String)] = [
        ("life", "Life & people"), ("routines", "Routines & wellbeing"),
        ("communication", "Communication"), ("engineering", "Engineering"),
        ("resources", "Machines, devices & services"), ("projects", "Projects"),
        ("corrections", "Corrections"), ("inferred", "Unsorted"), ("prior", "Prior organization")
    ]

    static func groups(_ items: [HomeProfileListItem]) -> [Group] {
        areas.compactMap { path, title in
            let members = items.filter { $0.path == path || $0.path.hasPrefix(path + "/") }
                .sorted { $0.path == $1.path ? $0.createdAt < $1.createdAt : $0.path < $1.path }
            return members.isEmpty ? nil : Group(title: title, items: members)
        }
    }

    static func kindTitle(_ kind: HomeProfileListItemKind) -> String {
        switch kind {
        case .preference: "Preference"
        case .standingDecision: "Standing decision"
        case .delegationDefault: "Delegation default"
        case .fact: "Fact"
        case .correction: "Correction"
        }
    }

    static func kindTitle(wire: String) -> String {
        HomeProfileListItemKind(rawValue: wire).map(kindTitle) ?? wire
    }

    static func kindIcon(_ kind: HomeProfileListItemKind) -> String {
        switch kind {
        case .preference: "hand.thumbsup"
        case .standingDecision: "flag"
        case .delegationDefault: "arrow.triangle.branch"
        case .fact: "info.circle"
        case .correction: "arrow.uturn.backward.circle"
        }
    }

    static func stateIcon(_ item: HomeProfileListItem) -> String {
        switch item.status {
        case .active: item.confirmed ? "checkmark.seal.fill" : "sparkle"
        case .superseded: "arrow.triangle.2.circlepath"
        case .retired: "archivebox"
        }
    }

    static func stateLabel(_ item: HomeProfileListItem) -> String {
        switch item.status {
        case .active: item.confirmed ? "Confirmed by you" : "Inferred"
        case .superseded: "Superseded"
        case .retired: "Retired"
        }
    }

    static func stateAccent(_ item: HomeProfileListItem) -> Color {
        switch item.status {
        case .active: item.confirmed ? .tronEmerald : .tronAmber
        case .superseded, .retired: .tronSlate
        }
    }

    static func stateLine(_ item: HomeProfileListItem) -> String {
        switch item.status {
        case .active: item.confirmed ? "Confirmed by you · " + item.path : "Inferred · " + item.path
        case .superseded: "Replaced by a newer item"
        case .retired: "No longer applies"
        }
    }

    static func rowContent(_ item: HomeProfileListItem) -> TronListRowContent {
        TronListRowContent(title: HomeChapterPresentation.topicPreview(item.text, limit: 160), preview: true,
                           status: TronListStatus(text: stateLabel(item), tone: stateAccent(item)),
                           tags: [TronListTag(text: item.path == "prior" ? "Prior organization" : item.path), TronListTag(text: kindTitle(item.kind))])
    }
}
