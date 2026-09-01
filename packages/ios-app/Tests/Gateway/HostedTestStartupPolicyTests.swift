import Foundation
import Testing
@testable import TronMobile

@Suite("Hosted test startup policy")
struct HostedTestStartupPolicyTests {
    private var appSource: String {
        get throws {
            let packageRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            return try String(
                contentsOf: packageRoot.appending(path: "Sources/App/TronMobileApp.swift"),
                encoding: .utf8
            )
        }
    }

    @Test("HOSTED_TEST app entry is inert and production startup stays outside its branch")
    func inertHostedEntry() throws {
        let source = try appSource
        let hostedStart = try #require(source.range(of: "#if HOSTED_TEST"))
        let productionStart = try #require(source.range(of: "#else", range: hostedStart.upperBound..<source.endIndex))
        let hosted = source[hostedStart.upperBound..<productionStart.lowerBound]

        #expect(hosted.contains("HostedTestRootView()"))
        for forbidden in [
            "AppDelegate", "AppModel(", "PushNotificationCoordinator(",
            "AppBackgroundCheckpointCoordinator(", "RetiredNotificationBadge",
            "configurePushNotifications", "reconcilePushNotifications", ".start("
        ] {
            #expect(!hosted.contains(forbidden), "Hosted startup must not contain \(forbidden)")
        }
        #expect(source.contains("#if HOSTED_TEST\nprivate struct HostedTestRootView"))
        #expect(source.contains(".accessibilityIdentifier(\"tron.hosted-test-root\")"))
    }
}
