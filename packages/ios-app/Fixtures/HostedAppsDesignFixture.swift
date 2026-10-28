#if HOSTED_TEST
import SwiftUI
import TronMobileCore

/// Design-only proposal for #2076. Synthetic catalog, no installed-app RPCs,
/// disk mutations, migration, hosting or production Apps entry. All geometry,
/// typography, glass, tags and navigation belong to existing shared components.
struct HostedAppsDesignFixture: View {
    @State private var presented = false
    private var dark: Bool { ProcessInfo.processInfo.arguments.contains("-apps-design-dark") }

    var body: some View {
        TronPresentationSurface(id: "hosted-apps-design") {
            Button("Review Apps proposal") { presented = true }
                .buttonStyle(.plain)
                .font(TronTypography.body)
                .accessibilityIdentifier("apps-design-present")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.tronBackground)
                .tronManagedSheet(isPresented: $presented, identity: "apps.design") {
                    AppsDesignList()
                }
        }
        .tronPresentation()
        .preferredColorScheme(dark ? .dark : .light)
    }
}

private enum AppsDesignReview {
    /// Capture the expanded presentation without claiming that a still image
    /// proves the native medium-to-large drag. Normal interaction starts medium.
    static var detent: PresentationDetent {
        ProcessInfo.processInfo.arguments.contains("-apps-design-expanded") ? .large : .medium
    }
}

private struct AppsDesignItem: Identifiable {
    let id: String
    let name: String
    let kind: String
    let icon: String
    let detail: String
    static let samples: [Self] = [
        .init(id: "habits", name: "Daily habits", kind: "Swift app", icon: "swift", detail: "Studio server · Source revision 4"),
        .init(id: "reading", name: "Reading list", kind: "Web app", icon: "globe", detail: "Studio server · Source revision 2"),
        .init(id: "notes", name: "Project notes", kind: "Page", icon: "doc.text", detail: "Studio server · Source revision 1"),
    ]
    @MainActor var row: TronListRowContent {
        TronListRowContent(leading: .icon(icon, .tronPrimary), title: name, subtext: detail,
                           tags: [TronListTag(text: kind)], accessibilityHint: "Opens artifact. Touch and hold for Open and Manage.")
    }
}

private struct AppsDesignList: View {
    @PresentationState private var managed: AppsDesignItem?
    @PresentationState private var launch: SwiftAppLaunch?
    @PresentationState private var longList = false
    @PresentationState private var loaded = 20
    private let total = 64
    private var feedItems: [AppsDesignItem] {
        (0..<min(loaded, total)).map { index in
            let sample = AppsDesignItem.samples[index % 3]
            return AppsDesignItem(id: "item-\(index)", name: "\(sample.name) \(index + 1)", kind: sample.kind,
                                  icon: sample.icon, detail: sample.detail)
        }
    }

    var body: some View {
        TronDocumentSheet(title: "Apps", detents: [.medium, .large], initialDetent: AppsDesignReview.detent,
                          leadingAction: TronDocumentSheetAction(systemImage: "list.bullet", accessibilityLabel: "Preview long catalog") {
            longList.toggle()
        }) {
            Group {
                if longList {
                    TronFeed(items: feedItems, identifier: "apps-design-feed", ordinal: { item in
                        Int(item.id.dropFirst(5))! + 1
                    }, total: total, tail: loaded >= total ? .end("All apps") : .idle, loadMore: {
                        loaded = min(loaded + 20, total)
                    }, retry: {}) {
                        EmptyView()
                    } row: { item in TronFeedCard { row(item) } }
                } else {
                    ScrollView {
                        TronSettingsSections(hidesLoneHeading: true) {
                            TronListGroup(AppsDesignItem.samples, hasLeading: true, identifier: "apps-design-group") { row($0) }
                        }
                        .padding(.horizontal, 16).padding(.top, 4)
                    }
                    .tronScrollEdgeChrome()
                }
            }
            .tronManagedSheet(item: $managed, identity: { "apps.design.manage.\($0.id)" }) { item in
                AppsDesignManage(item: item)
            }
            .tronManagedSheet(item: $launch, identity: { "apps.design.run.\($0.id)" }) { launch in
                SwiftAppRunnerSheet(launch: launch)
            }
        }
    }

    private func row(_ item: AppsDesignItem) -> some View {
        TronListButton(item.row, identifier: "apps-design-row-\(item.id)", action: { open(item) }) {
            Button("Open", systemImage: "arrow.up.forward.app") { open(item) }
            Button("Manage", systemImage: "slider.horizontal.3") { managed = item }
        }
    }

    private func open(_ item: AppsDesignItem) {
        // The only executable proposal is a Swift fixture. Other kinds remain
        // visibly design-only rather than pretending an HTML bridge exists.
        if item.kind == "Swift app" {
            launch = SwiftAppLaunch(name: item.name, source: """
                import SwiftUI
                struct Habits: View {
                    @State var count = 0
                    var body: some View {
                        VStack {
                            Text("Habits completed: \\(count)")
                            Button("Complete a habit") { count += 1 }
                        }.navigationTitle("Daily habits")
                    }
                }
                """, linkHost: nil)
        } else { managed = item }
    }
}

private enum AppsDesignDestination: String, Identifiable {
    case history = "History", data = "Data", metadata = "Metadata & Configuration", sessions = "Touched Sessions"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .history: "clock.arrow.circlepath"
        case .data: "externaldrive"
        case .metadata: "slider.horizontal.3"
        case .sessions: "bubble.left.and.bubble.right"
        }
    }
    var subtitle: String {
        switch self {
        case .history: "4 source versions · State revision 12"
        case .data: "3 keys · Stored on your Mac"
        case .metadata: "Type, source, permissions and feeds"
        case .sessions: "2 sessions · Created and updated"
        }
    }
}

private struct AppsDesignManage: View {
    let item: AppsDesignItem
    @PresentationState private var child: AppsDesignDestination?
    var body: some View {
        TronDocumentSheet(title: "Manage Artifact", detents: [.medium, .large], initialDetent: AppsDesignReview.detent) {
            ScrollView {
                TronSettingsSections(alignment: .leading, spacing: 18, hidesLoneHeading: true) {
                    TronSettingsGroup(nil) {
                        VStack(spacing: 0) {
                            TronSettingsRow(icon: item.icon, title: item.name, subtitle: item.detail,
                                            subtitleColor: .tronTextSecondary) {
                                ResourceTagLabel(title: item.kind, accent: .tronTextSecondary)
                            }
                        }
                    }
                    TronSettingsGroup(nil) {
                        VStack(spacing: 0) {
                            ForEach(Array([AppsDesignDestination.history, .data, .metadata, .sessions].enumerated()), id: \.element.id) { index, destination in
                                if index > 0 { TronSettingsDivider(accent: .tronPrimary) }
                                Button { child = destination } label: {
                                    TronSettingsRow(icon: destination.icon, title: destination.rawValue,
                                                    subtitle: destination.subtitle, subtitleColor: .tronTextSecondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("apps-design-manage-\(destination.id)")
                            }
                        }
                    }
                }
                .padding(18)
            }
            .tronScrollEdgeChrome()
            .accessibilityIdentifier("apps-design-manage-scroll")
            .tronManagedSheet(item: $child, identity: { "apps.design.child.\($0.id)" }) { destination in
                AppsDesignBrowser(destination: destination)
            }
        }
    }
}

private struct AppsDesignBrowser: View {
    let destination: AppsDesignDestination
    var body: some View {
        TronDocumentSheet(title: destination.rawValue, detents: [.medium, .large], initialDetent: .medium) {
            ScrollView {
                TronSettingsSections(hidesLoneHeading: true) {
                    if destination == .data || destination == .metadata {
                        TronMetadataTable(accent: .tronPrimary, rows: destination == .data ? [
                            .init(id: "count", title: "Completed", value: "7", type: "number"),
                            .init(id: "goal", title: "Daily goal", value: "3", type: "number"),
                            .init(id: "days", title: "Days", value: "[Mon, Tue, Wed]", type: "array"),
                        ] : [
                            .init(id: "id", title: "ID", value: "habits"),
                            .init(id: "kind", title: "Type", value: "Swift app"),
                            .init(id: "feed", title: "Feeds", value: "None"),
                        ])
                    } else {
                        TronListGroup(rows) { entry in TronListRow(entry.content) }
                    }
                }
                .padding(18)
            }.tronScrollEdgeChrome()
        }
    }
    private struct Entry: Identifiable { let id: String; let content: TronListRowContent }
    private var rows: [Entry] {
        if destination == .history {
            return (1...4).reversed().map { revision in
                Entry(id: "revision-\(revision)", content: .init(title: "Source revision \(revision)",
                    subtext: "Updated by session · Build a habits app", tags: [TronListTag(text: "Swift app")]))
            }
        }
        return [Entry(id: "creator", content: .init(title: "Build a habits app", subtext: "Created · Source revision 1")),
                Entry(id: "editor", content: .init(title: "Refine daily goals", subtext: "Updated · Source revision 4"))]
    }
}
#endif
