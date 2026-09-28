import Foundation
import Testing
@testable import TronMac

/// Failure modes recorded before this test was written:
/// 1. a reused admission outlives a real runtime change (new pid, or the same
///    pid with a new start identity);
/// 2. a reused admission outlives a payload selection change;
/// 3. an unreadable runtime fence authorizes reuse;
/// 4. reuse skips the per-cycle authenticated ping;
/// 5. reuse outlives the authenticated ping identity it was proved against;
/// 6. a transient refusal is reused, pinning "needs repair" for as long as the
///    process lives;
/// 7. a reused admission freezes the displayed uptime at the value the first
///    probe saw.
@Suite("ServerStatusPoller — bounded admission reuse")
struct ServerStatusPollerBoundedAdmissionTests {
    private actor RuntimeFenceFeed {
        private var upcoming: [StableGatewayObserver.RuntimeFence?]

        init(_ values: [StableGatewayObserver.RuntimeFence?]) {
            precondition(!values.isEmpty)
            upcoming = values
        }

        /// One value per call; the last value repeats.
        func next() -> StableGatewayObserver.RuntimeFence? {
            if upcoming.count > 1 { return upcoming.removeFirst() }
            return upcoming[0]
        }
    }

    private actor CallCounter {
        private(set) var count = 0

        func record() { count += 1 }
    }

    /// One authenticated `system::ping` info per call; the last value repeats.
    private actor PingInfoFeed {
        private var versions: [String]

        init(_ versions: [String]) {
            precondition(!versions.isEmpty)
            self.versions = versions
        }

        func next() -> ServerPingResult {
            let version = versions.count > 1 ? versions.removeFirst() : versions[0]
            return .success(ServerPingInfo(version: version, gatewayChannel: "stable"))
        }
    }

    private static func stamp(_ bytes: String) -> PayloadSelectionStamp {
        PayloadSelectionStamp(exists: true, device: 1, inode: 7, modified: 10, nanos: 0, bytes: Data(bytes.utf8))
    }

    private static func fence(
        pid: Int = 16027,
        startIdentity: String = "Mon Sep 28 10:00:00 2026",
        elapsedTime: String = "01:07:42",
        selection: PayloadSelectionStamp = stamp("selection-1"),
        manifest: PayloadSelectionStamp = stamp("manifest-1")
    ) -> StableGatewayObserver.RuntimeFence {
        StableGatewayObserver.RuntimeFence(
            process: LaunchAgentProcessFence(pid: pid, startIdentity: startIdentity, elapsedTime: elapsedTime),
            selection: selection,
            manifest: manifest
        )
    }

    private static func admission(info: ServerPingInfo, processID: Int) -> StableGatewayObserver.Admission {
        StableGatewayObserver.Admission(
            processID: processID,
            uptime: "01:07:42",
            payload: GatewayPayloadValidationResult(
                root: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
                manifest: GatewayPayloadManifest(
                    channel: "stable", version: "test", gatewayVersion: info.version,
                    nodeVersion: "22", sourceRevision: "revision", runtimeEpoch: "epoch",
                    payloadFingerprint: String(repeating: "a", count: 64)
                )
            ),
            info: info
        )
    }

    private static func makeSetup(
        processID: Int = 16027,
        probes: CallCounter,
        pings: CallCounter
    ) -> EnvironmentSetup {
        ServerStatusPollerTests.makeSetup(
            token: "abc123",
            tailscaleFromSettings: "100.64.0.1",
            admitStableRuntime: { info in
                await probes.record()
                return admission(info: info, processID: processID)
            },
            pingServer: { _ in
                await pings.record()
                return .success(ServerPingInfo(version: "0.5.0", gatewayChannel: "stable"))
            }
        )
    }

    private static func cache(_ feed: RuntimeFenceFeed, setup: EnvironmentSetup) -> StableProbeCache {
        StableProbeCache(
            runtimeFence: { await feed.next() },
            fullProbe: { info in await ServerStatusPoller.fullProbe(setup: setup, info: info) }
        )
    }

    @Test("reuses one admission while the runtime fence is unchanged, and republishes the fence's uptime")
    func reusesAdmissionAndRepublishesFenceUptime() async {
        let probes = CallCounter()
        let pings = CallCounter()
        let setup = Self.makeSetup(probes: probes, pings: pings)
        let feed = RuntimeFenceFeed([
            Self.fence(elapsedTime: "01:07:42"),
            Self.fence(elapsedTime: "01:08:12"),
            Self.fence(elapsedTime: "01:08:42"),
        ])
        let probeCache = Self.cache(feed, setup: setup)

        let snapshots = [
            await ServerStatusPoller.singleSnapshot(setup: setup, probeCache: probeCache),
            await ServerStatusPoller.singleSnapshot(setup: setup, probeCache: probeCache),
            await ServerStatusPoller.singleSnapshot(setup: setup, probeCache: probeCache),
        ]

        #expect(snapshots.allSatisfy { $0.state == .running(version: "0.5.0", port: 9847) })
        #expect(snapshots.allSatisfy { $0.processID == 16027 })
        // Failure mode 7: a reused admission must not freeze the menu's uptime.
        #expect(snapshots.map(\.uptime) == ["01:07:42", "01:08:12", "01:08:42"])
        #expect(await probes.count == 1)
        // Failure mode 4: the liveness ping still runs every cycle.
        #expect(await pings.count == 3)
    }

    @Test("a changed launchd process identity re-admits instead of reusing")
    func changedProcessIdentityReadmits() async {
        let probes = CallCounter()
        let pings = CallCounter()
        let setup = Self.makeSetup(processID: 4242, probes: probes, pings: pings)
        let feed = RuntimeFenceFeed([
            Self.fence(),
            Self.fence(pid: 4242, startIdentity: "Mon Sep 28 11:00:00 2026"),
        ])
        let probeCache = Self.cache(feed, setup: setup)

        _ = await ServerStatusPoller.singleSnapshot(setup: setup, probeCache: probeCache)
        let afterRestart = await ServerStatusPoller.singleSnapshot(setup: setup, probeCache: probeCache)

        #expect(await probes.count == 2)
        #expect(afterRestart.processID == 4242)
    }

    @Test("a changed payload selection stamp re-admits instead of reusing")
    func changedSelectionStampReadmits() async {
        let probes = CallCounter()
        let pings = CallCounter()
        let setup = Self.makeSetup(probes: probes, pings: pings)
        let feed = RuntimeFenceFeed([Self.fence(), Self.fence(selection: Self.stamp("deployed-selection"))])
        let probeCache = Self.cache(feed, setup: setup)

        _ = await ServerStatusPoller.singleSnapshot(setup: setup, probeCache: probeCache)
        _ = await ServerStatusPoller.singleSnapshot(setup: setup, probeCache: probeCache)

        #expect(await probes.count == 2)
    }

    @Test("an unreadable runtime fence never authorizes reuse")
    func unreadableFenceNeverReuses() async {
        let probes = CallCounter()
        let pings = CallCounter()
        let setup = Self.makeSetup(probes: probes, pings: pings)
        let feed = RuntimeFenceFeed([nil, nil, nil])
        let probeCache = Self.cache(feed, setup: setup)

        _ = await ServerStatusPoller.singleSnapshot(setup: setup, probeCache: probeCache)
        _ = await ServerStatusPoller.singleSnapshot(setup: setup, probeCache: probeCache)
        _ = await ServerStatusPoller.singleSnapshot(setup: setup, probeCache: probeCache)

        #expect(await probes.count == 3)
    }

    @Test("a refusal is re-proved on the next cycle under the same fence")
    func refusalIsNotReused() async {
        let attempts = CallCounter()
        let pings = CallCounter()
        let setup = ServerStatusPollerTests.makeSetup(
            token: "abc123",
            admitStableRuntime: { info in
                await attempts.record()
                // One transient listener read failure must not pin needs-repair.
                guard await attempts.count > 1 else { return nil }
                return Self.admission(info: info, processID: 16027)
            },
            pingServer: { _ in
                await pings.record()
                return .success(ServerPingInfo(version: "0.5.0", gatewayChannel: "stable"))
            }
        )
        let feed = RuntimeFenceFeed([Self.fence(), Self.fence()])
        let probeCache = Self.cache(feed, setup: setup)

        let refused = await ServerStatusPoller.singleSnapshot(setup: setup, probeCache: probeCache)
        let recovered = await ServerStatusPoller.singleSnapshot(setup: setup, probeCache: probeCache)

        guard case .needsRepair = refused.state else {
            Issue.record("expected the first cycle to report needsRepair, got \(refused.state)")
            return
        }
        #expect(refused.processID == nil && refused.uptime == nil)
        #expect(recovered.state == .running(version: "0.5.0", port: 9847))
        #expect(recovered.processID == 16027)
        #expect(await attempts.count == 2)
    }

    @Test("a changed authenticated ping identity re-admits instead of reusing")
    func changedPingIdentityReadmits() async {
        let probes = CallCounter()
        let versions = PingInfoFeed(["0.5.0", "0.6.0"])
        let setup = ServerStatusPollerTests.makeSetup(
            token: "abc123",
            admitStableRuntime: { info in
                await probes.record()
                return Self.admission(info: info, processID: 16027)
            },
            pingServer: { _ in await versions.next() }
        )
        let feed = RuntimeFenceFeed([Self.fence(), Self.fence()])
        let probeCache = Self.cache(feed, setup: setup)

        let first = await ServerStatusPoller.singleSnapshot(setup: setup, probeCache: probeCache)
        let second = await ServerStatusPoller.singleSnapshot(setup: setup, probeCache: probeCache)

        #expect(first.state == .running(version: "0.5.0", port: 9847))
        #expect(second.state == .running(version: "0.6.0", port: 9847))
        #expect(await probes.count == 2)
    }

    @Test("the poll cycle pings through the poll's bounded resolution; an explicit action keeps pingServer")
    func pollCycleKeepsItsBoundedPing() async {
        let probes = CallCounter()
        let livePings = CallCounter()
        let boundedPings = CallCounter()
        let setup = Self.makeSetup(probes: probes, pings: livePings)
        let feed = RuntimeFenceFeed([Self.fence(), Self.fence()])
        let probeCache = Self.cache(feed, setup: setup)

        let polled = await ServerStatusPoller.singleSnapshot(
            setup: setup,
            probeCache: probeCache,
            pingServer: { _ in
                await boundedPings.record()
                return .success(ServerPingInfo(version: "0.5.0", gatewayChannel: "stable"))
            }
        )
        let explicit = await ServerStatusPoller.singleSnapshot(setup: setup)

        #expect(polled.state == .running(version: "0.5.0", port: 9847))
        #expect(explicit.state == .running(version: "0.5.0", port: 9847))
        #expect(await boundedPings.count == 1)
        #expect(await livePings.count == 1)
    }

    @Test("an explicit user action never reuses the cached admission")
    func explicitActionReprobes() async {
        let probes = CallCounter()
        let pings = CallCounter()
        let setup = Self.makeSetup(probes: probes, pings: pings)
        let feed = RuntimeFenceFeed([Self.fence()])
        let probeCache = Self.cache(feed, setup: setup)

        _ = await ServerStatusPoller.singleSnapshot(setup: setup, probeCache: probeCache)
        _ = await ServerStatusPoller.singleSnapshot(setup: setup)

        #expect(await probes.count == 2)
    }
}
