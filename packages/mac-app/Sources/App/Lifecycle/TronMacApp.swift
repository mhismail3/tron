import SwiftUI
import AppKit
import Darwin

@main
struct TronMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        TronFontLoader.registerFonts()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch EnvironmentSetup.live.resolvedStartupMode() {
                case .testHost: TestHostView()
                default: RootView()
                }
            }
                .environment(\.environmentSetup, EnvironmentSetup.live)
                .tint(Color.tronEmerald)
                .containerBackground(.regularMaterial, for: .window)
                .configureHostingWindow { window in
                    if EnvironmentSetup.live.resolvedStartupMode() == .testHost {
                        window.orderOut(nil)
                        return
                    }
                    window.isOpaque = false
                    window.backgroundColor = .clear
                    window.titlebarAppearsTransparent = true
                    window.titleVisibility = .hidden
                    window.styleMask.insert(.fullSizeContentView)
                    window.styleMask.remove(.resizable)
                    window.contentView?.wantsLayer = true
                    window.contentView?.layer?.cornerRadius = 16
                    window.contentView?.layer?.masksToBounds = true
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commandsRemoved()
    }
}

enum TronMacRuntime {
    static func isRunningUnderTests(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["TRON_MAC_TEST_HOST"] == "1"
            || environment["XCTestSessionIdentifier"] != nil
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
    }
}

struct TestHostView: View {
    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
    }
}

struct RootView: View {
    @Environment(\.environmentSetup) private var setup
    @State private var mode: AppMode = .loading

    private var startupMode: MacStartupMode { setup.resolvedStartupMode() }

    var body: some View {
        Group {
            switch mode {
            case .loading:
                ProgressView("Loading…")
                    .controlSize(.large)
                    .frame(width: WizardLayout.width, height: WizardLayout.height)
            case .wizard:
                WizardView()
            case .menuBarOnly:
                MenuBarHostView()
            case .companion:
                CompanionHostView()
            }
        }
        .task(id: mode) {
            switch mode {
            case .loading:
                switch startupMode {
                case .testHost: mode = .companion
                case .debugReadOnly: mode = .companion
                case .wizard: mode = .wizard
                case .onboarded: mode = .menuBarOnly
                case .misplacedRelease, .unsupported: mode = .companion
                }
            case .wizard:
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
            case .menuBarOnly:
                NSApp.setActivationPolicy(.accessory)
            case .companion:
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
            }
        }
    }
}

enum AppMode: Equatable {
    case loading
    case wizard
    case menuBarOnly
    case companion
}

struct MenuBarHostView: View {
    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear {
                if let window = NSApp.windows.first {
                    window.orderOut(nil)
                }
            }
    }
}

struct CompanionHostView: View {
    @Environment(\.environmentSetup) private var setup

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Tron Debug Companion", systemImage: "hammer.circle.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.tronEmerald)
            Text("This debug wrapper observes the production Gateway on port \(setup.serverPort).")
                .foregroundStyle(.primary)
            Text("Production ownership remains with /Applications/Tron.app. This window does not install a second menu-bar item or restart the production service.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(28)
        .frame(width: WizardLayout.width, height: WizardLayout.height, alignment: .topLeading)
        .background(.regularMaterial)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let startupMode = EnvironmentSetup.live.resolvedStartupMode()
    private var menuBarController: MenuBarController?
    private var wizardCompletionObserver: NSObjectProtocol?
    private var instanceLock: SingleInstanceLock?
    private var quitCoordinator: MacQuitCoordinator?
    private var quitInProgress = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let setup = EnvironmentSetup.live
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        if startupMode != .testHost {
            TronLog.shared.record(.info, event: "app.started", source: "lifecycle", message: "Mac app started", appVersion: version, build: build)
        }
        if startupMode == .testHost {
            return
        }

        let lock = SingleInstanceLock(lockFileURL: setup.wrapperLockPath)
        guard lock.acquire() else {
            TronLog.shared.record(.warning, event: "app.instance-already-running", source: "lifecycle", message: "Another wrapper instance is already running")
            NSApp.terminate(nil)
            return
        }
        instanceLock = lock
        quitCoordinator = MacQuitCoordinator(
            readRuntime: { try await setup.readRuntimeForQuit() },
            processStartIdentity: { pid in await ServerProcessProbe.processStartIdentity(pid: pid) },
            runtimeOwnershipHealthy: setup.runtimeOwnershipHealthy,
            serviceEnabled: { setup.launchAgentServiceStatus() == .enabled },
            shutdownCompleted: { pid, drainID in
                await MacQuitCoordinator.hasCompletedShutdown(
                    pid: pid, drainID: drainID,
                    receiptURL: setup.tronHome.appendingPathComponent("gateway/stop-completed.json")
                )
            },
            readDrain: setup.readDrainForQuit,
            stopGateway: setup.stopGateway,
            retireCompletedGateway: setup.retireCompletedGatewayForQuit,
            retireNativeHost: setup.retireNativeHostForQuit
        )

        if case .onboarded = startupMode {
            installMenuBar(setup: setup, context: .existingOnboardedLaunch)
        }

        wizardCompletionObserver = NotificationCenter.default.addObserver(
            forName: .tronWizardDidComplete,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let setup = EnvironmentSetup.live
                if !setup.canManageLaunchAgent {
                    TronLog.shared.record(.info, event: "wizard.completed", source: "wizard", message: "Debug companion did not install the production menu bar", outcome: "not-managed")
                    return
                }
                self.installMenuBar(setup: setup, context: .wizardCompletion)
                NSApp.setActivationPolicy(.accessory)
                for window in NSApp.windows {
                    window.orderOut(nil)
                }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard MacQuitCoordinator.shouldCoordinate(
            mode: startupMode,
            ownsLock: instanceLock != nil,
            canManage: EnvironmentSetup.live.canManageLaunchAgent
        ), let quitCoordinator else { return .terminateNow }
        guard !quitInProgress else { return .terminateCancel }
        quitInProgress = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let directory = EnvironmentSetup.live.tronHome.deletingLastPathComponent()
                .appendingPathComponent(".tron-maintenance/replace/quit")
            let terminated = await ApplicationTermination.complete(
                directory: directory, pid: Int(getpid()),
                start: await ServerProcessProbe.processStartIdentity(pid: Int(getpid())),
                quit: { progress in try await quitCoordinator.quit(progress: progress) },
                ordinaryFailure: { error in
                    let alert = NSAlert()
                    alert.messageText = "Quit blocked"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Keep Tron Open")
                    alert.runModal()
                },
                receiptFailure: { error in
                    TronLog.shared.record(.error, event: "app.quit.replacement-receipt", source: "lifecycle",
                        message: "Could not publish replacement Quit result: \(error.localizedDescription)", outcome: "failed")
                }
            )
            if !terminated { self.quitInProgress = false }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let wizardCompletionObserver {
            NotificationCenter.default.removeObserver(wizardCompletionObserver)
        }
        menuBarController?.dispose()
        menuBarController = nil
        instanceLock?.release()
        instanceLock = nil
    }

    private func installMenuBar(setup: EnvironmentSetup, context: MacAppStartupContext) {
        guard menuBarController == nil else { return }
        let controller = MenuBarController(setup: setup)
        controller.install()
        menuBarController = controller
        Task { [weak controller] in
            _ = await MacAppStartupMaintenance.run(
                setup: setup,
                controller: controller,
                context: context
            )
        }
    }
}

extension Notification.Name {
    static let tronWizardDidComplete = Notification.Name("com.tron.mac.wizard.didComplete")
}
