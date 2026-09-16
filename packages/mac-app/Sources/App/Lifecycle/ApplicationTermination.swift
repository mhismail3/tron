import AppKit

/// AppKit's `.terminateLater` loop must not retain a main-dispatch callback:
/// that prevents main-actor cleanup/reply tasks from running. Another dispatch
/// hop has the same problem. A run-loop callback escapes that queue entirely.
/// Protected by MenuBarTerminationTests' real AppKit subprocess regression.
@MainActor
enum ApplicationTermination {
    static func request() {
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated {
                NSApp.terminate(nil)
            }
        }
    }
}
