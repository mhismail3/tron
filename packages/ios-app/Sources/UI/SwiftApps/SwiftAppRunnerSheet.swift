import SwiftUI
import TronSwiftAppEngine

/// Experimental gate for running displayed `.swift` files (#889), an
/// iPhone-only preference. Off by default, so normal use never shows the
/// control. Settings › System › Experimental owns the switch; launching
/// with `-tron.experimental.swiftApps YES|NO` sets the same stored choice, so
/// a device launched through `devicectl`/`simctl` keeps it across later normal
/// launches.
///
/// Reads go through this observable owner, never straight to `UserDefaults`:
/// a launch argument shadows the stored value for the whole process, which
/// would hide a later Settings change, and observation lets an open document
/// sheet gain or lose its run control as soon as the switch changes.
@MainActor
@Observable
final class SwiftAppExperiment {
    static let shared = SwiftAppExperiment(defaults: .standard)
    nonisolated static let defaultsKey = "tron.experimental.swiftApps"

    private let defaults: UserDefaults

    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.defaultsKey) }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let launchValue = defaults.volatileDomain(forName: UserDefaults.argumentDomain)[Self.defaultsKey] {
            let enabled = (launchValue as? NSString)?.boolValue ?? (launchValue as? Bool ?? false)
            defaults.set(enabled, forKey: Self.defaultsKey)
            isEnabled = enabled
        } else {
            isEnabled = defaults.bool(forKey: Self.defaultsKey)
        }
    }

    func canRun(fileNamed name: String) -> Bool {
        isEnabled && name.lowercased().hasSuffix(".swift")
    }
}

struct SwiftAppLaunch: Identifiable {
    let id = UUID()
    let name: String
    let source: String
    /// The paired Gateway's host: the only host the program's links may open (#1160).
    let linkHost: String?
    /// Only an installed launch supplies this Gateway-owned state projection.
    let installed: InstalledSwiftAppSession?

    init(name: String, source: String, linkHost: String?, installed: InstalledSwiftAppSession? = nil) {
        self.name = name
        self.source = source
        self.linkHost = linkHost
        self.installed = installed
    }
}

/// Runs one interpreted single-file SwiftUI app in a large sheet. Dismissing
/// discards the program and @State; accepted installed-state writes retain their owner.
///
/// The program is hosted in Tron's shared `TronDocumentSheet` (#909): detents,
/// sheet material, tint and typography. Its first real view sits in a
/// `SwiftAppHostStack` with the shared sheet chrome (title, Done); a root
/// TabView gets one per tab. Tron's theme is the environment default, so plain
/// SwiftUI looks like Tron, and anything the program sets explicitly is applied
/// closer to its views and wins.
struct SwiftAppRunnerSheet: View {
    let launch: SwiftAppLaunch
    @PresentationState private var runtime: Result<SwiftAppRuntime, Error>
    @Environment(\.openURL) private var openURL
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @PresentationState private var activeSession: InstalledSwiftAppSession?

    init(launch: SwiftAppLaunch) {
        self.launch = launch
        _activeSession = PresentationState(wrappedValue: launch.installed)
        _runtime = PresentationState(wrappedValue: Result { try Self.makeRuntime(launch) })
    }

    private static func makeRuntime(_ launch: SwiftAppLaunch) throws -> SwiftAppRuntime {
        let persistence = launch.installed.map { session in
            SwiftAppPersistence(entries: session.entries) { writes in
                session.accept(Dictionary(uniqueKeysWithValues: writes.map { ($0.key, $0.value) }))
            }
        }
        let feeds = launch.installed?.snapshot.feeds
        let manifests = feeds.map { $0.values.flatMap { $0.builds.map(\.manifestURL) } }
        return try SwiftAppRuntime(source: launch.source,
            linkPolicy: SwiftAppLinkPolicy(host: launch.linkHost, manifestURLs: manifests), persistence: persistence, feeds: feeds)
    }

    private var fileTitle: String {
        launch.name.lowercased().hasSuffix(".swift") ? String(launch.name.dropLast(6)) : launch.name
    }

    var body: some View {
        Group {
        switch runtime {
        case .success(let runtime):
            TronDocumentSheet(title: fileTitle, hostsNavigation: false) {
                refreshableRunning(runtime)
                    .onDisappear { runtime.stopAllTimers() }
                    // An install opens at once: iOS asks before installing.
                    .onChange(of: runtime.pendingLink) { _, link in
                        guard let link, !link.needsConfirmation else { return }
                        runtime.pendingLink = nil
                        openURL(link.url)
                    }
                    .tronConfirmation("Open link?", isPresented: Binding(
                        get: { runtime.pendingLink?.needsConfirmation == true },
                        set: { if !$0 { runtime.pendingLink = nil } }
                    ), presenting: runtime.pendingLink) { link in
                        Button("Open") { openURL(link.url) }
                    } message: { link in
                        Text(verbatim: link.url.absoluteString)
                    }
            }
        case .failure(let error):
            TronDocumentSheet(title: launch.name) {
                ScrollView {
                    TronInfoCard(
                        icon: "exclamationmark.triangle",
                        text: "This file uses Swift outside the supported SwiftUI subset.\n\n\(error)",
                        accent: .tronBlue
                    )
                    .padding(TronSpacing.xlarge)
                    .accessibilityIdentifier("swiftApp.unsupported")
                }
            }
        }
        }
        .onAppear { activeSession?.present(launch.id) }
        .onDisappear { activeSession?.dismiss(launch.id) }
    }

#if HOSTED_TEST
    @State private var hostedRefreshCalls = 0
#endif

    private func refresh(_ previous: SwiftAppRuntime) async {
#if HOSTED_TEST
        hostedRefreshCalls += 1
#endif
        guard let session = activeSession else { return }
        await session.settle()
        guard !Task.isCancelled, presentationActivity.allowsPresentationPublication,
              model.selectedGatewayProfileID() == session.profileID else { return }
        do {
            guard !session.hasUnsavedChanges else { throw InstalledSwiftAppFailure("Resolve this app's unsaved changes before refreshing.") }
            var prepared: SwiftAppRuntime?
            let fresh = try await model.installedApps.open(appID: session.snapshot.app.id, profileID: session.profileID, prepare: { fresh in
                guard !Task.isCancelled, presentationActivity.allowsPresentationPublication,
                      model.selectedGatewayProfileID() == session.profileID,
                      case .success(let current) = runtime, current === previous else { throw CancellationError() }
                let candidate = SwiftAppLaunch(name: fresh.snapshot.app.name, source: fresh.snapshot.source,
                    linkHost: model.profiles.selected?.host, installed: fresh)
                prepared = try Self.makeRuntime(candidate)
            })
            guard !Task.isCancelled, presentationActivity.allowsPresentationPublication,
                  model.selectedGatewayProfileID() == session.profileID,
                  case .success(let current) = runtime, current === previous else { return }
            guard fresh !== session, !fresh.hasUnsavedChanges, let replacement = prepared else {
                throw InstalledSwiftAppFailure("Resolve this app's unsaved changes before refreshing.")
            }
            previous.stopAllTimers()
            session.dismiss(launch.id)
            fresh.present(launch.id)
            activeSession = fresh
            runtime = .success(replacement)
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, presentationActivity.allowsPresentationPublication,
                  case .success(let current) = runtime, current === previous else { return }
            previous.actionError = "Refresh failed. \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private func refreshableRunning(_ runtime: SwiftAppRuntime) -> some View {
        if activeSession != nil { running(runtime).refreshable { await refresh(runtime) } }
        else { running(runtime) }
    }

    @ViewBuilder
    private func running(_ runtime: SwiftAppRuntime) -> some View {
        if let root = runtime.rootDeclaration {
            SwiftAppCustomView(runtime: runtime, node: SwiftAppViewNode(name: root.name, arguments: [], declaration: root))
                // A refreshed interpreter has new globals/persistence slots.
                // Never carry a prior program's @State scopes into that runtime.
                .id(ObjectIdentifier(runtime))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(\.swiftAppHostChrome, SwiftAppHostChrome(title: fileTitle))
                // Lists and Forms show the shared sheet material, like Tron's
                // own sheets; a program's own scrollContentBackground wins.
                .scrollContentBackground(.hidden)
                .overlay(alignment: .bottom) {
                    if let message = activeSession?.failure ?? runtime.actionError {
                        SwiftAppErrorView(message: message)
                            .padding(TronSpacing.xlarge)
                    }
                }
#if HOSTED_TEST
                .overlay(alignment: .bottomLeading) {
                    Text("Feed snapshot: \(activeSession?.snapshot.feeds?["ios-builds"]?.status ?? "none"), builds: \(activeSession?.snapshot.feeds?["ios-builds"]?.builds.count ?? -1), refresh calls: \(hostedRefreshCalls), active: \(presentationActivity.allowsPresentationPublication)")
                        .accessibilityIdentifier("swiftApp.feedProbe")
                        .opacity(0.01)
                        .frame(width: 1, height: 1)
                }
                .overlay(alignment: .topLeading) {
                    Text("Timer callbacks: \(runtime.hostedTimerCallbackCount), subscriptions: \(runtime.hostedTimerSubscriptionCount), global: \(SwiftAppTimerTestProbe.shared.activeSubscriptions)")
                        .accessibilityIdentifier("swiftApp.timerProbe")
                        .opacity(0.01)
                        .frame(width: 1, height: 1)
                }
                .overlay(alignment: .topTrailing) {
                    let opened = SwiftAppLinkTestProbe.shared.opened
                    Text("Links opened: \(opened.isEmpty ? "none" : opened.joined(separator: " "))")
                        .accessibilityIdentifier("swiftApp.linkProbe")
                        .opacity(0.01)
                        .frame(width: 1, height: 1)
                }
#endif
                // No identifier here: on a container SwiftUI pushes it onto
                // every child, replacing the program's own identifiers.
        }
    }
}
