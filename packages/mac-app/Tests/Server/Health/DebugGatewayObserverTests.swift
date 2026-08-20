import Foundation
import Testing
@testable import TronMac

@Suite("DebugGatewayObserver")
struct DebugGatewayObserverTests {
    private let fingerprint = String(repeating: "a", count: 64)
    private let root = URL(fileURLWithPath: "/tmp/DebugPayload", isDirectory: true)

    private var lifecycle: DebugGatewayObserver.Lifecycle {
        DebugGatewayObserver.Lifecycle(
            lifecycle: "ready",
            expectedHost: "tailscale",
            expectedPort: 9848,
            expectedHome: "/Users/test/.tron-dev",
            supervisorPid: 41,
            supervisorStartIdentity: "Wed Aug 20 00:00:00 2026",
            childPid: 42,
            childStartIdentity: "Wed Aug 20 00:00:01 2026",
            epoch: "epoch-1",
            sourceRevision: "revision-1",
            buildFingerprint: fingerprint
        )
    }

    private var selected: GatewayPayloadValidationResult {
        GatewayPayloadValidationResult(
            root: root,
            manifest: GatewayPayloadManifest(
                channel: "dev",
                version: "debug-1",
                gatewayVersion: "0.1.0",
                nodeVersion: "22.22.0",
                sourceRevision: "revision-1",
                runtimeEpoch: "epoch-1",
                payloadFingerprint: fingerprint
            )
        )
    }

    private var info: ServerPingInfo {
        ServerPingInfo(
            version: "0.1.0",
            gatewayChannel: "dev",
            sourceRevision: "revision-1",
            buildFingerprint: fingerprint,
            runtimeEpoch: "epoch-1"
        )
    }

    private var command: String {
        "\(root.path)/runtime/node-arm64 \(root.path)/app/dist/index.js --host tailscale --port 9848"
    }

    @Test("admits only exact supervisor, child, listener, payload, command, and authenticated identity")
    func exactAdmission() {
        #expect(validates())

        var wrongInfo = info
        wrongInfo.runtimeEpoch = "epoch-2"
        #expect(!validates(info: wrongInfo))

        var wrongChannel = info
        wrongChannel.gatewayChannel = "stable"
        #expect(!validates(info: wrongChannel))

        #expect(!validates(childStart: "reused pid"))
        #expect(!validates(listenerPIDs: [99]))
        #expect(!validates(command: "/Applications/Tron.app/Contents/Resources/Gateway/runtime/node-arm64 other --port 9848"))
    }

    @Test("orphan child is rejected when its exact supervisor is absent or reused")
    func orphanSupervisorRejected() {
        #expect(!validates(supervisorStart: nil))
        #expect(!validates(supervisorStart: "reused supervisor pid"))
        #expect(!validates(listenerPIDs: [lifecycle.childPid, 99]))
    }

    @Test("admission identity ignores display-only uptime")
    func admissionIdentityIgnoresUptime() {
        let first = DebugGatewayObserver.Admission(
            lifecycle: lifecycle,
            processID: lifecycle.childPid,
            uptime: "00:00:01",
            transportHost: "100.64.0.8",
            pairingTransportAvailable: true,
            selectedPayload: selected,
            info: info
        )
        let second = DebugGatewayObserver.Admission(
            lifecycle: lifecycle,
            processID: lifecycle.childPid,
            uptime: "00:00:59",
            transportHost: "100.64.0.8",
            pairingTransportAvailable: true,
            selectedPayload: selected,
            info: info
        )
        #expect(first == second)

        var changedLifecycle = lifecycle
        changedLifecycle.childStartIdentity = "new child"
        let replacement = DebugGatewayObserver.Admission(
            lifecycle: changedLifecycle,
            processID: changedLifecycle.childPid,
            uptime: "00:00:59",
            transportHost: "100.64.0.8",
            pairingTransportAvailable: true,
            selectedPayload: selected,
            info: info
        )
        #expect(first != replacement)
    }

    @Test("pairing is unavailable for loopback Debug")
    func pairingHostPolicy() {
        #expect(!DebugGatewayObserver.isPairingHost("127.0.0.1"))
        #expect(!DebugGatewayObserver.isPairingHost("::1"))
        #expect(DebugGatewayObserver.isPairingHost("tailscale"))
        #expect(DebugGatewayObserver.isPairingHost("100.64.0.8"))
    }

    private func validates(
        info: ServerPingInfo? = nil,
        supervisorStart: String? = "__expected__",
        childStart: String? = nil,
        listenerPIDs: Set<Int>? = nil,
        command: String? = nil
    ) -> Bool {
        let actualSupervisor = supervisorStart == "__expected__"
            ? lifecycle.supervisorStartIdentity
            : supervisorStart
        return DebugGatewayObserver.validates(
            lifecycle: lifecycle,
            selected: selected,
            info: info ?? self.info,
            observedSupervisorStartIdentity: actualSupervisor,
            observedChildStartIdentity: childStart ?? lifecycle.childStartIdentity,
            listenerPIDs: listenerPIDs ?? [lifecycle.childPid],
            processCommand: command ?? self.command
        )
    }
}
