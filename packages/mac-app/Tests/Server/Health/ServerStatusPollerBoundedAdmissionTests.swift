import Foundation
import Testing
@testable import TronMac

/// Failure modes recorded before this test was written:
/// 1. a reused admission outlives a real runtime change (new pid, or the same
///    pid with a new start identity);
/// 2. a reused admission outlives a payload selection change;
/// 3. an unreadable runtime fence authorizes reuse;
/// 4. reuse skips the per-cycle authenticated ping;
/// 5. a refused admission is re-proved on every cycle instead of being reused.
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

    private static func fence(
        pid: Int = 16027,
        startIdentity: String = "Mon Sep 28 10:00:00 2026",
        selection: PayloadSelectionStamp? = nil
    ) -> StableGatewayObserver.RuntimeFence {
        StableGatewayObserver.RuntimeFence(
            process: LaunchAgentProcessFence(pid: pid, startIdentity: startIdentity),
            selection: selection,
            manifest: nil
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

    @Test("reuses one admission while the runtime fence is unchanged")
    func reusesAdmissionWhileFenceUnchanged() async {
        let probes = CallCounter()
        let pings = CallCounter()
        let setup = Self.makeSetup(probes: probes, pings: pings)
        let feed = RuntimeFenceFeed([Self.fence(), Self.fence(), Self.fence()])
        let probeCache = Self.cache(feed, setup: setup)

        let snapshots = [
            await ServerStatusPoller.singleSnapshot(setup: setup, probeCache: probeCache),
            await ServerStatusPoller.singleSnapshot(setup: setup, probeCache: probeCache),
            await ServerStatusPoller.singleSnapshot(setup: setup, probeCache: probeCache),
        ]

        #expect(snapshots.allSatisfy { $0.state == .running(version: "0.5.0", port: 9847) })
        #expect(snapshots.allSatisfy { $0.processID == 16027 && $0.uptime == "01:07:42" })
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
        let deployed = PayloadSelectionStamp(
            exists: true, device: 1, inode: 7, modified: 10, nanos: 0, bytes: Data("{}".utf8)
        )
        let feed = RuntimeFenceFeed([Self.fence(), Self.fence(selection: deployed)])
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

    @Test("a refused admission is reused while the fence is unchanged")
    func refusedAdmissionIsReused() async {
        let probes = CallCounter()
        let pings = CallCounter()
        let setup = ServerStatusPollerTests.makeSetup(
            token: "abc123",
            admitStableRuntime: { _ in
                await probes.record()
                return nil
            },
            pingServer: { _ in
                await pings.record()
                return .success(ServerPingInfo(version: "0.5.0", gatewayChannel: "stable"))
            }
        )
        let feed = RuntimeFenceFeed([Self.fence(), Self.fence(), Self.fence()])
        let probeCache = Self.cache(feed, setup: setup)

        let snapshots = [
            await ServerStatusPoller.singleSnapshot(setup: setup, probeCache: probeCache),
            await ServerStatusPoller.singleSnapshot(setup: setup, probeCache: probeCache),
            await ServerStatusPoller.singleSnapshot(setup: setup, probeCache: probeCache),
        ]

        #expect(snapshots.allSatisfy { if case .needsRepair = $0.state { return true } else { return false } })
        #expect(snapshots.allSatisfy { $0.processID == nil && $0.uptime == nil })
        #expect(await probes.count == 1)
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
