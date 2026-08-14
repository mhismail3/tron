import AppKit
import Darwin
import SwiftUI

@main
struct TronMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() { TronFontLoader.registerFonts() }

    var body: some Scene {
        WindowGroup {
            Group {
                if TronMacRuntime.isRunningUnderTests() {
                    Color.clear.frame(width: 1, height: 1)
                } else if MacCommandLineMode.current.isCommand {
                    CommandModeHostView()
                } else {
                    RootView(context: appDelegate.context)
                }
            }
            .environment(\.gatewayDependencies, appDelegate.context.dependencies)
            .tint(Color.tronEmerald)
            .containerBackground(.regularMaterial, for: .window)
            .configureHostingWindow { window in
                if TronMacRuntime.isRunningUnderTests() {
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

struct RootView: View {
    @Bindable var context: GatewayAppContext

    var body: some View {
        Group {
            switch context.mode {
            case .loading:
                ProgressView("Loading…")
                    .controlSize(.large)
                    .frame(width: WizardLayout.width, height: WizardLayout.height)
            case .onboarding:
                WizardView(context: context)
            case .menuBarOnly:
                Color.clear
                    .frame(width: 1, height: 1)
                    .onAppear { NSApp.windows.first?.orderOut(nil) }
            }
        }
        .onChange(of: context.mode) { _, mode in
            switch mode {
            case .loading:
                break
            case .onboarding:
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
            case .menuBarOnly:
                NSApp.setActivationPolicy(.accessory)
                for window in NSApp.windows { window.orderOut(nil) }
            }
        }
    }
}

struct CommandModeHostView: View {
    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear {
                NSApp.setActivationPolicy(.accessory)
                for window in NSApp.windows { window.orderOut(nil) }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let context = GatewayAppContext()
    private var menuBarController: MenuBarController?
    private var instanceLock: SingleInstanceLock?
    private var lifecycleTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !TronMacRuntime.isRunningUnderTests() else { return }

        let lock = SingleInstanceLock(
            lockFileURL: context.dependencies.configuration.wrapperLockPath
        )
        switch lock.acquire() {
        case .acquired:
            instanceLock = lock
        case .heldByAnotherProcess:
            NSLog("[Tron] Another Tron window is already running.")
            NSApp.terminate(nil)
            return
        case .failed(let failure):
            NSLog("[Tron] Mac instance lock failed: %@", String(describing: failure))
            NSApp.terminate(nil)
            return
        }

        context.onMenuBarRequested = { [weak self] in self?.installMenuBar() }
        switch MacCommandLineMode.current {
        case .normal:
            lifecycleTask = Task { [weak context] in await context?.start() }
        case .startGatewayAndQuit:
            startGatewayAndQuit()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        lifecycleTask?.cancel()
        lifecycleTask = nil
        menuBarController?.dispose()
        menuBarController = nil
        instanceLock?.release()
        instanceLock = nil
    }

    private func installMenuBar() {
        guard menuBarController == nil else { return }
        let controller = MenuBarController(
            dependencies: context.dependencies,
            coordinator: context.coordinator
        )
        controller.install()
        menuBarController = controller
    }

    private func startGatewayAndQuit() {
        NSApp.setActivationPolicy(.accessory)
        lifecycleTask = Task { [weak self] in
            guard let self else { return }
            let result = await MacCommandModeGatewayStarter.start(
                coordinator: context.coordinator
            )
            switch result {
            case .ok:
                NSApp.terminate(nil)
            case .busy:
                NSLog("[Tron] Gateway command rejected because another operation is active.")
                Darwin.exit(1)
            case .failed(let failure):
                NSLog("[Tron] Gateway command failed: %@", String(describing: failure))
                Darwin.exit(1)
            }
        }
    }

}
