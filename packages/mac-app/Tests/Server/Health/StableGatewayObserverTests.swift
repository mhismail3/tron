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
            processCommand: "\(root.path)/runtime/node-arm64 \(root.path)/app/dist/index.js --host tailscale --port 9847",
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
        wrongHost.processCommand = "\(root.path)/runtime/node-arm64 \(root.path)/app/dist/index.js --host 127.0.0.1 --port 9847"
        #expect(!validates(runtime: wrongHost))
    }

    @Test("rejects wrong listener PID, wrong port, and extra responder")
    func rejectsListenerAndPortMismatch() {
        #expect(!validates(listenerPIDs: [82]))
        #expect(!validates(listenerPIDs: [81, 82]))

        var wrongPort = runtime
        wrongPort.processCommand = "\(root.path)/runtime/node-arm64 \(root.path)/app/dist/index.js --host tailscale --port 9848"
        #expect(!validates(runtime: wrongPort))
    }

    private func validates(
        runtime: LaunchAgentRuntimeInfo? = nil,
        listenerPIDs: Set<Int> = [81],
        info: ServerPingInfo? = nil
    ) -> Bool {
        StableGatewayObserver.validates(
            runtimeInfo: runtime ?? self.runtime,
            listenerPIDs: listenerPIDs,
            payload: payload,
            info: info ?? self.info,
            expectedHelperPath: helper,
            fileExists: { $0 == helper }
        )
    }
}
