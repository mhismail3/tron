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
        var quitInProgress = false
        init(mode: String) { self.mode = mode }

        func applicationDidFinishLaunching(_ notification: Notification) {
            log("application-ready")
            guard !mode.hasPrefix("replacement") else { return }
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
            if mode.hasPrefix("replacement"), quitInProgress { return .terminateCancel }
            quitInProgress = true
            attempts += 1
            log("termination-requested")
            Task { @MainActor in
                log("reply-task-ran")
                if mode.hasPrefix("replacement") {
                    let ps = Process()
                    ps.executableURL = URL(fileURLWithPath: "/bin/ps")
                    ps.arguments = ["-p", String(getpid()), "-o", "lstart="]
                    let pipe = Pipe()
                    ps.standardOutput = pipe
                    do { try ps.run() } catch { _exit(43) }
                    let start = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    ps.waitUntilExit()
                    let completed = await ApplicationTermination.complete(
                        directory: URL(fileURLWithPath: CommandLine.arguments[2]), pid: Int(getpid()), start: start,
                        quit: { progress in
                            await progress("fixture Gateway draining")
                            if mode == "replacement" { try await Task.sleep(for: .seconds(2)) }
                            if mode == "replacement-failure", attempts == 1 {
                                throw NSError(domain: "Fixture Quit refused", code: 1)
                            }
                        },
                        ordinaryFailure: { _ in log("ordinary-modal-would-open") },
                        receiptFailure: { _ in log("receipt-publication-failed") }
                    )
                    if !completed { quitInProgress = false; log("termination-cancelled") }
                } else if mode == "retry", attempts == 1 {
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
        let replacement = CommandLine.arguments[1].hasPrefix("replacement")
        DispatchQueue.global().asyncAfter(deadline: .now() + (replacement ? 30 : 2)) {
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
