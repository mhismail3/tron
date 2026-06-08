import UIKit

/// Manages display stream state for ChatViewModel.
/// Tracks active browser/display stream frames, sheet presentation, and stop state.
@Observable
@MainActor
final class DisplayStreamState {

    /// Active stream identifier (nil when no stream is actively sending frames).
    var activeStreamId: String?

    /// Current or last frame image from the stream (persists after stream ends).
    var streamFrameImage: UIImage?

    /// Capability invocation ID that initiated the stream (persists after stream ends).
    var streamInvocationId: String?

    /// Whether the stream sheet is presented.
    var showStreamSheet = false

    /// Whether the stream sheet has been auto-opened (prevents re-opening on dismiss).
    var hasAutoOpenedStream = false

    /// Stream ID that was explicitly stopped (frames ignored until cleared).
    var stoppedStreamId: String?

    /// Whether a display stream is currently active (frames arriving).
    var isStreamActive: Bool { activeStreamId != nil }

    /// Handle an incoming display frame. Returns false if the frame was ignored (stopped stream).
    @discardableResult
    func handleFrame(streamId: String, image: UIImage, invocationId: String?) -> Bool {
        if let stopped = stoppedStreamId, stopped == streamId {
            return false
        }
        let isNewStream = (activeStreamId == nil)
        activeStreamId = streamId
        streamFrameImage = image
        streamInvocationId = invocationId
        if isNewStream && !hasAutoOpenedStream {
            showStreamSheet = true
            hasAutoOpenedStream = true
        }
        return true
    }

    /// End the active stream. Keeps frame/invocationId for post-stream viewing.
    func endStream() {
        activeStreamId = nil
    }

    /// Mark the active stream as stopped (frames will be ignored).
    func markStopped() {
        guard let streamId = activeStreamId else { return }
        stoppedStreamId = streamId
        activeStreamId = nil
    }

    /// Check if a stream ID has been stopped.
    func isStopped(streamId: String) -> Bool {
        stoppedStreamId == streamId
    }

    /// Clear all stream state (session change or disconnect).
    func clearAll() {
        activeStreamId = nil
        stoppedStreamId = nil
        streamFrameImage = nil
        streamInvocationId = nil
        showStreamSheet = false
        hasAutoOpenedStream = false
    }
}
