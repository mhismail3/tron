import Foundation

/// Bounds the status poll's Tailscale CLI spawns.
///
/// The address itself stays in the disposable `network.json` cache
/// (`readTailscaleIPFromSettings` / `cacheTailscaleIP`); this only remembers
/// when the last live probe ran, so the 30 s poll reuses one resolution instead
/// of making Tailscale reload its network extension on every cycle. Explicit
/// user actions (pairing, restart, log/feedback capture) resolve live through
/// `resolveLive` and never consult the window.
actor TailscaleHostResolution {
    /// One live CLI resolution is reused for five minutes: about 288 spawns a
    /// day instead of about 2,880 at the 30 s poll cadence.
    static let reuseInterval: TimeInterval = 300
    /// A ping that just failed may re-resolve once this much has passed, so a
    /// moved address heals inside one poll without adding spawns while the
    /// Gateway is down (no worse than the pre-change per-cycle probe).
    static let failedPingReprobeInterval: TimeInterval = 30

    private let probe: @Sendable () async -> TailscaleStatus
    private let readCached: @Sendable () -> String?
    private let writeCached: @Sendable (String) -> Void
    private var lastProbe: Date?

    init(
        probe: @escaping @Sendable () async -> TailscaleStatus,
        readCached: @escaping @Sendable () -> String?,
        writeCached: @escaping @Sendable (String) -> Void
    ) {
        self.probe = probe
        self.readCached = readCached
        self.writeCached = writeCached
    }

    /// The host to use. The CLI runs only when the last resolution is older than
    /// the applicable window, or when the disposable cache cannot answer, so a
    /// failed cache write cannot turn into a false "unreachable".
    func host(previousPingFailed: Bool = false, now: Date = Date()) async -> String? {
        let window = previousPingFailed ? Self.failedPingReprobeInterval : Self.reuseInterval
        if let lastProbe, let cached = readCached(), now.timeIntervalSince(lastProbe) < window {
            return cached
        }
        lastProbe = now
        return await resolve()
    }

    /// Live-first resolution with the disposable cache as the only fallback.
    /// Every explicit user action resolves through this directly.
    static func resolveLive(
        probe: @escaping @Sendable () async -> TailscaleStatus,
        cache: @escaping @Sendable () -> String?
    ) async -> String? {
        let live = await probe().displayIP
        for candidate in [live, cache()] {
            let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if TailscaleProbe.isTailscaleAddress(value) { return value }
        }
        return nil
    }

    private func resolve() async -> String? {
        let cached = readCached()
        let resolved = await Self.resolveLive(probe: probe, cache: { cached })
        if let resolved, resolved != cached { writeCached(resolved) }
        return resolved
    }
}
