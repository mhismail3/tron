import Foundation
import Testing

extension SourceGuardTests {
    @Test("hosted tests use identities distinct from persistent app variants")
    func testHostedTestsUseDedicatedAppIdentity() throws {
        let iosRoot = iosAppRoot()
        let project = try String(
            contentsOf: iosRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        let testConfig = try String(
            contentsOf: iosRoot.appendingPathComponent("Configuration/Test.xcconfig"),
            encoding: .utf8
        )

        #expect(project.contains("Test: Configuration/Test.xcconfig"))
        #expect(project.contains("Test: debug"))
        #expect(project.contains("PRODUCT_BUNDLE_IDENTIFIER: com.tron.mobile.testhost"))
        #expect(project.contains("PRODUCT_BUNDLE_IDENTIFIER: com.tron.mobile.testhost.ShareExtension"))
        #expect(project.contains("PRODUCT_BUNDLE_IDENTIFIER: com.tron.mobile.testhost.tests"))
        #expect(project.components(separatedBy: "CODE_SIGN_ENTITLEMENTS: \"\"").count - 1 == 2)
        #expect(project.components(separatedBy: "test:\n      config: Test").count - 1 == 4)
        #expect(testConfig.contains("#include \"Debug.xcconfig\""))
        #expect(!testConfig.contains("PRODUCT_BUNDLE_IDENTIFIER"))
    }

    @Test("persistent simulator refuses an XCTest-replaced Beta artifact")
    func testPersistentSimulatorRejectsTestHostArtifact() throws {
        let repositoryRoot = iosAppRoot()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let helper = try String(
            contentsOf: repositoryRoot.appendingPathComponent("scripts/tron-ios-simulator"),
            encoding: .utf8
        )

        #expect(helper.contains("installed_beta_code_identifier"))
        #expect(helper.contains("codesign -dvv"))
        #expect(helper.contains("[ \"$installed_identifier\" = \"$BUNDLE_ID\" ]"))
        #expect(helper.contains("an XCTest host may have replaced it"))
        #expect(helper.contains("Hosted test actions use a separate app identity"))
        #expect(helper.contains("validation unavailable while simulator is not booted"))
    }
}
