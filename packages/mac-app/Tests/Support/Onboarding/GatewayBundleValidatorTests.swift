import Foundation
import Testing
@testable import TronMac

@Suite("Gateway bundle validator")
struct GatewayBundleValidatorTests {
    @Test(arguments: [GatewayRuntimeMode.production, .development])
    func trackedServiceDefinitionsAreExact(mode: GatewayRuntimeMode) throws {
        let configuration = trackedConfiguration(mode: mode)
        let data = try Data(contentsOf: trackedPlistPath(mode: mode))

        #expect(GatewayBundleValidator.serviceDefinitionIsCurrent(
            configuration: configuration,
            data: data
        ))
    }

    @Test(arguments: [GatewayRuntimeMode.production, .development])
    func trackedHelperMetadataIsExact(mode: GatewayRuntimeMode) throws {
        let configuration = trackedConfiguration(mode: mode)
        let helperName = mode == .production ? "Tron Gateway.app" : "Tron Gateway Dev.app"
        let plist = try decodedPlist(
            TestRepository.macAppRoot
                .appendingPathComponent("Sources/Resources/Library/LoginItems")
                .appendingPathComponent(helperName)
                .appendingPathComponent("Contents/Info.plist")
        )

        #expect(plist["CFBundleDisplayName"] as? String == configuration.helperName)
        #expect(plist["CFBundleIdentifier"] as? String == configuration.serviceLabel)
        #expect(plist["CFBundleExecutable"] as? String == "tron")
    }

    @Test("bundled Node runtimes are signed with the V8 JIT entitlement")
    func nodeRuntimeEntitlementIsExact() throws {
        let plist = try decodedPlist(
            TestRepository.macAppRoot.appendingPathComponent("Configuration/GatewayNode.entitlements")
        )

        #expect(plist.count == 1)
        #expect(plist["com.apple.security.cs.allow-jit"] as? Bool == true)
    }

    @Test("service definition rejects a wrong current helper")
    func rejectsWrongHelper() throws {
        let configuration = trackedConfiguration(mode: .development)
        var plist = try decodedPlist(trackedPlistPath(mode: .development))
        plist["BundleProgram"] = "Contents/Library/LoginItems/Wrong.app/Contents/MacOS/tron"

        #expect(!GatewayBundleValidator.serviceDefinitionIsCurrent(
            configuration: configuration,
            data: try encodedPlist(plist)
        ))
    }

    @Test("service definition rejects missing supervision properties")
    func rejectsMissingSupervision() throws {
        let configuration = trackedConfiguration(mode: .production)
        var plist = try decodedPlist(trackedPlistPath(mode: .production))
        plist.removeValue(forKey: "KeepAlive")

        #expect(!GatewayBundleValidator.serviceDefinitionIsCurrent(
            configuration: configuration,
            data: try encodedPlist(plist)
        ))
    }

    @Test("service definition rejects wrong arguments, environment, and throttle")
    func rejectsWrongLaunchContract() throws {
        let configuration = trackedConfiguration(mode: .development)
        let original = try decodedPlist(trackedPlistPath(mode: .development))
        var mutations: [[String: Any]] = []

        var arguments = original
        arguments["ProgramArguments"] = ["tron", "--port", "9999"]
        mutations.append(arguments)

        var environment = original
        environment["EnvironmentVariables"] = [:]
        mutations.append(environment)

        var throttle = original
        throttle["ThrottleInterval"] = 1
        mutations.append(throttle)

        for plist in mutations {
            #expect(!GatewayBundleValidator.serviceDefinitionIsCurrent(
                configuration: configuration,
                data: try encodedPlist(plist)
            ))
        }
    }

    @Test("filesystem and signature failures are typed")
    func validationFailuresAreTyped() throws {
        let root = try TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let application = root.appendingPathComponent("Tron.app", isDirectory: true)
        let configuration = GatewayPaths.configuration(
            mode: .development,
            applicationBundle: application,
            homeDirectory: root,
            bundleIdentifier: "com.tron.mac.dev"
        )

        #expect(GatewayBundleValidator.validate(
            configuration: configuration,
            fileExists: { _ in false },
            signatureProblem: { _, _ in false }
        ) == .helperMissing)

        let helperOnly: Set<String> = [configuration.helperBundle.path]
        #expect(GatewayBundleValidator.validate(
            configuration: configuration,
            fileExists: { helperOnly.contains($0) },
            signatureProblem: { _, _ in false }
        ) == .executableMissing)

        let noPlist: Set<String> = [configuration.helperBundle.path, configuration.helperBinary.path]
        #expect(GatewayBundleValidator.validate(
            configuration: configuration,
            fileExists: { noPlist.contains($0) },
            signatureProblem: { _, _ in false }
        ) == .serviceDefinitionMissing)
    }

    @Test("a current fixture reaches signature validation")
    func signatureValidationIsRequired() throws {
        let root = try TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let application = root.appendingPathComponent("Tron.app", isDirectory: true)
        let configuration = GatewayPaths.configuration(
            mode: .development,
            applicationBundle: application,
            homeDirectory: root,
            bundleIdentifier: "com.tron.mac.dev"
        )
        try FileManager.default.createDirectory(
            at: configuration.helperBinary.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: configuration.helperBinary)
        try FileManager.default.createDirectory(
            at: configuration.servicePlistPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contentsOf: trackedPlistPath(mode: .development))
            .write(to: configuration.servicePlistPath)

        #expect(GatewayBundleValidator.validate(
            configuration: configuration,
            signatureProblem: { _, identifier in identifier == "com.tron.gateway.dev" }
        ) == .signatureInvalid)
    }

    private func trackedConfiguration(mode: GatewayRuntimeMode) -> GatewayServiceConfiguration {
        let application = mode == .production
            ? URL(fileURLWithPath: "/Applications/Tron.app", isDirectory: true)
            : URL(fileURLWithPath: "/tmp/Tron.app", isDirectory: true)
        return GatewayPaths.configuration(
            mode: mode,
            applicationBundle: application,
            homeDirectory: URL(fileURLWithPath: "/Users/test", isDirectory: true),
            bundleIdentifier: mode.bundleIdentifier
        )
    }

    private func trackedPlistPath(mode: GatewayRuntimeMode) -> URL {
        let name = mode == .production ? "com.tron.gateway.plist" : "com.tron.gateway.dev.plist"
        return TestRepository.macAppRoot
            .appendingPathComponent("Sources/Resources/Library/LaunchAgents/\(name)")
    }

    private func decodedPlist(_ path: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: path)
        return try #require(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                as? [String: Any]
        )
    }

    private func encodedPlist(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: value,
            format: .xml,
            options: 0
        )
    }
}
