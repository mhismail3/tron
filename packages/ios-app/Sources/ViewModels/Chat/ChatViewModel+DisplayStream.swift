import Foundation
import UIKit

// MARK: - Display Stream State & Handler

extension ChatViewModel: DisplayStreamEventHandler {

    // MARK: - Handler

    func handleDisplayFrame(_ result: DisplayFramePlugin.Result) {
        displayStreamState.handleFrame(streamId: result.streamId, image: result.image, invocationId: result.invocationId)
    }

    // MARK: - Stream Lifecycle

    /// Called when the stream ends (agent complete, frames stop arriving).
    /// Keeps `streamFrameImage` and `streamInvocationId` so the tool chip
    /// can still show the last frame after the stream is over.
    func endDisplayStream() {
        displayStreamState.endStream()
    }

    /// Stop the active display stream via engine protocol and clean up active state.
    /// Keeps the last frame for post-stream viewing.
    func stopDisplayStream() {
        guard let streamId = displayStreamState.activeStreamId else { return }

        displayStreamState.markStopped()

        launchBackground { [weak self] in
            guard let self else { return }
            do {
                let _ = try await self.engineClient.display.stopStream(streamId: streamId, idempotencyKey: .userAction("display.stopStream"))
                self.logInfo("Stopped display stream: \(streamId)")
            } catch {
                self.logWarning("Failed to stop display stream: \(error)")
            }
        }
    }

    /// Clear all stream state (e.g., on session change or disconnect).
    func clearDisplayStreamState() {
        displayStreamState.clearAll()
    }
}
