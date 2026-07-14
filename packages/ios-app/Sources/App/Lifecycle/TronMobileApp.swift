import SwiftUI

/// Process entry point. Hosted XCTest gets an inert view and cannot construct
/// `ProductionAppRoot` or any production dependency as a side effect of test
/// bundle injection.
@main
struct TronMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let bootstrap: AppBootstrap<ProductionAppRoot>

    init() {
        let mode = AppRuntimeMode.resolve(
            environment: ProcessInfo.processInfo.environment,
            arguments: ProcessInfo.processInfo.arguments
        )
        bootstrap = AppBootstrap(mode: mode) {
            ProductionAppRoot()
        }
    }

    var body: some Scene {
        WindowGroup {
            if let productionRoot = bootstrap.productionRoot {
                productionRoot
            } else {
                HostedUnitTestRoot()
            }
        }
    }
}
