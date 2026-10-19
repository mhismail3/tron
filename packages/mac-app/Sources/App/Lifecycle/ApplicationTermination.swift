import AppKit

/// AppKit's `.terminateLater` loop must not retain a main-dispatch callback:
/// that prevents main-actor cleanup/reply tasks from running. Another dispatch
/// hop has the same problem. A run-loop callback escapes that queue entirely.
/// Protected by MenuBarTerminationTests' real AppKit subprocess regression.
@MainActor
enum ApplicationTermination {
    /// Same deferred AppKit owner for menu Quit and unattended replacement.
    /// A matching replacement reports failure to its runner, never a modal.
    /// Returning false cancels only UI termination, not an accepted Gateway drain.
    static func complete(
        directory: URL, pid: Int, start: String?,
        quit: (@escaping @Sendable (String) async -> Void) async throws -> Void,
        ordinaryFailure: (Error) -> Void,
        receiptFailure: @escaping @Sendable (Error) -> Void
    ) async -> Bool {
        let replacement = MacReplacementQuit.current(directory: directory, pid: pid, start: start)
        let publish: @Sendable (String, String) -> Void = { state, detail in
            do { try replacement?.publish(directory: directory, state: state, detail: detail) }
            catch { receiptFailure(error) }
        }
        do {
            try await quit { publish("waiting", $0) }
            publish("stopped", "Gateway and native helper retired; app exiting")
            replyToPendingTermination(shouldTerminate: true)
            return true
        } catch {
            if replacement != nil { publish("failed", error.localizedDescription) }
            else { ordinaryFailure(error) }
            replyToPendingTermination(shouldTerminate: false)
            return false
        }
    }

    static func request() {
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated {
                NSApp.terminate(nil)
            }
        }
    }

    static func replyToPendingTermination(shouldTerminate: Bool) {
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated {
                NSApp.reply(toApplicationShouldTerminate: shouldTerminate)
            }
        }
    }
}
