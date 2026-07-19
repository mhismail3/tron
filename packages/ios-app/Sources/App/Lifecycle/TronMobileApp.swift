import SwiftUI

/// Process entry point. Hosted XCTest gets an inert view and cannot construct
/// `ProductionAppRoot` or any production dependency as a side effect of test
/// bundle injection.
@main
struct TronMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let productionRoot: ProductionAppRoot?

    init() {
        if AppRuntimeMode.current.runsApplicationLifecycle {
            productionRoot = ProductionAppRoot()
        } else {
            productionRoot = nil
        }
    }

    var body: some Scene {
        WindowGroup {
            if let productionRoot {
                productionRoot
            } else {
                Color.clear
                    .accessibilityHidden(true)
            }
        }
    }
}
