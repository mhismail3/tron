import Darwin
import Foundation
import Testing
@testable import TronMac

@Suite("StableGatewayObserver")
struct StableGatewayObserverTests {
    private let fingerprint = String(repeating: "b", count: 64)
    private let root = URL(fileURLWithPath: "/tmp/StablePayload", isDirectory: true)
    private let helper = "/Applications/Tron.app/Contents/Library/LoginItems/Tron Agent.app/Contents/MacOS/tron"

    private var payload: GatewayPayloadValidationResult {
        GatewayPayloadValidationResult(
            root: root,
            manifest: GatewayPayloadManifest(
                channel: "stable",
                version: "stable-1",
                gatewayVersion: "0.9.0",
                nodeVersion: "22.22.0",
                sourceRevision: "revision-stable",
                runtimeEpoch: "epoch-stable",
                payloadFingerprint: fingerprint
            )
        )
    }

    private var info: ServerPingInfo {
        ServerPingInfo(
            version: "0.9.0",
            gatewayChannel: "stable",
            sourceRevision: "revision-stable",
            buildFingerprint: fingerprint,
            runtimeEpoch: "epoch-stable"
        )
    }

    private var runtime: LaunchAgentRuntimeInfo {
        LaunchAgentRuntimeInfo(
            pid: 81,
            uptime: "00:10",
            parentBundleIdentifier: MacRuntimeVariant.releaseBundleIdentifier,
            executablePath: helper,
            bundleProgram: "Contents/Library/LoginItems/Tron Agent.app/Contents/MacOS/tron",
            processCommand: "\(root.path)/runtime/node-arm64 --max-old-space-size=4096 \(root.path)/app/dist/index.js --host tailscale --port 9847",
            gatewaySupervisionMarker: TronPaths.gatewaySupervisionValue,
            gatewayChannelMarker: "stable"
        )
    }

    @Test("admits the exact Release-owned listener and payload identity")
    func exactAdmission() {
        #expect(validates())
    }

    @Test("rejects stale selected payload and unrelated authenticated responder")
    func rejectsStaleSelectionAndResponder() {
        var stale = info
        stale.runtimeEpoch = "old-runtime"
        #expect(!validates(info: stale))

        var unrelated = info
        unrelated.gatewayChannel = "dev"
        #expect(!validates(info: unrelated))

        var wrongFingerprint = info
        wrongFingerprint.buildFingerprint = String(repeating: "c", count: 64)
        #expect(!validates(info: wrongFingerprint))
    }

    @Test("unchanged admission ignores elapsed uptime, but runtime identity transitions fail")
    func admissionEqualityPinsRuntimeIdentity() {
        let pinned = StableGatewayObserver.Admission(
            processID: 81,
            uptime: "00:10",
            payload: payload,
            info: info
        )
        let unchanged = StableGatewayObserver.Admission(
            processID: 81,
            uptime: "00:11",
            payload: payload,
            info: info
        )
        var transitionedInfo = info
        transitionedInfo.runtimeEpoch = "new-runtime"
        let transitioned = StableGatewayObserver.Admission(
            processID: 81,
            uptime: "00:11",
            payload: payload,
            info: transitionedInfo
        )

        #expect(pinned == unchanged)
        #expect(pinned != transitioned)
    }

    @Test("final pairing admission re-ping accepts unchanged runtime and rejects transition")
    func finalPairingAdmissionRevalidation() async {
        let pinned = StableGatewayObserver.Admission(
            processID: 81,
            uptime: "00:10",
            payload: payload,
            info: info
        )
        let unchanged = await StableGatewayObserver.revalidatePairingAdmission(
            pinned: pinned,
            token: "token",
            ping: { token in
                #expect(token == "token")
                return .success(self.info)
            },
            admit: { info in
                StableGatewayObserver.Admission(
                    processID: 81,
                    uptime: "00:11",
                    payload: self.payload,
                    info: info
                )
            }
        )
        #expect(unchanged == pinned)

        let transitioned = await StableGatewayObserver.revalidatePairingAdmission(
            pinned: pinned,
            token: "token",
            ping: { _ in .success(self.info) },
            admit: { info in
                StableGatewayObserver.Admission(
                    processID: 82,
                    uptime: "00:11",
                    payload: self.payload,
                    info: info
                )
            }
        )
        #expect(transitioned == nil)
    }

    @Test("rejects wrong host even when payload and process otherwise match")
    func rejectsHostMismatch() {
        var wrongHost = runtime
        wrongHost.processCommand = "\(root.path)/runtime/node-arm64 --max-old-space-size=4096 \(root.path)/app/dist/index.js --host 127.0.0.1 --port 9847"
        #expect(!validates(runtime: wrongHost))
    }

    @Test("refuses command lines the launcher never execs and names that check")
    func refusesOtherLaunchArguments() {
        let node = "\(root.path)/runtime/node-arm64"
        let entry = "\(root.path)/app/dist/index.js"
        for command in [
            "\(node) \(entry) --host tailscale --port 9847", // a launcher from before the heap limit
            "\(node) --max-old-space-size=8192 \(entry) --host tailscale --port 9847",
            "\(node) \(entry) --max-old-space-size=4096 --host tailscale --port 9847",
            "\(node) --max-old-space-size=4096 --inspect \(entry) --host tailscale --port 9847",
        ] {
            var other = runtime
            other.processCommand = command
            #expect(refusal(runtime: other) == .processCommand, "\(command)")
        }
    }

    @Test("rejects wrong listener PID, wrong port, and extra responder")
    func rejectsListenerAndPortMismatch() {
        #expect(!validates(listenerPIDs: [82]))
        #expect(!validates(listenerPIDs: [81, 82]))

        var wrongPort = runtime
        wrongPort.processCommand = "\(root.path)/runtime/node-arm64 --max-old-space-size=4096 \(root.path)/app/dist/index.js --host tailscale --port 9848"
        #expect(!validates(runtime: wrongPort))
    }

    @Test("the runtime fence follows an atomic selection and manifest replacement")
    func runtimeFenceFollowsDeployment() async throws {
        let fixture = try makeFenceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try select("v1", in: fixture.store)
        let first = await readFence(fixture)
        try select("v2", in: fixture.store)
        let second = await readFence(fixture)
        // An absent selection pointer is the deployment's own fallback, exactly
        // as `activePayload` resolves the active payload.
        try FileManager.default.removeItem(at: fixture.store.currentManifestURL)
        let fallback = await readFence(fixture)

        #expect(first != nil && second != nil)
        #expect(first != second)
        #expect(first?.manifest.bytes == Data("manifest-1".utf8))
        #expect(second?.manifest.bytes == Data("manifest-2".utf8))
        #expect(fallback?.manifest.bytes == Data("bundled-manifest".utf8))
    }

    @Test("the fence follows the bundled manifest even when the selection names a selected version")
    func runtimeFenceTracksTheBundledManifest() async throws {
        let fixture = try makeFenceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        // The selection names v1, whose manifest exists, so the fence stamps it
        // as the active manifest. When v1's payload does not validate,
        // `activePayload` admits the bundled payload instead — replacing the
        // app bundle must still move the fence.
        try select("v1", in: fixture.store)
        let before = await readFence(fixture)
        try Data("bundled-manifest-2".utf8).write(to: fixture.bundled.appendingPathComponent("manifest.json"))
        let after = await readFence(fixture)

        #expect(before != nil && after != nil)
        #expect(before != after)
        #expect(after?.bundledManifest.bytes == Data("bundled-manifest-2".utf8))
        #expect(after?.manifest.bytes == Data("manifest-1".utf8))
    }

    @Test("a selection or manifest that exists but cannot be stamped makes the fence unreadable")
    func runtimeFenceIsUnreadableWhenAStampCannotBeRead() async throws {
        let fixture = try makeFenceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try select("v1", in: fixture.store)
        // Empty is a file the fence must stamp but cannot trust.
        try Data().write(to: fixture.store.currentManifestURL)
        #expect(await readFence(fixture) == nil)

        try select("v1", in: fixture.store)
        try Data().write(to: fixture.store.versionRoot("v1").appendingPathComponent("manifest.json"))
        #expect(await readFence(fixture) == nil)
    }

    @Test("one ps read yields the fence's start identity and elapsed time")
    func processFenceReadYieldsBothValues() async {
        let read = await ServerProcessProbe.processFenceRead(pid: Int(getpid()))
        #expect(read?.startIdentity.isEmpty == false)
        #expect(read?.elapsedTime.isEmpty == false)
    }

    private struct FenceFixture {
        let root: URL
        let store: GatewayPayloadStore
        let bundled: URL
    }

    /// A temporary payload store with two deployable versions and a bundled
    /// fallback. The fence is a change detector over real files, so its tests
    /// must run the production read instead of a hand-built fence.
    private func makeFenceFixture() throws -> FenceFixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("StableRuntimeFence-\(UUID().uuidString)", isDirectory: true)
        let bundled = root.appendingPathComponent("bundled", isDirectory: true)
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        try Data("bundled-manifest".utf8).write(to: bundled.appendingPathComponent("manifest.json"))
        let store = GatewayPayloadStore(home: root, channel: "stable")
        for (version, manifest) in [("v1", "manifest-1"), ("v2", "manifest-2")] {
            let versionRoot = store.versionRoot(version)
            try FileManager.default.createDirectory(at: versionRoot, withIntermediateDirectories: true)
            try Data(manifest.utf8).write(to: versionRoot.appendingPathComponent("manifest.json"))
        }
        return FenceFixture(root: root, store: store, bundled: bundled)
    }

    /// Replaces the selection pointer the way deployment does.
    private func select(_ version: String, in store: GatewayPayloadStore) throws {
        let temporary = store.channelRoot.appendingPathComponent("current.json.deploy")
        let json = Data(
            #"{"schema":1,"kind":"tron-gateway-selection","channel":"stable","version":"\#(version)","payloadFingerprint":"\#(fingerprint)"}"#.utf8
        )
        try json.write(to: temporary)
        guard rename(temporary.path, store.currentManifestURL.path) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func readFence(_ fixture: FenceFixture) async -> StableGatewayObserver.RuntimeFence? {
        await StableGatewayObserver.RuntimeFence.read(
            label: "com.tron.server",
            store: fixture.store,
            bundledPayloadRoot: fixture.bundled,
            processFence: { _ in
                LaunchAgentProcessFence(
                    pid: 81, startIdentity: "Mon Sep 28 10:00:00 2026", elapsedTime: "00:10"
                )
            }
        )
    }

    private func validates(
        runtime: LaunchAgentRuntimeInfo? = nil,
        listenerPIDs: Set<Int> = [81],
        info: ServerPingInfo? = nil
    ) -> Bool {
        refusal(runtime: runtime, listenerPIDs: listenerPIDs, info: info) == nil
    }

    private func refusal(
        runtime: LaunchAgentRuntimeInfo? = nil,
        listenerPIDs: Set<Int> = [81],
        info: ServerPingInfo? = nil
    ) -> StableGatewayObserver.Refusal? {
        StableGatewayObserver.refusal(
            runtimeInfo: runtime ?? self.runtime,
            listenerPIDs: listenerPIDs,
            payload: payload,
            info: info ?? self.info,
            expectedHelperPath: helper,
            fileExists: { $0 == helper }
        )
    }
}
