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
}

/// Runs one interpreted single-file SwiftUI app in a large sheet. Dismissing
/// the sheet discards the program and all of its state.
struct SwiftAppRunnerSheet: View {
    let launch: SwiftAppLaunch
    @State private var runtime: Result<SwiftAppRuntime, Error>

    init(launch: SwiftAppLaunch) {
        self.launch = launch
        _runtime = State(initialValue: Result { try SwiftAppRuntime(source: launch.source) })
    }

    var body: some View {
        Group {
            switch runtime {
            case .success(let runtime):
                running(runtime)
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
    }

    @ViewBuilder
    private func running(_ runtime: SwiftAppRuntime) -> some View {
        if let root = runtime.rootDeclaration {
            SwiftAppCustomView(runtime: runtime, node: SwiftAppViewNode(name: root.name, arguments: [], declaration: root))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The interpreted app looks like a standard iOS app, not Tron:
                // controls and text use their system default fonts.
                .environment(\.font, nil)
                .overlay(alignment: .bottom) {
                    if let message = runtime.actionError {
                        SwiftAppErrorView(message: message)
                            .padding()
                    }
                }
                // No identifier here: on a container SwiftUI pushes it onto
                // every child, replacing the program's own identifiers.
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }
}
