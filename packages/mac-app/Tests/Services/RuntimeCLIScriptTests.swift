import Foundation
import Testing

@Suite("Runtime CLI scripts")
struct RuntimeCLIScriptTests {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test("packaged tron-cli handles uninstall directly instead of delegating to workspace")
    func runtimeCLIHandlesUninstallDirectly() throws {
        let source = try String(contentsOf: repoRoot.appending(path: "scripts/tron-cli"), encoding: .utf8)

        #expect(source.contains("uninstall)       shift; cmd_uninstall \"$@\" ;;"))
        #expect(source.contains("dev|deploy|ci|bench|preflight|setup|install|auto-deploy)"))
        #expect(!source.contains("dev|deploy|ci|bench|preflight|setup|install|uninstall|auto-deploy)"))
        #expect(!source.contains("|ios"))
    }

    @Test("uninstall removes the Mac onboarded sentinel and preserves user data")
    func uninstallResetsMacOnboarding() throws {
        let source = try String(contentsOf: repoRoot.appending(path: "scripts/tron-lib.sh"), encoding: .utf8)

        #expect(source.contains("ONBOARDED_MARKER_PATH=\"$TRON_HOME/system/.onboarded\""))
        #expect(source.contains("rm -f \"$ONBOARDED_MARKER_PATH\""))
        #expect(source.contains("Database and workspace data preserved in: $TRON_HOME"))
        #expect(!source.contains("rm -rf \"$TRON_HOME\""))
        #expect(!source.contains("rm -rf \"$DB_PATH\""))
        #expect(!source.contains("rm -rf \"$TRON_HOME/system/database\""))
    }

    @Test("uninstall can optionally reset settings and credentials independently")
    func uninstallResetOptionsRemoveSettingsAndAuthOnly() throws {
        let source = try String(contentsOf: repoRoot.appending(path: "scripts/tron-lib.sh"), encoding: .utf8)

        #expect(source.contains("--reset-settings"))
        #expect(source.contains("--reset-credentials"))
        #expect(source.contains("rm -f \"$TRON_HOME/system/settings.json\""))
        #expect(source.contains("rm -f \"$AUTH_FILE\""))
        #expect(!source.contains("rm -f \"$DB_PATH\""))
        #expect(!source.contains("rm -f \"$TRON_HOME/system/database"))
    }

    @Test("menu bar uninstall exposes independent reset checkboxes")
    func menuBarUninstallResetCheckboxes() throws {
        let source = try String(contentsOf: repoRoot.appending(path: "packages/mac-app/Sources/MenuBar/MenuBarActionHandler.swift"), encoding: .utf8)

        #expect(source.contains("Reset settings"))
        #expect(source.contains("Reset saved credentials"))
        #expect(source.contains("let checkboxWidth = max("))
        #expect(source.contains("let accessoryWidth = max(checkboxWidth, 300)"))
        #expect(source.contains("let accessoryHeight = resetSettingsCheckbox.fittingSize.height"))
        #expect(source.contains("alert.accessoryView = resetOptionsAccessory"))
        #expect(source.contains("--reset-settings"))
        #expect(source.contains("--reset-credentials"))
        #expect(source.contains("The database is never removed."))
    }

    @Test("runtime config bootstrap keeps settings sparse")
    func configBootstrapDoesNotCreateSettingsJSON() throws {
        let source = try String(contentsOf: repoRoot.appending(path: "scripts/tron-lib.sh"), encoding: .utf8)

        #expect(source.contains("settings.json is intentionally not created here"))
        #expect(!source.contains("cat > \"$TRON_HOME/system/settings.json\""))
        #expect(source.contains("cat > \"$TRON_HOME/system/auth.json\""))
    }
}
