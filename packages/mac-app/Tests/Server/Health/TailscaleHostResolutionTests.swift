import Foundation
import Testing
@testable import TronMac

/// Failure modes recorded before this test was written:
/// 1. the window reuses an address past its interval;
/// 2. a moved address is never re-resolved after a failed ping, or a failed
///    ping reloads the CLI on every cycle;
/// 3. an address the disposable cache cannot answer is reused without a probe;
/// 4. a newly resolved address is not persisted, so the menu bar keeps
///    presenting a different host than the poll pings.
@Suite("TailscaleHostResolution — bounded CLI spawns")
struct TailscaleHostResolutionTests {
    /// The window's cache closures are synchronous (the disposable cache is one
    /// small owner-only file read), so the fixture guards its state with a lock.
    private final class Fixture: @unchecked Sendable {
        private let lock = NSLock()
        private var status: TailscaleStatus
        private var cached: String?
        private var probeCount = 0
        private var writeLog: [String] = []

        init(status: TailscaleStatus, cached: String?) {
            self.status = status
            self.cached = cached
        }

        func probe() -> TailscaleStatus {
            lock.withLock {
                probeCount += 1
                return status
            }
        }

        func read() -> String? { lock.withLock { cached } }

        func write(_ value: String) {
            lock.withLock {
                writeLog.append(value)
                cached = value
            }
        }

        func setCached(_ value: String?) { lock.withLock { cached = value } }

        func counts() -> (probes: Int, writes: [String]) { lock.withLock { (probeCount, writeLog) } }
    }

    private static func resolution(_ fixture: Fixture, persist: Bool = true) -> TailscaleHostResolution {
        TailscaleHostResolution(
            probe: { fixture.probe() },
            readCached: { fixture.read() },
            writeCached: { value in if persist { fixture.write(value) } }
        )
    }

    @Test("reuses one live resolution inside the reuse window")
    func reusesResolutionInsideWindow() async {
        let fixture = Fixture(status: .signedIn(address: "100.64.0.2"), cached: nil)
        let resolution = Self.resolution(fixture)
        let start = Date()

        #expect(await resolution.host(now: start) == "100.64.0.2")
        #expect(await resolution.host(now: start.addingTimeInterval(10)) == "100.64.0.2")

        let counts = fixture.counts()
        #expect(counts.probes == 1)
        #expect(counts.writes == ["100.64.0.2"])
    }

    @Test("re-resolves once the reuse window has passed")
    func rereolvesAfterReuseWindow() async {
        let fixture = Fixture(status: .signedIn(address: "100.64.0.2"), cached: nil)
        let resolution = Self.resolution(fixture)
        let start = Date()

        _ = await resolution.host(now: start)
        _ = await resolution.host(now: start.addingTimeInterval(TailscaleHostResolution.reuseInterval + 1))

        let counts = fixture.counts()
        #expect(counts.probes == 2)
        #expect(counts.writes == ["100.64.0.2"])
    }

    @Test("a failed ping re-resolves only after the failed-ping window")
    func failedPingReresolvesAfterWindow() async {
        let fixture = Fixture(status: .signedIn(address: "100.64.0.2"), cached: nil)
        let resolution = Self.resolution(fixture)
        let start = Date()

        _ = await resolution.host(now: start)
        // Inside the failed-ping window: no second spawn for a Gateway that is down.
        _ = await resolution.host(previousPingFailed: true, now: start.addingTimeInterval(10))
        #expect(fixture.counts().probes == 1)
        // Past it: the reused address may have moved, so resolve again.
        _ = await resolution.host(
            previousPingFailed: true,
            now: start.addingTimeInterval(TailscaleHostResolution.failedPingReprobeInterval + 1)
        )
        #expect(fixture.counts().probes == 2)
    }

    @Test("does not reuse an address the disposable cache cannot answer")
    func unansweredCacheResolvesLive() async {
        let fixture = Fixture(status: .signedIn(address: "100.64.0.2"), cached: nil)
        // The cache write is unavailable, as an unwritable network.json is.
        let resolution = Self.resolution(fixture, persist: false)
        let start = Date()

        #expect(await resolution.host(now: start) == "100.64.0.2")
        #expect(await resolution.host(now: start.addingTimeInterval(10)) == "100.64.0.2")

        #expect(fixture.counts().probes == 2)
    }

    @Test("persists a resolved address that changed")
    func persistsChangedAddress() async {
        let fixture = Fixture(status: .signedIn(address: "100.64.0.2"), cached: "100.64.0.1")
        let resolution = Self.resolution(fixture)
        let start = Date()

        #expect(await resolution.host(now: start) == "100.64.0.2")
        #expect(fixture.counts().writes == ["100.64.0.2"])

        // An unchanged address needs no write.
        fixture.setCached("100.64.0.2")
        _ = await resolution.host(now: start.addingTimeInterval(TailscaleHostResolution.reuseInterval + 1))
        #expect(fixture.counts().writes == ["100.64.0.2"])

        // A live address wins; the disposable cache is the only fallback.
        #expect(await TailscaleHostResolution.resolveLive(
            probe: { .signedIn(address: "100.64.0.4") },
            cache: { "100.64.0.5" }
        ) == "100.64.0.4")
        #expect(await TailscaleHostResolution.resolveLive(
            probe: { .notInstalled },
            cache: { "100.64.0.5" }
        ) == "100.64.0.5")
        #expect(await TailscaleHostResolution.resolveLive(
            probe: { .notInstalled },
            cache: { "127.0.0.1" }
        ) == nil)
    }
}
