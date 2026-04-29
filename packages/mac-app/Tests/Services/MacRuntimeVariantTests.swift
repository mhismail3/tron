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
        #expect(variant.precedence == 2)
        #expect(!variant.canManageLaunchAgent(isIsolatedInstallMode: false))
        #expect(variant.canManageLaunchAgent(isIsolatedInstallMode: true))
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
        #expect(variant.precedence == 0)
    }

    @Test("parent bundle precedence treats debug and installed release as peer wrappers")
    func parentPrecedence() {
        #expect(MacRuntimeVariant.precedence(forParentBundleIdentifier: "com.tron.mac.dev") == MacRuntimeVariant.precedence(forParentBundleIdentifier: "com.tron.mac"))
        #expect(MacRuntimeVariant.precedence(forParentBundleIdentifier: "com.tron.mac") > MacRuntimeVariant.precedence(forParentBundleIdentifier: "other"))
        #expect(MacRuntimeVariant.precedence(forParentBundleIdentifier: nil) == 0)
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
            "--tron-probe-screen-recording-and-quit",
            "--tron-probe-result-path",
            "/tmp/result",
        ]) == .probeScreenRecordingAndQuit(resultPath: "/tmp/result"))
        #expect(MacCommandLineMode.probeScreenRecordingAndQuit(resultPath: nil).isCommand)
        #expect(MacCommandLineMode.parse([
            "Tron",
            "--tron-start-server-and-quit",
            "--tron-uninstall-and-quit",
        ]) == .uninstallAndQuit)
        #expect(MacCommandLineMode.uninstallAndQuit.isCommand)
        #expect(!MacCommandLineMode.normal.isCommand)
    }
}
