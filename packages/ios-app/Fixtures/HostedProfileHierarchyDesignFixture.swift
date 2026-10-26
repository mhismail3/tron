#if HOSTED_TEST
import SwiftUI

/// Design-only native preview. Illustrative records, no Knowledge or Gateway access.
/// Reuses the Profile sheet's shared list, typography, chrome and presentation owners.
struct HostedProfileHierarchyDesignFixture: View {
    @State private var presented = true
    private var args: [String] { ProcessInfo.processInfo.arguments }
    private var page: String {
        guard let index = args.firstIndex(of: "-profile-design-page"), args.indices.contains(index + 1) else { return "root" }
        return args[index + 1]
    }
    var body: some View {
        Color.tronBackground.ignoresSafeArea()
            .tronManagedSheet(isPresented: $presented, identity: "design.profile-hierarchy") {
                ProfileDesignPage(page: page)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.hidden)
                    .tronPresentation()
                    .tronSettingsLayout()
                    .dynamicTypeSize(args.contains("-profile-design-xxl") ? .xxLarge : .large)
            }
            .preferredColorScheme(args.contains("-profile-design-dark") ? .dark : .light)
    }
}

private struct ProfileDesignRow: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    init(_ id: String, _ title: String, _ subtitle: String) {
        self.id = id; self.title = title; self.subtitle = subtitle
    }
}

private struct ProfileDesignPage: View {
    let page: String
    @Environment(\.dismiss) private var dismiss
    private var title: String {
        switch page {
        case "engineering": "Engineering"
        case "inferred": "Inferred notes"
        case "triage": "Review note"
        default: "Profile"
        }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                TronSettingsSections(alignment: .leading, spacing: 18) {
                    TronSettingsCaption("Design preview · Illustrative content")
                        .containerValue(\.tronSettingsSection, false)
                    content
                }
                .padding(18)
            }
            .accessibilityIdentifier("profile-design-scroll")
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { TronSheetTitle(title: title, accent: .tronEmerald) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark").font(TronTypography.buttonSM).tronToolbarAction(accent: .tronEmerald)
                    }
                    .accessibilityLabel("Done")
                }
            }
        }
        .tronTopBlur(.sheet)
        .tronSettingsVisualTheme(accent: .tronEmerald)
    }

    @ViewBuilder private var content: some View {
        switch page {
        case "engineering": engineering
        case "inferred": inferred
        case "triage": triage
        default: root
        }
    }

    private var root: some View {
        Group {
            TronSettingsCaption("About you, not a project rulebook. Home reads what it needs; placement does not grant permission.")
                .containerValue(\.tronSettingsSection, false)
            TronListGroup([ProfileDesignRow("inferred", "Review inferred notes", "4 unsorted · Not confirmed")], identifier: "profile-design-holding") { row in
                TronProgressiveSheetLink(accessibilityLabel: row.title, identity: "profile-design.inferred") {
                    ProfileDesignPage(page: "inferred")
                } label: {
                    TronListRow(TronListRowContent(title: row.title, subtext: row.subtitle))
                }
                .accessibilityIdentifier("profile-design-review")
            }
            TronListGroup(sections: [TronListSection(title: "About you", rows: Self.areas)], identifier: "profile-design-areas") { row in
                if row.id == "engineering" {
                    TronProgressiveSheetLink(accessibilityLabel: row.title, identity: "profile-design.engineering") {
                        ProfileDesignPage(page: "engineering")
                    } label: {
                        TronListRow(TronListRowContent(title: row.title, subtext: row.subtitle))
                    }
                    .accessibilityIdentifier("profile-design-engineering")
                } else {
                    TronListRow(TronListRowContent(title: row.title, subtext: row.subtitle))
                }
            }
            TronSettingsCaption("Changes & undo remain in Settings › Changes. No “confirm all”: review meaning and destination first.")
                .containerValue(\.tronSettingsSection, false)
        }
    }

    private static let areas = [
        ProfileDesignRow("life", "Life & people", "Identity · Relationships · Practical details"),
        ProfileDesignRow("routines", "Routines & wellbeing", "Day-to-day · Availability · Wellbeing"),
        ProfileDesignRow("communication", "Communication", "Answers · Questions · Tone"),
        ProfileDesignRow("engineering", "Engineering", "Architecture · Testing · Collaboration"),
        ProfileDesignRow("resources", "Machines & resources", "Compute · Storage · Cleanup"),
        ProfileDesignRow("devices", "Devices & services", "Devices · Subscriptions · Renewals"),
        ProfileDesignRow("projects", "Projects", "Ownership & pointers only"),
        ProfileDesignRow("corrections", "Corrections", "What Home got wrong about you")
    ]

    private var engineering: some View {
        Group {
            TronSettingsCaption("Profile › Engineering. Personal standards stay here; repository-specific rules live with their project.")
                .containerValue(\.tronSettingsSection, false)
            TronListGroup(sections: [
                TronListSection(title: "Architecture", rows: [ProfileDesignRow("simple", "Prefer the simplest robust implementation.", "Standing decision · Inferred")]),
                TronListSection(title: "Testing", rows: [ProfileDesignRow("e2e", "Prefer E2E, then integration tests.", "Preference · Inferred")]),
                TronListSection(title: "Collaboration", rows: [ProfileDesignRow("scope", "Keep work tightly scoped to what I asked.", "Standing decision · Inferred")])
            ], identifier: "profile-design-subareas") { row in
                TronListRow(TronListRowContent(title: row.title, preview: true, subtext: row.subtitle))
            }
            TronSettingsCaption("Illustrative excerpts, not rewritten live notes. Open a record for exact text, evidence, confirmation, last seen and history.")
                .containerValue(\.tronSettingsSection, false)
        }
    }

    private var inferred: some View {
        Group {
            TronSettingsCaption("Home saved these during chats. Review where each belongs before it becomes an instruction.")
                .containerValue(\.tronSettingsSection, false)
            TronListGroup(sections: [TronListSection(title: "Unsorted", rows: [
                ProfileDesignRow("questions", "When asking a decision, recommend an option and explain why.", "Suggested: Communication › Questions"),
                ProfileDesignRow("repo", "Keep this project’s setup instructions in AGENTS.md.", "Suggested: Project instructions"),
                ProfileDesignRow("procedure", "Use the shared signing procedure for this app.", "Suggested: Skill or prompt"),
                ProfileDesignRow("setting", "Change the worker model queue.", "Suggested: Settings")
            ])], identifier: "profile-design-inferred") { row in
                if row.id == "questions" {
                    TronProgressiveSheetLink(accessibilityLabel: "Review decision-question note", identity: "profile-design.triage") {
                        ProfileDesignPage(page: "triage")
                    } label: {
                        TronListRow(TronListRowContent(title: row.title, preview: true, subtext: row.subtitle))
                    }
                    .accessibilityIdentifier("profile-design-triage")
                } else {
                    TronListRow(TronListRowContent(title: row.title, preview: true, subtext: row.subtitle))
                }
            }
            TronSettingsCaption("Suggestions are Home’s judgment, not automatic routing. Nothing moves without a recorded outcome; binding moves need your tap.")
                .containerValue(\.tronSettingsSection, false)
        }
    }

    private var triage: some View {
        Group {
            TronSettingsCaption("Inferred notes › Review. Nothing has changed.")
                .containerValue(\.tronSettingsSection, false)
            TronSettingsGroup("Note", accent: .tronEmerald) {
                TronSettingsRow(icon: nil, title: "When asking a decision, recommend an option and explain why.",
                                subtitle: "Inferred · Preference · Illustrative chat evidence", subtitleLineLimit: nil, accent: .tronEmerald)
            }
            TronSettingsGroup("Proposed destination", accent: .tronEmerald) {
                TronSettingsRow(icon: "person.text.rectangle", title: "Communication › Questions", subtitle: "About how you want to be asked, not a repo procedure.", subtitleLineLimit: nil, accent: .tronEmerald)
            }
            TronSettingsGroup("Approval", accent: .tronEmerald) {
                TronSettingsRow(icon: "hand.tap", title: "Confirm & move", subtitle: "Makes this exact preference confirmed. Needs your tap; Home cannot approve it.", subtitleLineLimit: nil, accent: .tronEmerald)
            }
            TronSettingsGroup("Other destinations", accent: .tronEmerald) {
                TronSettingsRow(icon: nil, title: "Project instructions · Skill or prompt · Settings · Retire", subtitle: "Keep inferred or leave unsorted if uncertain.", subtitleLineLimit: nil, accent: .tronEmerald)
            }
            TronSettingsCaption("On apply: one logged change with exact before/after, evidence and Undo in Changes. This preview has no apply action.")
                .containerValue(\.tronSettingsSection, false)
        }
    }
}
#endif
