import Foundation
import Testing
@testable import TronMac

@Suite("Gateway runtime mode")
struct GatewayRuntimeModeTests {
    @Test("only production and development wrapper identities are supported")
    func detectsExactBundleIdentifiers() {
        #expect(GatewayRuntimeMode.detect(bundleIdentifier: "com.tron.mac") == .production)
        #expect(GatewayRuntimeMode.detect(bundleIdentifier: "com.tron.mac.dev") == .development)
        #expect(GatewayRuntimeMode.detect(bundleIdentifier: "example.tron") == nil)
        #expect(GatewayRuntimeMode.detect(bundleIdentifier: nil) == nil)
    }

    @Test("production requires the installed application path")
    func productionLocation() {
        #expect(
            GatewayRuntimeMode.production.applicationLocationProblem(
                bundleURL: URL(fileURLWithPath: "/Applications/Tron.app", isDirectory: true)
            ) == nil
        )
        #expect(
            GatewayRuntimeMode.production.applicationLocationProblem(
                bundleURL: URL(fileURLWithPath: "/tmp/Tron.app", isDirectory: true)
            ) != nil
        )
        #expect(
            GatewayRuntimeMode.development.applicationLocationProblem(
                bundleURL: URL(fileURLWithPath: "/tmp/Tron.app", isDirectory: true)
            ) == nil
        )
    }
}

@Suite("Mac command-line mode")
struct MacCommandLineModeTests {
    @Test("recognizes only the current Gateway start command")
    func parsesGatewayStartFlag() {
        #expect(MacCommandLineMode.parse(["Tron"]) == .normal)
        #expect(
            MacCommandLineMode.parse(["Tron", "--tron-start-gateway-and-quit"])
                == .startGatewayAndQuit
        )
        #expect(MacCommandLineMode.parse(["Tron", "--unknown"]) == .normal)
        #expect(MacCommandLineMode.startGatewayAndQuit.isCommand)
        #expect(!MacCommandLineMode.normal.isCommand)
    }
}

@Suite("Tron Mac runtime")
struct TronMacRuntimeTests {
    @Test("test-host detection accepts Xcode test environment markers")
    func testHostDetectionMarkers() {
        #expect(TronMacRuntime.isRunningUnderTests(environment: ["TRON_MAC_TEST_HOST": "1"]))
        #expect(TronMacRuntime.isRunningUnderTests(environment: ["XCTestSessionIdentifier": "session"]))
        #expect(TronMacRuntime.isRunningUnderTests(environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"]))
        #expect(TronMacRuntime.isRunningUnderTests(environment: ["XCTestBundlePath": "/tmp/TronMacTests.xctest"]))
        #expect(!TronMacRuntime.isRunningUnderTests(environment: [:]))
    }
}
