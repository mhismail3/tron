import SwiftUI
import TronMobileCore
import WebKit

struct ArtifactEntry: Decodable, Identifiable {
    let name: String
    let title: String
    let updatedAt: String
    let url: URL
    var day: String?
    var id: String { url.absoluteString }
}

private struct ArtifactsListing: Decodable {
    let tools: [ArtifactEntry]
    let reports: [ArtifactEntry]
}

@MainActor enum ArtifactsPresentation {
    struct Item: Identifiable {
        enum Kind { case header(String, Int), tool(ArtifactEntry), report(ArtifactEntry) }
        let id: String
        let kind: Kind
        let position: Int
    }

    static func items(tools: [ArtifactEntry], reports: [ArtifactEntry]) -> [Item] {
        var items: [Item] = []
        var position = 0
        if !tools.isEmpty {
            items.append(Item(id: "header-tools", kind: .header("Tools", tools.count), position: 1))
            for tool in tools { position += 1; items.append(Item(id: tool.id, kind: .tool(tool), position: position)) }
        }
        var days: [(String, [ArtifactEntry])] = []
        for report in reports {
            let day = report.day ?? ""
            if days.last?.0 == day { days[days.count - 1].1.append(report) } else { days.append((day, [report])) }
        }
        for (day, group) in days {
            items.append(Item(id: "header-day-\(day)", kind: .header(dayTitle(day), group.count), position: position + 1))
            for report in group { position += 1; items.append(Item(id: report.id, kind: .report(report), position: position)) }
        }
        return items
    }

    static func dayTitle(_ day: String, now: Date = .now) -> String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return day }
        if Calendar.current.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now), Calendar.current.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        let sameYear = Calendar.current.isDate(date, equalTo: now, toGranularity: .year)
        return date.formatted(sameYear ? .dateTime.weekday(.abbreviated).month(.abbreviated).day()
                                       : .dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
    }

    static func toolRow(_ tool: ArtifactEntry, now: Date = .now) -> TronListRowContent {
        TronListRowContent(leading: .icon("square.grid.2x2", .tronPrimary), title: tool.title,
                           timestamp: TronListTime.short(iso: tool.updatedAt, now: now),
                           accessibilityHint: "Opens the tool. Touch and hold to open it in Safari.")
    }

    static func reportRow(_ report: ArtifactEntry) -> TronListRowContent {
        TronListRowContent(leading: .icon("doc.text", .tronPrimary), title: report.title,
                           timestamp: GatewayTimestamp.parse(report.updatedAt)?.formatted(date: .omitted, time: .shortened),
                           accessibilityHint: "Opens the report. Touch and hold to open it in Safari.")
    }
}

struct ArtifactsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.tronPresentationActivity) private var activity
    @Environment(\.tronPresentationActivityCoordinator) private var coordinator
    @Environment(\.tronPresentationSurfaceToken) private var token
    @PresentationState private var store = FeedStore<ArtifactsListing, Int, ReadIdentity>()
    @PresentationState private var opened: ArtifactEntry?
    @State private var detent: PresentationDetent = .large // view-local: a reopened sheet starts large so both sections show

    private struct ReadIdentity: PresentationReadIdentity, Hashable {
        let knowledge: KnowledgePresentationIdentity
        func retainsContent(from previous: Self) -> Bool { knowledge.profileID == previous.knowledge.profileID }
    }
    private struct LoadKey: Hashable { let identity: ReadIdentity; let active: Bool }

    private var identity: ReadIdentity { ReadIdentity(knowledge: model.knowledgePresentationIdentity) }
    private var active: Bool { PresentationPublicationPolicy.allows(ambient: activity, coordinator: coordinator, token: token) }
    private var listing: ArtifactsListing? { store.pages.first?.page }
    private var items: [ArtifactsPresentation.Item] {
        listing.map { ArtifactsPresentation.items(tools: $0.tools, reports: $0.reports) } ?? []
    }
    private var tail: TronFeedTail {
        if let error = store.error, store.hasPage { return .failed(error) }
        return store.loading ? .loading : .idle
    }

    var body: some View {
        NavigationStack {
            Group {
                if let listing, listing.tools.isEmpty, listing.reports.isEmpty, store.error == nil, !store.loading {
                    TronFeedEmptyState(identifier: "artifacts-viewport") { caption } placeholder: {
                        TronPlaceholderState(title: "No artifacts yet", detail: "Tools and reports Tron makes for you appear here.", icon: "doc.richtext")
                            .accessibilityIdentifier("artifacts-empty")
                    }
                } else if listing != nil {
                    TronFeed(items: items, identifier: "artifacts-viewport", ordinal: \.position,
                             total: (listing?.tools.count ?? 0) + (listing?.reports.count ?? 0), tail: tail,
                             loadMore: {}, retry: reload) {
                        caption
                    } row: { row($0) }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: TronListMetrics.feedGap) {
                            caption
                            if let error = store.error {
                                TronSettingsNotice(message: "Artifacts could not be loaded. \(error)", retry: reload)
                                    .accessibilityIdentifier("artifacts-error")
                            } else {
                                TronSheetLoadingState(label: "Loading artifacts…", accent: .tronPrimary)
                            }
                        }
                        .padding(.horizontal, 16).padding(.top, 4)
                    }
                    .tronScrollEdgeChrome()
                    .accessibilityIdentifier("artifacts-viewport")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: reload) {
                        TronToolbarTextLabel("Reload", systemImage: "arrow.clockwise", isWorking: store.loading)
                            .tronToolbarAction(accent: .tronPrimary)
                    }.disabled(!active || store.loading)
                }
                ToolbarItem(placement: .principal) { TronSheetTitle(title: "Artifacts", accent: .tronPrimary) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark").font(TronTypography.buttonSM).tronToolbarAction(accent: .tronPrimary)
                    }.accessibilityLabel("Done")
                }
            }
            .task(id: LoadKey(identity: identity, active: active)) {
                guard active else { store.suspend(); return }
                guard let request = store.request(for: identity) else { return }
                await load(request)
            }
            .onChange(of: active) { _, active in if !active { store.suspend() } }
            .onPresentationRetire { store.suspend() }
            .tronManagedSheet(item: $opened, identity: { "artifacts.open.\($0.id)" }) { ArtifactViewer(entry: $0) }
        }
        .tronTopBlur(.sheet).presentationDetents([.medium, .large], selection: $detent).presentationDragIndicator(.hidden)
        .tronSettingsVisualTheme(accent: .tronPrimary).tint(.tronPrimary)
    }

    private var caption: some View {
        TronSettingsCaption("Tools stay current and are ordered by last update. Reports are one-off pages, newest day first.")
            .containerValue(\.tronSettingsSection, false)
    }

    @ViewBuilder private func row(_ item: ArtifactsPresentation.Item) -> some View {
        switch item.kind {
        case .header(let title, let count):
            TronListSectionHeader(title: title, count: count)
                .padding(.top, item.position > 1 ? TronListMetrics.sectionGap - TronListMetrics.feedGap : 0)
                .accessibilityIdentifier("artifacts-\(item.id)")
        case .tool(let entry): card(entry, ArtifactsPresentation.toolRow(entry))
        case .report(let entry): card(entry, ArtifactsPresentation.reportRow(entry))
        }
    }

    private func card(_ entry: ArtifactEntry, _ content: TronListRowContent) -> some View {
        TronFeedCard {
            TronListButton(content, identifier: "artifact-row-\(entry.name)", action: { opened = entry }) {
                Button("Open in Safari", systemImage: "safari") { openURL(entry.url) }
            }
        }
        .tronListMarker(.container)
        .tronListMarkers("artifact-card-\(entry.name)")
    }

    private func load(_ request: FeedStore<ArtifactsListing, Int, ReadIdentity>.Request) async {
        let identity = identity
        await store.load(request, identity: identity, isCurrent: { active && self.identity == identity }) { _ in
            try await model.client.request("artifacts.list", EmptyParams())
        }
    }

    private func reload() {
        guard active, !store.loading else { return }
        Task { await load(.reset) }
    }
}

private struct ArtifactViewer: View {
    let entry: ArtifactEntry
    @Environment(\.openURL) private var openURL
    @PresentationState private var failure: String?

    var body: some View {
        TronDocumentSheet(title: entry.title, leadingAction: TronDocumentSheetAction(
            systemImage: "safari", accessibilityLabel: "Open in Safari", action: { openURL(entry.url) })) {
            if let failure {
                TronPlaceholderState(title: "The page could not be opened", detail: failure, icon: "exclamationmark.triangle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ArtifactWebView(url: entry.url) { failure = $0 }
            }
        }
    }
}

private struct ArtifactWebView: UIViewRepresentable {
    let url: URL
    let failed: @MainActor (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(failed: failed) }

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = UIColor(Color.tronBackground)
        view.accessibilityIdentifier = "artifact-viewer"
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let failed: @MainActor (String) -> Void
        init(failed: @escaping @MainActor (String) -> Void) { self.failed = failed }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            report(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            report(error)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }

        private func report(_ error: any Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            failed(error.localizedDescription)
        }
    }
}
