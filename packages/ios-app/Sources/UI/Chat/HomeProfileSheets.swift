import SwiftUI
import TronMobileCore

/// The learned profile: what Home has saved about the maintainer as Knowledge
/// notes, grouped by kind in the order Home applies them. On a Gateway with
/// `home-profile-edit.v1` the maintainer confirms, edits, replaces and retires items
/// here; every change goes through the settings change path, shows in Changes and
/// can be undone. An older Gateway keeps the sheet read-only.
extension HomeSheet {
    func profile(_ list: HomeProfileListDTO) -> some View {
        let active = list.active
        let inactive = list.items.filter { $0.status != .active }
        let inferred = active.filter { !$0.confirmed }
        let editable = model.homeProfileEditable
        return VStack(alignment: .leading, spacing: 18) {
            TronSettingsCaption(editable
                ? "Learned from your messages to Home. Confirmed items are binding; inferred items are Home's default until you confirm them. Changes apply from Home's next activation."
                : "Learned from your messages to Home. Confirmed items are binding; inferred items are Home's default until you confirm them.")
            profileEditNotices()
            if active.isEmpty {
                TronPlaceholderState(title: "Nothing learned yet",
                                     detail: "Home saves durable preferences, decisions, delegation defaults and facts you state.",
                                     icon: "person.text.rectangle")
            }
            if editable, inferred.count > 1 {
                TronGlassCard(accent: .tronSessionTeal) {
                    Button { profileEdit.confirmingAll = true } label: {
                        TronSettingsRow(icon: "checkmark.seal", title: "Confirm all inferred",
                                        subtitle: "\(inferred.count) items become binding on every Home turn", accent: .tronSessionTeal) {
                            TronInlineActionLabel("Confirm all", isWorking: profileEdit.working, accent: .tronSessionTeal)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(profileEdit.working)
                    .accessibilityIdentifier("home-profile-confirm-all")
                }
                .tronManagedSheet(isPresented: $profileEdit.confirmingAll, identity: "home.\(profileID).profile-confirm-all") {
                    TronConfirmationSheet(
                        title: "Confirm \(inferred.count) items?",
                        message: "Every inferred item becomes binding from Home's next activation. You can undo this.",
                        confirmTitle: "Confirm all",
                        destructive: false,
                        icon: "checkmark.seal",
                        onConfirm: {
                            changeProfile(inferred.map { HomeProfileChange(action: .confirm, id: $0.id, expectedRevision: $0.revisionId) },
                                          done: "Confirmed \(inferred.count) items")
                        }
                    )
                }
            }
            ForEach(HomeProfilePresentation.groups(active), id: \.kind) { group in
                TronSettingsGroup(HomeProfilePresentation.groupTitle(group.kind), accent: .tronSessionTeal) {
                    profileRows(group.items, editable: editable)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("home-profile-group-\(group.kind.rawValue)")
            }
            if !inactive.isEmpty {
                TronSettingsGroup("No longer applied", detail: "Superseded or retired items, kept in Knowledge.", accent: .tronSessionTeal) {
                    profileRows(inactive, editable: false)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("home-profile-inactive")
            }
            if list.unclassified > 0 {
                TronSettingsCaption("\(list.unclassified) profile \(list.unclassified == 1 ? "note has" : "notes have") no single kind and \(list.unclassified == 1 ? "is" : "are") not applied.")
            }
        }
    }

    /// Each row opens its item. An inferred item carries a one-tap Confirm, so
    /// confirming never needs the detail sheet.
    private func profileRows(_ items: [HomeProfileListDTO.Item], editable: Bool) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { divider() }
                HStack(spacing: 0) {
                    Button { present(.profileItem(item)) } label: {
                        TronSettingsRow(icon: HomeProfilePresentation.stateIcon(item), title: HomeChapterPresentation.topicPreview(item.text, limit: 160),
                                        subtitle: HomeProfilePresentation.rowSubtitle(item), accent: .tronSessionTeal,
                                        titleFont: TronTypography.sans(size: TronTypography.sizeBody))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home-profile-item-\(item.id)")
                    if editable, item.status == .active, !item.confirmed {
                        Button { confirm(item) } label: {
                            TronInlineActionLabel("Confirm", icon: "checkmark", accent: .tronSessionTeal)
                        }
                        .buttonStyle(.plain)
                        .disabled(profileEdit.working)
                        .padding(.trailing, TronSpacing.section)
                        .accessibilityLabel("Confirm")
                        .accessibilityIdentifier("home-profile-confirm-\(item.id)")
                    }
                }
            }
        }
    }

    func profileItemDetail(_ item: HomeProfileListDTO.Item) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            profileEditNotices()
            TronGlassCard(accent: .tronSessionTeal) {
                VStack(alignment: .leading, spacing: 0) {
                    TronSettingsRow(icon: HomeProfilePresentation.kindIcon(item.kind), title: HomeProfilePresentation.kindTitle(item.kind),
                                    subtitle: HomeProfilePresentation.stateLine(item), accent: .tronSessionTeal) {
                        TronStatusPill(text: HomeProfilePresentation.stateLabel(item), accent: HomeProfilePresentation.stateAccent(item))
                            .accessibilityIdentifier("home-profile-item-state")
                    }
                    divider()
                    markdownText(item.text)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home-profile-item-detail")
            if model.homeProfileEditable, item.status == .active {
                profileItemActions(item)
            }
            TronSettingsGroup("Knowledge note", accent: .tronSessionTeal) {
                VStack(spacing: 0) {
                    TronSettingsRow(icon: "number", title: "Note ID", subtitle: item.id, subtitleLineLimit: nil, accent: .tronSessionTeal)
                        .accessibilityIdentifier("home-profile-item-note-id")
                    divider()
                    TronSettingsRow(icon: "calendar", title: "Learned", subtitle: HomeSheetTime.absolute(item.createdAt), accent: .tronSessionTeal)
                    if item.updatedAt != item.createdAt {
                        divider()
                        TronSettingsRow(icon: "clock.arrow.circlepath", title: "Last changed", subtitle: HomeSheetTime.absolute(item.updatedAt),
                                        accent: .tronSessionTeal)
                    }
                }
            }
        }
    }

    /// Confirm, Edit and Retire. Edit and Retire open the Settings value-editor
    /// pattern: a progressive sheet with Save (or Retire) in its toolbar.
    private func profileItemActions(_ item: HomeProfileListDTO.Item) -> some View {
        TronSettingsGroup("Change", accent: .tronSessionTeal) {
            VStack(spacing: 0) {
                if !item.confirmed {
                    Button { confirm(item) } label: {
                        TronSettingsRow(icon: "checkmark.seal", title: "Confirm",
                                        subtitle: "Make it binding on every Home turn", accent: .tronSessionTeal)
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
                                    subtitle: "Change its text or kind, or replace it", accent: .tronSessionTeal)
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
                                    accent: .tronError, titleColor: .tronError)
                }
                .disabled(profileEdit.working)
                .accessibilityIdentifier("home-profile-item-retire")
            }
        }
    }

    /// The last change made here, with Undo, and a refused change. Shared by the
    /// Profile sheet and an item's sheet.
    @ViewBuilder func profileEditNotices() -> some View {
        if let undo = profileEdit.undo {
            TronGlassCard(accent: .tronSessionTeal) {
                // Undo sits beside the row, not in it: the row reads as one element.
                HStack(spacing: 0) {
                    TronSettingsRow(icon: "checkmark.circle", title: undo.summary,
                                    subtitle: "Applies from Home's next activation", accent: .tronSessionTeal)
                    Button { undoProfileChange(undo) } label: {
                        TronInlineActionLabel("Undo", icon: "arrow.uturn.backward", isWorking: profileEdit.working, accent: .tronSessionTeal)
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

    private func confirm(_ item: HomeProfileListDTO.Item) {
        changeProfile([HomeProfileChange(action: .confirm, id: item.id, expectedRevision: item.revisionId)],
                      done: "Confirmed: \(HomeChapterPresentation.topicPreview(item.text, limit: 60))")
    }

    /// One accepted profile command: it runs under the admission the tap captured and
    /// publishes only while this sheet still shows that profile.
    func changeProfile(_ changes: [HomeProfileChange], done summary: String) {
        guard model.homeProfileEditable, let admission = profileAdmission() else { return }
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
            // A refusal can mean Home changed the item: re-read either way.
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

    /// A profile command is admitted from this sheet or from the editor or confirmation
    /// it presents: while that child covers it, this sheet still publishes data, so the
    /// child's Save runs under this sheet's identity and authority.
    private func profileAdmission() -> HomeControlAdmission? {
        guard let identity, let coordinator, coordinator.activity(for: identity.surfaceToken).allowsDataPublication,
              let authority = try? model.homeMutations.authority(profileID: profileID) else { return nil }
        return HomeControlAdmission(identity: identity, coordinator: coordinator, authority: authority)
    }

    private func publishes(_ admission: HomeControlAdmission) -> Bool {
        identity == admission.identity && admission.coordinator.activity(for: admission.identity.surfaceToken).allowsDataPublication
    }

    /// The item as the latest profile read lists it; the row's copy until that read lands.
    func loadedProfileItem(_ carried: HomeProfileListDTO.Item) -> HomeProfileListDTO.Item {
        switch owner.state {
        case .loaded(let read, .profile(let list)), .loading(let read, .some(.profile(let list))):
            guard read.identity == identity else { return carried }
            return list.items.first { $0.id == carried.id } ?? carried
        default:
            return carried
        }
    }
}

/// A Profile or item sheet's edit state: the change in flight, the last change it
/// made (for Undo), and a refusal.
struct HomeProfileEditState {
    struct Undo: Equatable { let changeID: String; let summary: String }
    struct Failure: Equatable {
        let title: String
        let message: String
        init(title: String, error: any Error) {
            self.title = title
            // An undo refused because Home changed the item names what it holds now.
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
    var confirmingAll = false
}

/// Edits an item's text and kind, the Settings value-editor way: Save in the
/// toolbar, Done to leave. Saving changes the item in place (a refine); with
/// Replace on, it saves a new item and keeps this one as superseded.
struct HomeProfileItemEditor: View {
    let item: HomeProfileListDTO.Item
    let onSave: (HomeProfileChange, String) -> Void
    @State private var text: String
    @State private var kind: HomeProfileListDTO.Item.Kind
    @State private var replaces = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tronSettingsVisualTheme) private var theme

    init(item: HomeProfileListDTO.Item, onSave: @escaping (HomeProfileChange, String) -> Void) {
        self.item = item
        self.onSave = onSave
        _text = State(initialValue: item.text)
        _kind = State(initialValue: item.kind)
    }

    /// The item is one line: line breaks typed here become spaces.
    private var line: String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
    private var changed: Bool { line != item.text || kind != item.kind }
    private var valid: Bool { !line.isEmpty && line.count <= 512 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                TronSettingsGroup("Text", detail: "One line, as Home applies it.", accent: .tronSessionTeal) {
                    TextField("Item text", text: $text, axis: .vertical)
                        .lineLimit(2...8)
                        .tronTextEntryDone(keyboardToolbar: true)
                        .textFieldStyle(.plain)
                        .font(TronTypography.body)
                        .foregroundStyle(Color.tronTextPrimary)
                        .tint(theme?.accent ?? .tronSessionTeal)
                        .padding(.horizontal, TronSpacing.section)
                        .padding(.vertical, TronSpacing.md)
                        .frame(minHeight: 52)
                        .accessibilityIdentifier("home-profile-editor-text")
                }
                TronSettingsGroup("Kind", accent: .tronSessionTeal) {
                    TronChoiceRow(icon: HomeProfilePresentation.kindIcon(kind), title: "Kind",
                                  choices: HomeProfileListDTO.Item.Kind.allCases.map { TronChoice(id: $0, label: HomeProfilePresentation.kindTitle($0)) },
                                  selected: kind, accent: .tronSessionTeal) { kind = $0 }
                }
                TronSettingsGroup("Replace", accent: .tronSessionTeal) {
                    TronToggleRow(icon: "arrow.triangle.2.circlepath", title: "Replace this item",
                                  detail: "Save a new item and keep this one as superseded. Use it when the meaning changes, not to fix wording.",
                                  accent: .tronSessionTeal, isOn: $replaces)
                        .accessibilityIdentifier("home-profile-editor-replace")
                }
                TronSettingsCaption("Your edit is confirmed and applies from Home's next activation. You can undo it.")
            }
            .padding(18)
        }
        .scrollDismissesKeyboard(.interactively)
        .tronScrollEdgeChrome()
        .tronNavigationTitle(replaces ? "Replace item" : "Edit item")
        .tronSaveToolbar(enabled: valid && (changed || replaces)) {
            let preview = HomeChapterPresentation.topicPreview(line, limit: 60)
            if replaces {
                onSave(HomeProfileChange(action: .supersede, id: item.id, expectedRevision: item.revisionId, text: line, kind: kind),
                       "Replaced with: \(preview)")
            } else {
                onSave(HomeProfileChange(action: .refine, id: item.id, expectedRevision: item.revisionId,
                                         text: line == item.text ? nil : line, kind: kind == item.kind ? nil : kind),
                       "Edited: \(preview)")
            }
            dismiss()
        }
    }
}

/// Retires an item with an optional reason, recorded in Changes. Retire sits where
/// Save does, in the destructive role.
struct HomeProfileRetireEditor: View {
    let item: HomeProfileListDTO.Item
    let onRetire: (String?) -> Void
    @State private var reason = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tronSettingsVisualTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                TronSettingsGroup("Item", accent: .tronSessionTeal) {
                    TronSettingsRow(icon: HomeProfilePresentation.kindIcon(item.kind), title: HomeProfilePresentation.kindTitle(item.kind),
                                    subtitle: item.text, subtitleLineLimit: 4, accent: .tronSessionTeal)
                }
                TronSettingsGroup("Reason", detail: "Optional. Shown with the change in Changes.", accent: .tronSessionTeal) {
                    TextField("Why it no longer holds", text: $reason, axis: .vertical)
                        .lineLimit(1...4)
                        .tronTextEntryDone(keyboardToolbar: true)
                        .textFieldStyle(.plain)
                        .font(TronTypography.body)
                        .foregroundStyle(Color.tronTextPrimary)
                        .tint(theme?.accent ?? .tronSessionTeal)
                        .padding(.horizontal, TronSpacing.section)
                        .padding(.vertical, TronSpacing.md)
                        .frame(minHeight: 52)
                        .accessibilityIdentifier("home-profile-retire-reason")
                }
                TronSettingsCaption("Home stops applying it from its next activation. It stays in Knowledge, and you can undo this.")
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

/// One owner of the profile rows' derived text, shared by the Manage Home row,
/// the Profile sheet and the `profile` tool's detail.
enum HomeProfilePresentation {
    struct Group { let kind: HomeProfileListDTO.Item.Kind; let items: [HomeProfileListDTO.Item] }

    /// Items grouped in the Gateway's kind order; the Gateway already orders each kind by creation.
    static func groups(_ items: [HomeProfileListDTO.Item]) -> [Group] {
        HomeProfileListDTO.Item.Kind.allCases.compactMap { kind in
            let members = items.filter { $0.kind == kind }
            return members.isEmpty ? nil : Group(kind: kind, items: members)
        }
    }

    static func groupTitle(_ kind: HomeProfileListDTO.Item.Kind) -> String {
        switch kind {
        case .preference: "Preferences"
        case .standingDecision: "Standing decisions"
        case .delegationDefault: "Delegation defaults"
        case .fact: "Facts"
        }
    }

    static func kindTitle(_ kind: HomeProfileListDTO.Item.Kind) -> String {
        switch kind {
        case .preference: "Preference"
        case .standingDecision: "Standing decision"
        case .delegationDefault: "Delegation default"
        case .fact: "Fact"
        }
    }

    /// The Gateway's kind label as the `profile` tool sends it (`standing-decision`).
    static func kindTitle(wire: String) -> String {
        HomeProfileListDTO.Item.Kind(rawValue: wire).map(kindTitle) ?? wire
    }

    static func kindIcon(_ kind: HomeProfileListDTO.Item.Kind) -> String {
        switch kind {
        case .preference: "hand.thumbsup"
        case .standingDecision: "flag"
        case .delegationDefault: "arrow.triangle.branch"
        case .fact: "info.circle"
        }
    }

    static func stateIcon(_ item: HomeProfileListDTO.Item) -> String {
        switch item.status {
        case .active: item.confirmed ? "checkmark.seal.fill" : "sparkle"
        case .superseded: "arrow.triangle.2.circlepath"
        case .retired: "archivebox"
        }
    }

    static func stateLabel(_ item: HomeProfileListDTO.Item) -> String {
        switch item.status {
        case .active: item.confirmed ? "Confirmed" : "Inferred"
        case .superseded: "Superseded"
        case .retired: "Retired"
        }
    }

    static func stateAccent(_ item: HomeProfileListDTO.Item) -> Color {
        switch item.status {
        case .active: item.confirmed ? .tronEmerald : .tronAmber
        case .superseded, .retired: .tronSlate
        }
    }

    static func stateLine(_ item: HomeProfileListDTO.Item) -> String {
        switch item.status {
        case .active: item.confirmed ? "Binding on every Home turn" : "Home's default until you confirm it"
        case .superseded: "Replaced by a newer item"
        case .retired: "No longer applies"
        }
    }

    /// The row's second line: its state, then the note it is, by its short ID.
    static func rowSubtitle(_ item: HomeProfileListDTO.Item) -> String {
        let state = item.status == .active ? stateLabel(item) : "\(kindTitle(item.kind)) · \(stateLabel(item))"
        return "\(state) · note \(item.id.prefix(8))"
    }
}
