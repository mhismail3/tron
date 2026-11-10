import Foundation

actor TailscaleHostResolution {
    static let reuseInterval: TimeInterval = 300
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

    func host(previousPingFailed: Bool = false, now: Date = Date()) async -> String? {
        let window = previousPingFailed ? Self.failedPingReprobeInterval : Self.reuseInterval
        if let lastProbe, let cached = readCached(), now.timeIntervalSince(lastProbe) < window {
            return cached
        }
        lastProbe = now
        return await resolve()
    }

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
