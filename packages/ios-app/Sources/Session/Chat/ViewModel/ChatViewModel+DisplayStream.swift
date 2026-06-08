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
    /// Keeps `streamFrameImage` and `streamInvocationId` so the capability chip
    /// can still show the last frame after the stream is over.
    func endDisplayStream() {
        displayStreamState.endStream()
    }

    /// Stop rendering the active display stream locally and keep the last frame.
    func stopDisplayStream() {
        guard let streamId = displayStreamState.activeStreamId else { return }

        displayStreamState.markStopped()
        logInfo("Stopped local display stream rendering: \(streamId)")
    }

    /// Clear all stream state (e.g., on session change or disconnect).
    func clearDisplayStreamState() {
        displayStreamState.clearAll()
    }
}
