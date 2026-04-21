import Foundation

/// Minimal handle on a live streaming message captured at the
/// moment `cleanUpStreamingState` runs for a reconstruction cycle.
///
/// The live path streams text deltas into an in-memory bubble with a
/// unique UUID. When the client briefly disconnects and reconnects,
/// reconstruction rebuilds messages from persisted events and replaces
/// the live bubble with a freshly-constructed one — different UUID,
/// different scroll identity, visible flicker even though the text
/// converges.
///
/// Capturing the pre-cleanup UUID here lets `processInFlightState`
/// reuse it: if the reconstructed in-flight streaming text extends
/// from (or matches) the captured text, the UI keeps the same bubble
/// and the animation stays continuous.
///
/// The snapshot is in-memory-only; its lifetime is a single
/// disconnect → reconstruct → drain cycle on one `ChatViewModel`
/// instance. Session switch constructs a new view model (see H8) and
/// therefore starts with a nil snapshot by construction.
struct StreamingRecoverySnapshot: Equatable {
    /// The streaming message's UUID at cleanup time. Reused on
    /// reconstruction so the bubble's identity is preserved.
    let messageId: UUID

    /// The accumulated text that was on screen at cleanup time.
    /// Reconstruction compares this against the server-reported
    /// in-flight text: if the in-flight text starts with (or equals)
    /// this value, it's a safe continuation and the UUID is reused.
    /// Otherwise the snapshot is discarded (with a warning if the
    /// reconstructed history doesn't cover the captured text — a
    /// potential data-loss signal).
    let text: String
}
