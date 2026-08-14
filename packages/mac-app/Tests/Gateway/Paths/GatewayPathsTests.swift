import Foundation
import Testing
@testable import TronMac

@Suite("Gateway paths")
struct GatewayPathsTests {
    @Test("production configuration is exact")
    func productionConfiguration() {
        let configuration = GatewayPaths.configuration(
            mode: .production,
            applicationBundle: URL(fileURLWithPath: "/Applications/Tron.app", isDirectory: true),
            homeDirectory: URL(fileURLWithPath: "/Users/test", isDirectory: true),
            bundleIdentifier: "com.tron.mac"
        )

        #expect(configuration.serviceLabel == "com.tron.gateway")
        #expect(configuration.helperName == "Tron Gateway")
        #expect(configuration.gatewayPort == 9847)
        #expect(configuration.tronHome.path == "/Users/test/.tron")
        #expect(configuration.gatewayDirectory.path == "/Users/test/.tron/gateway")
        #expect(configuration.appStatePath.path.hasSuffix("/.tron/gateway/mac-app-state.json"))
        #expect(configuration.wrapperLockPath.path.hasSuffix("/gateway/mac-app.com.tron.mac.lock"))
        #expect(configuration.serviceEnvironment.isEmpty)
        #expect(configuration.associatedWrapperBundleIdentifiers == ["com.tron.mac"])
        #expect(
            configuration.helperBundleProgram
                == "Contents/Library/LoginItems/Tron Gateway.app/Contents/MacOS/tron"
        )
    }

    @Test("development configuration is isolated")
    func developmentConfiguration() {
        let root = URL(fileURLWithPath: "/tmp/home", isDirectory: true)
        let configuration = GatewayPaths.configuration(
            mode: .development,
            applicationBundle: URL(fileURLWithPath: "/tmp/Tron.app", isDirectory: true),
            homeDirectory: root,
            bundleIdentifier: "com.tron.mac.dev"
        )

        #expect(configuration.serviceLabel == "com.tron.gateway.dev")
        #expect(configuration.helperName == "Tron Gateway Dev")
        #expect(configuration.gatewayPort == 9848)
        #expect(configuration.tronHome.path == "/tmp/home/.tron-dev")
        #expect(configuration.serviceEnvironment == ["TRON_HOME_NAME": ".tron-dev"])
        #expect(configuration.associatedWrapperBundleIdentifiers == ["com.tron.mac.dev"])
        #expect(configuration.applicationLocationProblem == nil)
    }

    @Test("lock names sanitize unsupported bundle characters")
    func lockNameSanitization() {
        let configuration = GatewayPaths.configuration(
            mode: .development,
            applicationBundle: URL(fileURLWithPath: "/tmp/Tron.app"),
            homeDirectory: URL(fileURLWithPath: "/tmp/home"),
            bundleIdentifier: "com/tron mac"
        )
        #expect(configuration.wrapperLockPath.lastPathComponent == "mac-app.com-tron-mac.lock")
    }
}
