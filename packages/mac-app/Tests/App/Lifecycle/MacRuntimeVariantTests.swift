import Foundation
import Testing
@testable import TronMac

@Suite("MacRuntimeVariant")
struct MacRuntimeVariantTests {
    @Test("debug builds may run from Xcode paths")
    func debugBuildMayRunFromDerivedData() {
        let variant = MacRuntimeVariant.detect(
            bundleURL: URL(fileURLWithPath: "/Users/dev/Library/Developer/Xcode/DerivedData/Build/Products/Debug/Tron.app", isDirectory: true),
            bundleIdentifier: "com.tron.mac.dev"
        )

        #expect(variant.locationProblem == nil)
        #expect(variant.expectedParentBundleIdentifier == "com.tron.mac.dev")
        #expect(variant == .xcodeDebug)
        #expect(!variant.canManageLaunchAgent(isIsolatedInstallMode: false))
        #expect(!variant.canManageLaunchAgent(isIsolatedInstallMode: true))
    }

    @Test("release builds must be installed at Applications")
    func releaseBuildRequiresApplicationsPath() {
        let installed = MacRuntimeVariant.detect(
            bundleURL: URL(fileURLWithPath: "/Applications/Tron.app", isDirectory: true),
            bundleIdentifier: "com.tron.mac"
        )
        #expect(installed == .installedRelease)
        #expect(installed.locationProblem == nil)

        let misplaced = MacRuntimeVariant.detect(
            bundleURL: URL(fileURLWithPath: "/Users/dev/Downloads/Tron.app", isDirectory: true),
            bundleIdentifier: "com.tron.mac"
        )
        #expect(misplaced.locationProblem?.contains("/Applications") == true)
    }

    @Test("unknown wrapper builds are unsupported")
    func unknownBuildIsUnsupported() {
        let variant = MacRuntimeVariant.detect(
            bundleURL: URL(fileURLWithPath: "/tmp/Tron.app", isDirectory: true),
            bundleIdentifier: "example.tron"
        )

        #expect(variant.locationProblem?.contains("Unsupported") == true)
        #expect(!variant.canTakeOverRegistration(ownedBy: MacRuntimeVariant.debugBundleIdentifier))
    }

}

@Suite("MacCommandLineMode")
struct MacCommandLineModeTests {
    @Test("parses internal server start flag")
    func parsesServerStartFlag() {
        #expect(MacCommandLineMode.parse(["Tron"]) == .normal)
        #expect(MacCommandLineMode.parse(["Tron", "--tron-start-server-and-quit"]) == .startServerAndQuit)
        #expect(MacCommandLineMode.parse(["Tron", "--tron-uninstall-and-quit"]) == .uninstallAndQuit)
        #expect(MacCommandLineMode.parse([
            "Tron",
            "--tron-start-server-and-quit",
            "--tron-uninstall-and-quit",
        ]) == .uninstallAndQuit)
        #expect(MacCommandLineMode.uninstallAndQuit.isCommand)
        #expect(!MacCommandLineMode.normal.isCommand)
    }
}

@Suite("MacStartupMode")
struct MacStartupModeTests {
    @Test("one authority routes release, debug, command, and test hosts")
    func startupMatrix() {
        let release = MacRuntimeVariant.installedRelease
        #expect(MacStartupMode.resolve(variant: release, onboarded: false, command: .normal, underTests: false) == .wizard)
        #expect(MacStartupMode.resolve(variant: release, onboarded: true, command: .normal, underTests: false) == .onboarded)
        #expect(MacStartupMode.resolve(variant: .xcodeDebug, onboarded: true, command: .normal, underTests: false) == .debugReadOnly)
        #expect(MacStartupMode.resolve(variant: .misplacedRelease(actualPath: "/tmp/Tron.app"), onboarded: true, command: .normal, underTests: false) == .misplacedRelease)
        #expect(MacStartupMode.resolve(variant: release, onboarded: true, command: .startServerAndQuit, underTests: false) == .command(.startServerAndQuit))
        #expect(MacStartupMode.resolve(variant: release, onboarded: true, command: .normal, underTests: true) == .testHost)
    }

}
