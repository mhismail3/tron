import SwiftUI
import TronMobileCore

struct ArtifactEntry: Decodable, Hashable, Identifiable {
    let name: String
    let url: URL
    var id: String { name }
    var date: String { String(name.prefix(10)) }
    var title: String { String(name.dropFirst(11)).replacingOccurrences(of: "-", with: " ") }
}

struct ArtifactsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var activity
    @Environment(\.openURL) private var openURL
    @PresentationState private var artifacts: [ArtifactEntry]?
    @PresentationState private var failure: String?
    @PresentationState private var opened: ArtifactEntry?

    private struct Listing: Decodable { let artifacts: [ArtifactEntry] }

    var body: some View {
        TronDocumentSheet(title: "Artifacts", detents: [.medium, .large], initialDetent: .large) {
            ScrollView {
                TronSettingsSections(hidesLoneHeading: true) {
                    if let failure {
                        TronInfoCard(icon: "exclamationmark.triangle", text: failure, accent: .tronAmber)
                            .accessibilityIdentifier("artifacts-error")
                    }
                    if let artifacts {
                        if artifacts.isEmpty {
                            TronInfoCard(icon: "doc.richtext", text: "No artifacts yet. Pages Tron makes for you appear here, newest first.")
                                .accessibilityIdentifier("artifacts-empty")
                        } else {
                            TronListGroup(artifacts, hasLeading: true, identifier: "artifacts-list") { artifact in
                                TronListButton(
                                    TronListRowContent(leading: .icon("doc.richtext", .tronPrimary), title: artifact.title,
                                                       timestamp: artifact.date, accessibilityHint: "Opens the artifact. Touch and hold to open it in Safari."),
                                    identifier: "artifact-row-\(artifact.name)", action: { opened = artifact }
                                ) {
                                    Button("Open in Safari", systemImage: "safari") { openURL(artifact.url) }
                                }
                            }
                        }
                    } else if failure == nil {
                        TronLoadingState(label: "Loading artifacts")
                    }
                }
                .padding(.horizontal, 16).padding(.top, 4)
            }
            .tronScrollEdgeChrome()
            .refreshable { await load() }
            .task(id: PresentationActivityTaskID(source: "\(model.knowledgePresentationIdentity)", presentationActive: activity.allowsPresentationPublication)) { await load() }
            .tronManagedSheet(item: $opened, identity: { "artifacts.open.\($0.id)" }) { artifact in
                TronSafariView(url: artifact.url)
                    .ignoresSafeArea(.container, edges: .all)
                    .accessibilityIdentifier("artifact-browser")
                    .presentationDetents([.large])
                    .presentationDragIndicator(.hidden)
            }
        }
    }

    private func load() async {
        guard activity.allowsPresentationPublication else { return }
        let identity = model.knowledgePresentationIdentity
        do {
            let listing: Listing = try await model.client.request("artifacts.list", EmptyParams())
            guard identity == model.knowledgePresentationIdentity else { return }
            artifacts = listing.artifacts
            failure = nil
        } catch is CancellationError {
        } catch {
            guard identity == model.knowledgePresentationIdentity else { return }
            failure = "Artifacts could not be loaded. \(error.localizedDescription)"
        }
    }
}
