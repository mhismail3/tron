import AppKit
import Darwin

// Standalone application only: no Tron startup, service registration, Gateway,
// credentials, or helper. A background watchdog bounds a blocked AppKit loop.
@main
struct AppKitTerminationProbe {
    static func log(_ value: String) {
        FileHandle.standardError.write(Data((value + "\n").utf8))
    }

    @MainActor
    final class Delegate: NSObject, NSApplicationDelegate {
        let mode: String
        var attempts = 0
        init(mode: String) { self.mode = mode }

        func applicationDidFinishLaunching(_ notification: Notification) {
            Task { @MainActor in
                switch mode {
                case "direct": NSApp.terminate(nil)
                case "dispatch": DispatchQueue.main.async { NSApp.terminate(nil) }
                default: ApplicationTermination.request()
                }
                log("action-returned")
            }
        }

        func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
            attempts += 1
            log("termination-requested")
            Task { @MainActor in
                log("reply-task-ran")
                if mode == "retry", attempts == 1 {
                    sender.reply(toApplicationShouldTerminate: false)
                    log("termination-cancelled")
                    ApplicationTermination.request()
                } else {
                    sender.reply(toApplicationShouldTerminate: true)
                }
            }
            return .terminateLater
        }

        func applicationWillTerminate(_ notification: Notification) {
            log("terminated")
        }
    }

    @MainActor
    static func main() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            log("watchdog-expired")
            _exit(42)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let delegate = Delegate(mode: CommandLine.arguments[1])
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
