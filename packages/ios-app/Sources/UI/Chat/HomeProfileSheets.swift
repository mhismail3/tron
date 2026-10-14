import SwiftUI
import TronMobileCore

/// The learned profile: what Home has saved about the maintainer as Knowledge
/// notes, grouped by kind in the order Home applies them. Read-only; Home changes
/// it with its `profile` tool. An item's detail comes from the row already loaded.
extension HomeSheet {
    func profile(_ list: HomeProfileListDTO) -> some View {
        let active = list.active
        let inactive = list.items.filter { $0.status != .active }
        return VStack(alignment: .leading, spacing: 18) {
            TronSettingsCaption("Learned from your messages to Home. Confirmed items are binding; inferred items are Home's default until you confirm them.")
            if active.isEmpty {
                TronPlaceholderState(title: "Nothing learned yet",
                                     detail: "Home saves durable preferences, decisions, delegation defaults and facts you state.",
                                     icon: "person.text.rectangle")
            }
            ForEach(HomeProfilePresentation.groups(active), id: \.kind) { group in
                TronSettingsGroup(HomeProfilePresentation.groupTitle(group.kind), accent: .tronSessionTeal) {
                    profileRows(group.items)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("home-profile-group-\(group.kind.rawValue)")
            }
            if !inactive.isEmpty {
                TronSettingsGroup("No longer applied", detail: "Superseded or retired items, kept in Knowledge.", accent: .tronSessionTeal) {
                    profileRows(inactive)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("home-profile-inactive")
            }
            if list.unclassified > 0 {
                TronSettingsCaption("\(list.unclassified) profile \(list.unclassified == 1 ? "note has" : "notes have") no single kind and \(list.unclassified == 1 ? "is" : "are") not applied.")
            }
        }
    }

    private func profileRows(_ items: [HomeProfileListDTO.Item]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { divider() }
                Button { present(.profileItem(item)) } label: {
                    TronSettingsRow(icon: HomeProfilePresentation.stateIcon(item), title: HomeChapterPresentation.topicPreview(item.text, limit: 160),
                                    subtitle: HomeProfilePresentation.rowSubtitle(item), accent: .tronSessionTeal,
                                    titleFont: TronTypography.sans(size: TronTypography.sizeBody))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home-profile-item-\(item.id)")
            }
        }
    }

    func profileItemDetail(_ item: HomeProfileListDTO.Item) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            TronGlassCard(accent: .tronSessionTeal) {
                VStack(alignment: .leading, spacing: 0) {
                    TronSettingsRow(icon: HomeProfilePresentation.kindIcon(item.kind), title: HomeProfilePresentation.kindTitle(item.kind),
                                    subtitle: HomeProfilePresentation.stateLine(item), accent: .tronSessionTeal) {
                        TronStatusPill(text: HomeProfilePresentation.stateLabel(item), accent: HomeProfilePresentation.stateAccent(item))
                    }
                    divider()
                    markdownText(item.text)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home-profile-item-detail")
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
        case .active: item.confirmed ? "checkmark.seal" : "sparkle"
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
        case .active: item.confirmed ? .tronEmerald : .tronSessionTeal
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
