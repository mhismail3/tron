import Foundation
import Testing
@testable import TronMobile

@MainActor
@Suite("Gateway update control plane", .serialized)
struct GatewayUpdateControlPlaneTests {
    @Test("GatewayInfo requires a bounded authenticated channel while runtime identity remains optional")
    func gatewayInfoChannelAdmission() throws {
        let data = Data(#"{"gatewayVersion":"1","piVersion":"2","protocolVersion":4,"minProtocolVersion":4,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":[]}"#.utf8)
        let info = try JSONDecoder.gateway.decode(GatewayInfo.self, from: data)
        #expect(info.machineGroupID == "machine")
        #expect(info.gatewayChannel == "stable")
        #expect(info.sourceRevision == nil)
        #expect(info.runtimeEpoch == nil)
        for malformed in [
            #"{"gatewayVersion":"1","piVersion":"2","protocolVersion":4,"minProtocolVersion":4,"machineId":"machine","machineName":"Mac","capabilities":[]}"#,
            #"{"gatewayVersion":"1","piVersion":"2","protocolVersion":4,"minProtocolVersion":4,"machineId":"machine","machineName":"Mac","gatewayChannel":"preview","capabilities":[]}"#,
        ] {
            #expect(throws: Error.self) {
                _ = try JSONDecoder.gateway.decode(GatewayInfo.self, from: Data(malformed.utf8))
            }
        }
    }

    @Test("update config admits legacy optional artifact roots and bounded paths")
    func updateConfigAdmission() throws {
        let data = Data(#"{"schema":1,"kind":"tron-gateway-update-config","sourceRoot":"/Users/name/Workspace/tron","updatedAt":"2026-01-01T00:00:00Z"}"#.utf8)
        let config = try JSONDecoder.gateway.decode(GatewayUpdateConfig.self, from: data)
        #expect(config.artifactRoot == nil)
        #expect(config.sourceRoot == "/Users/name/Workspace/tron")
        #expect(throws: GatewayFailure.self) {
            _ = try JSONDecoder.gateway.decode(
                GatewayUpdateConfig.self,
                from: Data(#"{"schema":1,"kind":"tron-gateway-update-config","sourceRoot":"relative/path","updatedAt":"2026-01-01T00:00:00Z"}"#.utf8)
            )
        }
        #expect(throws: GatewayFailure.self) {
            _ = try GatewayUpdateConfig(
                sourceRoot: "/" + String(repeating: "x", count: GatewayUpdateConfigPolicy.maximumPathBytes),
                updatedAt: "2026-01-01T00:00:00Z"
            )
        }
    }

    @Test("server detail keeps opaque identities behind technical details and unifies source configuration")
    func serverDetailPresentation() throws {
        let info = GatewayInfo(
            gatewayVersion: "1", piVersion: "2", protocolVersion: 4, minProtocolVersion: 4,
            machineId: "machine", machineName: "Mac", capabilities: ["gateway-update.v1"],
            sourceRevision: "source-revision", runtimeEpoch: "runtime-epoch"
        )
        let status = GatewayUpdateStatus(
            state: "ready", channel: "stable",
            currentIdentity: GatewayUpdateIdentity(
                version: "candidate", gatewayVersion: "1", sourceRevision: "fallback-revision",
                runtimeEpoch: "fallback-epoch", payloadFingerprint: "payload-identity"
            ),
            candidateIdentity: nil, candidateAvailable: false, error: nil, updatedAt: nil
        )
        let details = GatewayConnectionDetailPresentation.technicalDetails(info: info, updateStatus: status)
        #expect(details.map(\.title) == ["Source revision", "Runtime epoch", "Payload identity"])
        #expect(details.map(\.value) == ["source-revision", "runtime-epoch", "payload-identity"])
        #expect(GatewayConnectionDetailPresentation.sourceRepositoryDetail(nil) == "Not configured")

        let config = try GatewayUpdateConfig(
            sourceRoot: "/Users/name/Workspace/tron",
            updatedAt: "2026-01-01T00:00:00Z"
        )
        #expect(GatewayConnectionDetailPresentation.sourceRepositoryDetail(config) == "…/name/Workspace/tron")
    }

    @Test("status presentation is bounded and candidate availability is explicit")
    func statusPresentation() throws {
        let available = GatewayUpdateStatus(
            state: "ready", channel: "stable", currentIdentity: nil,
            candidateIdentity: GatewayUpdateIdentity(version: "2026.01", gatewayVersion: nil, sourceRevision: nil, runtimeEpoch: nil, payloadFingerprint: nil),
            candidateAvailable: true, error: nil, updatedAt: "2026-01-01T00:00:00Z"
        )
        #expect(available.presentationTitle == "Update available")
        let installed = GatewayUpdateStatus(
            state: "ready", channel: "stable", currentIdentity: available.candidateIdentity,
            candidateIdentity: nil, candidateAvailable: false, error: nil, updatedAt: "2026-01-01T00:00:01Z"
        )
        #expect(installed.presentationTitle == "Installed and running")
        #expect(installed.isActive == false)
        let draining = GatewayUpdateStatus(
            state: "draining", channel: "stable", currentIdentity: installed.currentIdentity,
            candidateIdentity: available.candidateIdentity, candidateAvailable: true,
            error: nil, updatedAt: "2026-01-01T00:00:02Z", commandId: "command-draining"
        )
        #expect(draining.isActive)
        #expect(draining.presentationTitle == "Draining")
        let failed = GatewayUpdateStatus(
            state: "failed", channel: "stable", currentIdentity: nil, candidateIdentity: available.candidateIdentity,
            candidateAvailable: true, error: "health check failed", updatedAt: nil,
            commandId: "command-failed", rollbackAvailable: true
        )
        #expect(failed.presentationTitle == "Update failed")
        let rolledBack = GatewayUpdateStatus(
            state: "rolled-back", channel: "stable", currentIdentity: nil, candidateIdentity: available.candidateIdentity,
            candidateAvailable: true, error: "health check failed", updatedAt: nil,
            commandId: "command-failed", rollbackAvailable: true
        )
        #expect(rolledBack.presentationTitle == "Rolled back")
        let unavailable = GatewayUpdateStatus(
            state: "unknown", channel: "stable", currentIdentity: nil, candidateIdentity: nil,
            candidateAvailable: false, error: "unsupported", updatedAt: nil
        )
        #expect(unavailable.presentationTitle == "Unavailable")
        #expect(AppModel.supportsGatewayUpdate(capabilities: ["restart-drain.v1"]) == false)
        #expect(AppModel.supportsGatewayUpdate(capabilities: ["gateway-update.v1"]))
        let legacy = try JSONDecoder.gateway.decode(
            GatewayUpdateStatus.self,
            from: Data(#"{"state":"ready","channel":"stable","currentIdentity":null,"candidateIdentity":null,"candidateAvailable":false,"error":null,"updatedAt":null}"#.utf8)
        )
        #expect(legacy.commandId == nil)
        #expect(legacy.rollbackAvailable == false)
        let fingerprint = String(repeating: "a", count: 64)
        let identity = #"{"version":"debug-1","sourceRevision":"revision-1","runtimeEpoch":"candidate-epoch","payloadFingerprint":"\#(fingerprint)"}"#
        let provenance = #"{"origin":"debug","version":"debug-1","payloadFingerprint":"\#(fingerprint)","sourceRevision":"revision-1","testedRuntimeEpoch":"tested-epoch","candidateRuntimeEpoch":"candidate-epoch"}"#
        let debug = try JSONDecoder.gateway.decode(
            GatewayUpdateStatus.self,
            from: Data(#"{"state":"prepared","channel":"stable","currentIdentity":null,"candidateIdentity":\#(identity),"candidateAvailable":true,"candidateOrigin":"debug","candidateProvenance":\#(provenance),"error":null,"updatedAt":null,"commandId":"debug-command"}"#.utf8)
        )
        #expect(debug.candidateOrigin == "debug")
        #expect(debug.debugPromotionCandidate?.version == "debug-1")
        #expect(debug.debugPromotionCandidate?.sourceRevision == "revision-1")
        #expect(debug.debugPromotionCandidate?.testedRuntimeEpoch == "tested-epoch")
        #expect(debug.debugPromotionCandidate?.candidateRuntimeEpoch == "candidate-epoch")
        #expect(debug.commandId == "debug-command")

        let capableInfo = GatewayInfo(
            gatewayVersion: "1", piVersion: "1", protocolVersion: 4, minProtocolVersion: 4,
            machineId: "machine", machineName: "Mac", capabilities: ["gateway-update.v1"],
            gatewayChannel: "stable"
        )
        let config = try GatewayUpdateConfig(
            sourceRoot: "/Users/name/Workspace/tron",
            updatedAt: "2026-01-01T00:00:00Z"
        )
        let provenDebug = try #require(debug.debugPromotionCandidate)
        #expect(GatewayUpdateIntent.admitted(info: capableInfo, status: debug, config: config) == .debug(provenDebug))
        #expect(GatewayUpdateIntent.admitted(info: capableInfo, status: available, config: nil) == nil)
        #expect(GatewayUpdateIntent.admitted(info: capableInfo, status: available, config: config) == .source)
        #expect(GatewayUpdateIntent.source.actionTitle == "Rebuild Gateway from Source")
        #expect(GatewayUpdateIntent.source.confirmationPresentation.confirmTitle == "Rebuild")
        #expect(GatewayUpdateIntent.source.confirmationPresentation.centersTitle)
        #expect(!GatewayUpdateIntent.debug(provenDebug).confirmationPresentation.centersTitle)
        let unprovenDebug = GatewayUpdateStatus(
            state: "prepared", channel: "stable", currentIdentity: nil,
            candidateIdentity: available.candidateIdentity, candidateAvailable: true,
            error: nil, updatedAt: nil, candidateOrigin: "debug"
        )
        #expect(GatewayUpdateIntent.admitted(info: capableInfo, status: unprovenDebug, config: config) == nil)

        let malformed = [
            #"{"state":"prepared","channel":"stable","candidateIdentity":null,"candidateAvailable":false,"candidateOrigin":"release"}"#,
            #"{"state":"prepared","channel":"dev","candidateIdentity":\#(identity),"candidateAvailable":true,"candidateOrigin":"debug","candidateProvenance":\#(provenance)}"#,
            #"{"state":"prepared","channel":"stable","candidateIdentity":\#(identity),"candidateAvailable":false,"candidateOrigin":"debug","candidateProvenance":\#(provenance)}"#,
            #"{"state":"prepared","channel":"stable","candidateIdentity":\#(identity),"candidateAvailable":true,"candidateOrigin":"debug"}"#,
            #"{"state":"prepared","channel":"stable","candidateIdentity":\#(identity),"candidateAvailable":true,"candidateOrigin":"debug","candidateProvenance":{"origin":"debug","version":"debug-1","payloadFingerprint":"\#(fingerprint)","sourceRevision":"different","testedRuntimeEpoch":"tested-epoch","candidateRuntimeEpoch":"candidate-epoch"}}"#,
            #"{"state":"prepared","channel":"stable","candidateIdentity":\#(identity),"candidateAvailable":true,"candidateOrigin":"debug","candidateProvenance":{"origin":"debug","version":"debug-1","payloadFingerprint":"\#(fingerprint)","sourceRevision":"revision-1","testedRuntimeEpoch":"tested-epoch","candidateRuntimeEpoch":"different-epoch"}}"#,
            #"{"state":"prepared","channel":"stable","candidateIdentity":\#(identity),"candidateAvailable":true,"candidateOrigin":null,"candidateProvenance":\#(provenance)}"#,
        ]
        for value in malformed {
            #expect(throws: GatewayFailure.self) {
                _ = try JSONDecoder.gateway.decode(GatewayUpdateStatus.self, from: Data(value.utf8))
            }
        }
    }

    @Test("drain wire models stay additive and presentation is bounded and private")
    func administrativeDrainWireAndPresentation() throws {
        let blockers = #"{"id":"opaque-private-id","category":"foreground-agent-operation","state":"active","admittedAt":"2026-01-01T00:00:00Z","ageMs":10}"#
        let snapshotJSON = #"{"drainId":"private-drain-id","revision":7,"phase":"waiting","startedAt":"2026-01-01T00:00:00Z","lastProgressAt":"2026-01-01T00:00:01Z","blockerCount":9,"blockerCounts":{"foreground-agent-operation":4,"queued-mutation":2,"detached-extension-run":1,"terminal-receipt-persistence":1,"administrative-provider-package-operation":1},"oldestAdmissionAt":"2026-01-01T00:00:00Z","oldestAdmissionAgeMs":1000,"blockers":[\#(blockers)],"omittedCount":5,"suspectProjectionCount":2}"#
        let snapshot = try JSONDecoder.gateway.decode(AdministrativeDrainSnapshot.self, from: Data(snapshotJSON.utf8))
        let summary = AdministrativeDrainPresentation.summary(snapshot)
        #expect(summary.contains("Waiting for 9 accepted operations"))
        #expect(summary.contains("2 other accepted operations"))
        #expect(summary.contains("5 blocker details omitted"))
        #expect(!summary.contains("opaque-private-id"))
        #expect(!summary.contains("private-drain-id"))
        #expect(!summary.contains("2026-01-01"))
        #expect(AdministrativeDrainPresentation.suspectSummary(snapshot) == "2 nonblocking diagnostic projections")

        let restart = try JSONDecoder.gateway.decode(
            GatewayRestartResponse.self,
            from: Data(#"{"restarting":false,"scheduled":true,"activeSessionIds":["session-private"],"drainId":"private-drain-id","drainRevision":7,"drain":\#(snapshotJSON),"futureField":true}"#.utf8)
        )
        #expect(restart.drain?.revision == 7)
        let legacy = try JSONDecoder.gateway.decode(
            GatewayRestartResponse.self,
            from: Data(#"{"restarting":true,"scheduled":false,"activeSessionIds":[]}"#.utf8)
        )
        #expect(legacy.drain == nil)
    }

    @Test("drain polling policy requires exact local ownership and active presentation")
    func administrativeDrainPollingPolicy() throws {
        let draining = GatewayUpdateStatus(
            state: "draining", channel: "stable", currentIdentity: nil, candidateIdentity: nil,
            candidateAvailable: false, error: nil, updatedAt: nil, commandId: "local-command"
        )
        let updateOwner = AdministrativeDrainPollingOwner.update(commandID: "local-command", drainID: nil)
        #expect(AdministrativeDrainPresentation.shouldPoll(
            owner: updateOwner, profileID: "profile", selectedProfileID: "profile",
            connected: true, sceneActive: true, updateStatus: draining, snapshot: nil
        ))
        for value in [
            AdministrativeDrainPresentation.shouldPoll(owner: nil, profileID: "profile", selectedProfileID: "profile", connected: true, sceneActive: true, updateStatus: draining, snapshot: nil),
            AdministrativeDrainPresentation.shouldPoll(owner: updateOwner, profileID: "profile", selectedProfileID: "other", connected: true, sceneActive: true, updateStatus: draining, snapshot: nil),
            AdministrativeDrainPresentation.shouldPoll(owner: updateOwner, profileID: "profile", selectedProfileID: "profile", connected: false, sceneActive: true, updateStatus: draining, snapshot: nil),
            AdministrativeDrainPresentation.shouldPoll(owner: updateOwner, profileID: "profile", selectedProfileID: "profile", connected: true, sceneActive: false, updateStatus: draining, snapshot: nil),
            AdministrativeDrainPresentation.shouldPoll(owner: updateOwner, profileID: "profile", selectedProfileID: "profile", connected: true, sceneActive: true, updateStatus: GatewayUpdateStatus(state: "draining", channel: "stable", currentIdentity: nil, candidateIdentity: nil, candidateAvailable: false, error: nil, updatedAt: nil, commandId: "adopted-command"), snapshot: nil),
        ] { #expect(!value) }

        let complete = try JSONDecoder.gateway.decode(
            AdministrativeDrainSnapshot.self,
            from: Data(#"{"drainId":"completed-drain","revision":2,"phase":"complete","blockerCount":0,"blockerCounts":{},"blockers":[],"omittedCount":0,"suspectProjectionCount":0}"#.utf8)
        )
        let restartOwner = AdministrativeDrainPollingOwner.restart(drainID: "completed-drain")
        #expect(!AdministrativeDrainPresentation.shouldPoll(owner: restartOwner, profileID: "profile", selectedProfileID: "profile", connected: true, sceneActive: true, updateStatus: nil, snapshot: complete))
        #expect(AdministrativeDrainPresentation.summary(AdministrativeDrainSnapshot(
            drainId: "failed-drain", revision: 3, phase: .failed, blockerCount: 1,
            blockerCounts: [:], omittedCount: 0, suspectProjectionCount: 0
        )) == "Restart drain failed. Tron is still connected.")
        #expect(AdministrativeDrainPresentation.admits(complete, for: restartOwner))
        #expect(!AdministrativeDrainPresentation.admits(complete, for: .restart(drainID: "replacement-id")))
    }

    @Test("drain RPC uses empty params and a scheduled restart waits for system stopping")
    func administrativeDrainRPCAndScheduledRestartLifecycle() async throws {
        let suiteName = "GatewayDrainControlTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cacheRoot = FileManager.default.temporaryDirectory.appending(path: suiteName, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let profile = GatewayProfile(id: "stable", label: "Stable", host: "gateway.test", port: 9_847, machineId: "machine", deviceId: "device")
        defaults.set(try JSONEncoder.gateway.encode([profile]), forKey: "gatewayProfiles.v1")
        defaults.set(profile.id, forKey: "selectedGateway.v1")
        let socket = ScriptedGatewaySocket()
        let replacementSocket = ScriptedGatewaySocket()
        let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(sockets: [socket, replacementSocket]).factory)
        let clock = ManualClock()
        let model = AppModel(client: client, profiles: GatewayProfileStore(defaults: defaults), cache: SnapshotCache(root: cacheRoot), clock: clock.clock)
        let capabilities = ["gateway-update.v1", "restart-drain.v1", "restart-supervised.v1", "drain-status.v1"]
        let connecting = Task { try await model.connectHostedGateway(profile: profile, token: "token") }
        try await socket.waitUntilSent(count: 1)
        await socket.enqueue(helloFrame(machineID: "machine", capabilities: capabilities))
        try await connecting.value

        let reading = Task { try await model.loadAdministrativeDrainStatus(for: profile) }
        try await socket.waitUntilSent(count: 2)
        let drainRequest = try requestFrame(await socket.sentFrames()[1])
        #expect(drainRequest.method == "gateway.drain.status")
        #expect(drainRequest.params == [:])
        let snapshot: JSONValue = .object([
            "drainId": .string("drain-one"), "revision": .number(1), "phase": .string("waiting"),
            "blockerCount": .number(1), "blockerCounts": .object(["foreground-agent-operation": .number(1)]),
            "blockers": .array([]), "omittedCount": .number(1), "suspectProjectionCount": .number(0),
        ])
        await socket.enqueue(successResponse(id: drainRequest.id, result: snapshot))
        #expect(try await reading.value?.drainId == "drain-one")

        let restarting = Task { await model.requestGatewayRestart(for: profile) }
        try await socket.waitUntilSent(count: 3)
        let restartRequest = try requestFrame(await socket.sentFrames()[2])
        #expect(restartRequest.method == "gateway.restart")
        await socket.enqueue(successResponse(id: restartRequest.id, result: .object([
            "restarting": .bool(false), "scheduled": .bool(true), "activeSessionIds": .array([]),
            "drainId": .string("drain-one"), "drainRevision": .number(1), "drain": snapshot,
        ])))
        #expect(await restarting.value?.scheduled == true)
        #expect(model.connectionState == .connected)
        clock.advance(by: .seconds(91))
        await Task.yield()
        #expect(model.connectionState == .connected)

        await model.handle(GatewayEvent(type: "event", topic: "system.stopping", sessionId: nil, payload: .object([:])))
        #expect(model.connectionState == .restarting)
        await model.teardown()
        await client.close()
    }

    @Test("artifact promotion sends exact tested identity and rejects non-focused targets")
    func artifactPromotionWireAndAdmission() async throws {
        let suiteName = "GatewayUpdateControlPlaneTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cacheRoot = FileManager.default.temporaryDirectory.appending(path: suiteName, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let stable = GatewayProfile(
            id: "stable", label: "Stable", host: "gateway.test", port: 9_847,
            machineId: "stable-machine", deviceId: "stable-device"
        )
        let debug = GatewayProfile(
            id: "debug", label: "Debug", host: "gateway.test", port: 9_848,
            machineId: "debug-machine", deviceId: "debug-device"
        )
        defaults.set(try JSONEncoder.gateway.encode([stable, debug]), forKey: "gatewayProfiles.v1")
        defaults.set(stable.id, forKey: "selectedGateway.v1")
        let profiles = GatewayProfileStore(defaults: defaults)
        let socket = ScriptedGatewaySocket()
        let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory)
        let model = AppModel(client: client, profiles: profiles, cache: SnapshotCache(root: cacheRoot))

        let connecting = Task { try await model.connectHostedGateway(profile: stable, token: "stable-token") }
        try await socket.waitUntilSent(count: 1)
        await socket.enqueue(helloFrame(machineID: "stable-machine"))
        try await connecting.value

        let candidate = try debugCandidate(fingerprint: String(repeating: "b", count: 64))
        #expect(await model.requestGatewayUpdate(
            for: debug,
            mode: "artifact",
            debugCandidate: candidate
        ) == nil)
        #expect((await socket.sentFrames()).count == 1)

        let updating = Task {
            await model.requestGatewayUpdate(
                for: stable,
                mode: "artifact",
                debugCandidate: candidate
            )
        }
        try await socket.waitUntilSent(count: 2)
        let request = try requestFrame(await socket.sentFrames()[1])
        #expect(request.method == "gateway.update")
        #expect(request.params?["channel"] == .string("stable"))
        #expect(request.params?["mode"] == .string("artifact"))
        #expect(request.params?["candidateVersion"] == .string("debug-tested"))
        #expect(request.params?["candidateFingerprint"] == .string(String(repeating: "b", count: 64)))
        let commandID = try #require(request.params?["commandId"]?.stringValue)
        await socket.enqueue(successResponse(id: request.id, result: .object(["accepted": .bool(true), "commandId": .string(commandID)])))
        #expect(await updating.value == commandID)

        let rejected = Task { await model.requestGatewayRollback(for: stable) }
        try await socket.waitUntilSent(count: 3)
        let rejectedRequest = try requestFrame(await socket.sentFrames()[2])
        #expect(rejectedRequest.method == "gateway.rollback")
        await socket.enqueue(successResponse(
            id: rejectedRequest.id,
            result: .object(["accepted": .bool(false), "commandId": rejectedRequest.params?["commandId"] ?? .null])
        ))
        #expect(await rejected.value == nil)

        let mismatched = Task { await model.requestGatewayRollback(for: stable) }
        try await socket.waitUntilSent(count: 4)
        let mismatchedRequest = try requestFrame(await socket.sentFrames()[3])
        await socket.enqueue(successResponse(
            id: mismatchedRequest.id,
            result: .object(["accepted": .bool(true), "commandId": .string("different-command")])
        ))
        #expect(await mismatched.value == nil)

        let malformed = Task { await model.requestGatewayRollback(for: stable) }
        try await socket.waitUntilSent(count: 5)
        let malformedRequest = try requestFrame(await socket.sentFrames()[4])
        await socket.enqueue(successResponse(id: malformedRequest.id, result: .object(["commandId": .string("missing-accepted")])) )
        #expect(await malformed.value == nil)

        let sentCount = (await socket.sentFrames()).count
        #expect(await model.requestGatewayUpdate(
            for: stable,
            mode: "artifact",
            debugCandidate: nil
        ) == nil)
        #expect((await socket.sentFrames()).count == sentCount)
        #expect(await model.requestGatewayUpdate(for: stable, mode: "auto") == nil)
        #expect((await socket.sentFrames()).count == sentCount)

        let sourceUpdate = Task { await model.requestGatewayUpdate(for: stable) }
        try await socket.waitUntilSent(count: sentCount + 1)
        let sourceRequest = try requestFrame(await socket.sentFrames()[sentCount])
        #expect(sourceRequest.method == "gateway.update")
        #expect(sourceRequest.params?["mode"] == .string("source"))
        #expect(sourceRequest.params?["candidateVersion"] == nil)
        #expect(sourceRequest.params?["candidateFingerprint"] == nil)
        let sourceCommandID = try #require(sourceRequest.params?["commandId"]?.stringValue)
        await socket.enqueue(successResponse(
            id: sourceRequest.id,
            result: .object(["accepted": .bool(true), "commandId": .string(sourceCommandID)])
        ))
        #expect(await sourceUpdate.value == sourceCommandID)

        await model.teardown()
        await client.close()
    }

    @Test("receipt resolution validates typed update acknowledgements after completed and missing outcomes")
    func receiptAcknowledgementAdmission() async throws {
        let suiteName = "GatewayUpdateReceiptTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cacheRoot = FileManager.default.temporaryDirectory.appending(path: suiteName, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let stable = GatewayProfile(
            id: "stable", label: "Stable", host: "gateway.test", port: 9_847,
            machineId: "stable-machine", deviceId: "stable-device"
        )
        defaults.set(try JSONEncoder.gateway.encode([stable]), forKey: "gatewayProfiles.v1")
        defaults.set(stable.id, forKey: "selectedGateway.v1")
        let profiles = GatewayProfileStore(defaults: defaults)
        let socket = ScriptedGatewaySocket()
        let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory)
        let commandIDs = [
            UUID(uuidString: "00000000-0000-0000-0000-000000000201")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000202")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000203")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000204")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000205")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000206")!,
        ]
        let model = AppModel(
            client: client,
            profiles: profiles,
            cache: SnapshotCache(root: cacheRoot),
            uuidSource: SequenceUUIDSource(commandIDs).source
        )
        let connecting = Task { try await model.connectHostedGateway(profile: stable, token: "stable-token") }
        try await socket.waitUntilSent(count: 1)
        await socket.enqueue(helloFrame(machineID: "stable-machine"))
        try await connecting.value

        let candidate = try debugCandidate(fingerprint: String(repeating: "c", count: 64))
        await socket.failNextSend(GatewayFailure(code: "disconnected", message: "synthetic", retryable: true, details: nil))
        let completed = Task {
            await model.requestGatewayUpdate(
                for: stable,
                mode: "artifact",
                debugCandidate: candidate
            )
        }
        try await socket.waitUntilSent(count: 2)
        let completedStatus = try requestFrame(await socket.sentFrames()[1])
        #expect(completedStatus.method == "command.status")
        let completedID = try #require(completedStatus.params?["commandId"]?.stringValue)
        await socket.enqueue(successResponse(
            id: completedStatus.id,
            result: .object([
                "status": .string("completed"),
                "result": .object(["accepted": .bool(true), "commandId": .string(completedID)]),
            ])
        ))
        #expect(await completed.value == completedID)

        await socket.failNextSend(GatewayFailure(code: "disconnected", message: "synthetic", retryable: true, details: nil))
        let missing = Task { await model.requestGatewayRollback(for: stable) }
        try await socket.waitUntilSent(count: 3)
        let missingStatus = try requestFrame(await socket.sentFrames()[2])
        #expect(missingStatus.method == "command.status")
        let missingID = try #require(missingStatus.params?["commandId"]?.stringValue)
        await socket.enqueue(successResponse(id: missingStatus.id, result: .object(["status": .string("missing")])))
        try await socket.waitUntilSent(count: 4)
        let replay = try requestFrame(await socket.sentFrames()[3])
        #expect(replay.method == "gateway.rollback")
        #expect(replay.params?["commandId"] == .string(missingID))
        await socket.enqueue(successResponse(
            id: replay.id,
            result: .object(["accepted": .bool(true), "commandId": .string(missingID)])
        ))
        #expect(await missing.value == missingID)

        await socket.failNextSend(GatewayFailure(code: "disconnected", message: "synthetic", retryable: true, details: nil))
        let mismatched = Task { await model.requestGatewayRollback(for: stable) }
        try await socket.waitUntilSent(count: 5)
        let mismatchedStatus = try requestFrame(await socket.sentFrames()[4])
        await socket.enqueue(successResponse(
            id: mismatchedStatus.id,
            result: .object([
                "status": .string("completed"),
                "result": .object(["accepted": .bool(true), "commandId": .string("different-command")]),
            ])
        ))
        #expect(await mismatched.value == nil)

        await model.teardown()
        await client.close()
    }

    private func debugCandidate(fingerprint: String) throws -> GatewayDebugPromotionCandidate {
        let data = Data(#"{"state":"prepared","channel":"stable","currentIdentity":null,"candidateIdentity":{"version":"debug-tested","sourceRevision":"revision-1","runtimeEpoch":"candidate-epoch","payloadFingerprint":"\#(fingerprint)"},"candidateAvailable":true,"candidateOrigin":"debug","candidateProvenance":{"origin":"debug","version":"debug-tested","payloadFingerprint":"\#(fingerprint)","sourceRevision":"revision-1","testedRuntimeEpoch":"tested-epoch","candidateRuntimeEpoch":"candidate-epoch"},"error":null,"updatedAt":null}"#.utf8)
        return try #require(JSONDecoder.gateway.decode(GatewayUpdateStatus.self, from: data).debugPromotionCandidate)
    }

    private func helloFrame(machineID: String, capabilities: [String] = ["gateway-update.v1"]) -> Data {
        try! JSONEncoder.gateway.encode(JSONValue.object([
            "type": .string("hello"),
            "gatewayVersion": .string("1.0.0"),
            "piVersion": .string("1.0.0"),
            "protocolVersion": .number(4),
            "minProtocolVersion": .number(4),
            "machineId": .string(machineID),
            "machineName": .string("Mac"),
            "gatewayChannel": .string("stable"),
            "capabilities": .array(capabilities.map(JSONValue.string)),
        ]))
    }

    private func requestFrame(_ data: Data) throws -> (id: String, method: String, params: [String: JSONValue]?) {
        let value = try JSONDecoder.gateway.decode(JSONValue.self, from: data)
        return (
            try #require(value.objectValue?["id"]?.stringValue),
            try #require(value.objectValue?["method"]?.stringValue),
            value.objectValue?["params"]?.objectValue
        )
    }

    private func successResponse(id: String, result: JSONValue) -> Data {
        try! JSONEncoder.gateway.encode(JSONValue.object([
            "type": .string("response"), "id": .string(id), "ok": .bool(true), "result": result,
        ]))
    }
}
