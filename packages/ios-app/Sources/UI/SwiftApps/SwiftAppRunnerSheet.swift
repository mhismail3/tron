import SwiftUI

/// Experimental gate for running displayed `.swift` files (#889), an
/// iPhone-only preference. Off by default, so normal use never shows the
/// control. Settings › Tools & Diagnostics › Experimental owns the switch; launching
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
}

/// Runs one interpreted single-file SwiftUI app in a large sheet. Dismissing
/// the sheet discards the program and all of its state.
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

    init(launch: SwiftAppLaunch) {
        self.launch = launch
        _runtime = PresentationState(wrappedValue: Result {
            try SwiftAppRuntime(source: launch.source, linkPolicy: SwiftAppLinkPolicy(host: launch.linkHost))
        })
    }

    private var fileTitle: String {
        launch.name.lowercased().hasSuffix(".swift") ? String(launch.name.dropLast(6)) : launch.name
    }

    var body: some View {
        switch runtime {
        case .success(let runtime):
            TronDocumentSheet(title: fileTitle, hostsNavigation: false) {
                running(runtime)
                    .onDisappear { runtime.stopAllTimers() }
                    // An install opens at once: iOS asks before installing.
                    .onChange(of: runtime.pendingLink) { _, link in
                        guard let link, !link.needsConfirmation else { return }
                        runtime.pendingLink = nil
                        openURL(link.url)
                    }
                    .alert("Open link?", isPresented: Binding(
                        get: { runtime.pendingLink?.needsConfirmation == true },
                        set: { if !$0 { runtime.pendingLink = nil } }
                    ), presenting: runtime.pendingLink) { link in
                        Button("Open") { openURL(link.url) }
                        Button("Cancel", role: .cancel) {}
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

    @ViewBuilder
    private func running(_ runtime: SwiftAppRuntime) -> some View {
        if let root = runtime.rootDeclaration {
            SwiftAppCustomView(runtime: runtime, node: SwiftAppViewNode(name: root.name, arguments: [], declaration: root))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(\.swiftAppHostChrome, SwiftAppHostChrome(title: fileTitle))
                // Lists and Forms show the shared sheet material, like Tron's
                // own sheets; a program's own scrollContentBackground wins.
                .scrollContentBackground(.hidden)
                .overlay(alignment: .bottom) {
                    if let message = runtime.actionError {
                        SwiftAppErrorView(message: message)
                            .padding(TronSpacing.xlarge)
                    }
                }
#if HOSTED_TEST
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
