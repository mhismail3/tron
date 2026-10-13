import SwiftUI

/// Experimental gate for running displayed `.swift` files (#889). Off by
/// default; the launch argument `-tron.experimental.swiftApps YES` (or the
/// same UserDefaults key) enables it, so normal use never shows the control.
enum SwiftAppExperiment {
    static let defaultsKey = "tron.experimental.swiftApps"

    static func canRun(fileNamed name: String) -> Bool {
        UserDefaults.standard.bool(forKey: defaultsKey) && name.lowercased().hasSuffix(".swift")
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
                .overlay(alignment: .bottom) {
                    if let message = runtime.actionError {
                        SwiftAppErrorView(message: message)
                            .padding()
                    }
                }
                .accessibilityIdentifier("swiftApp.running")
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }
}
