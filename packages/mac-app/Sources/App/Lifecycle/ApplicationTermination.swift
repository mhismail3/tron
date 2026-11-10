import AppKit

@MainActor
enum ApplicationTermination {
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
