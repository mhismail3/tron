import Foundation
import Testing
@testable import TronMac

@Suite("Live Gateway service manager")
struct LiveGatewayServiceManagerTests {
    @Test("runtime identity must match the exact current helper")
    func runtimeMatchesCurrentHelper() {
        let configuration = GatewayPaths.configuration(
            mode: .development,
            applicationBundle: URL(fileURLWithPath: "/tmp/Tron.app", isDirectory: true),
            homeDirectory: URL(fileURLWithPath: "/tmp/home", isDirectory: true),
            bundleIdentifier: "com.tron.mac.dev"
        )
        let runtime = GatewayRuntimeInfo(
            pid: 42,
            uptime: "00:02",
            parentBundleIdentifier: "com.tron.mac.dev",
            parentBundleVersion: "3",
            programIdentifier: configuration.helperBundleProgram
        )

        #expect(LiveGatewayServiceManager.runtimeMatches(
            runtime,
            configuration: configuration,
            fileExists: { $0 == configuration.helperBinary.path }
        ))
    }

    @Test("wrong wrapper, helper, missing binary, or process exit never matches")
    func runtimeMismatchCases() {
        let configuration = GatewayPaths.configuration(
            mode: .production,
            applicationBundle: URL(fileURLWithPath: "/Applications/Tron.app", isDirectory: true),
            homeDirectory: URL(fileURLWithPath: "/Users/test", isDirectory: true),
            bundleIdentifier: "com.tron.mac"
        )
        let current = GatewayRuntimeInfo(
            pid: 10,
            parentBundleIdentifier: "com.tron.mac",
            programIdentifier: configuration.helperBundleProgram
        )
        let wrongWrapper = GatewayRuntimeInfo(
            pid: 10,
            parentBundleIdentifier: "com.tron.mac.dev",
            programIdentifier: configuration.helperBundleProgram
        )
        let wrongHelper = GatewayRuntimeInfo(
            pid: 10,
            parentBundleIdentifier: "com.tron.mac",
            programIdentifier: "Contents/Library/LoginItems/Wrong.app/Contents/MacOS/tron"
        )

        #expect(!LiveGatewayServiceManager.runtimeMatches(nil, configuration: configuration))
        #expect(!LiveGatewayServiceManager.runtimeMatches(wrongWrapper, configuration: configuration))
        #expect(!LiveGatewayServiceManager.runtimeMatches(wrongHelper, configuration: configuration))
        #expect(!LiveGatewayServiceManager.runtimeMatches(
            current,
            configuration: configuration,
            fileExists: { _ in false }
        ))
    }

    @Test("launchctl program identifiers are parsed without mode diagnostics")
    func parsesLaunchctlProgramIdentifier() {
        let output = """
        gui/501/com.tron.gateway.dev = {
            program identifier = Contents/Library/LoginItems/Tron Gateway Dev.app/Contents/MacOS/tron (mode: 2)
            parent bundle identifier = com.tron.mac.dev
        }
        """

        #expect(
            LiveGatewayServiceManager.parseProgramIdentifier(output)
                == "Contents/Library/LoginItems/Tron Gateway Dev.app/Contents/MacOS/tron"
        )
        #expect(LiveGatewayServiceManager.parseProgramIdentifier("state = running") == nil)
    }

    @Test("only completed service outcomes are successful")
    func serviceOutcomeSuccess() {
        #expect(GatewayServiceOutcome.registered.isSuccess)
        #expect(GatewayServiceOutcome.alreadyRegistered.isSuccess)
        #expect(GatewayServiceOutcome.unregistered.isSuccess)
        #expect(!GatewayServiceOutcome.requiresApproval.isSuccess)
        #expect(!GatewayServiceOutcome.portInUse(9847).isSuccess)
        #expect(!GatewayServiceOutcome.invalidBundle.isSuccess)
        #expect(!GatewayServiceOutcome.refused.isSuccess)
        #expect(!GatewayServiceOutcome.failed.isSuccess)
    }
}
