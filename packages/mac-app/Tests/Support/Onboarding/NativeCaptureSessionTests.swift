import Foundation
import Testing
import TronComputerControl
@testable import TronNativeCaptureHost

@Suite("Native capture host boundary (offline)")
struct NativeCaptureSessionTests {
    @Test func wireRejectsUnboundedAndRawTargetAuthority() throws {
        let hello = CaptureWireFixture()
        #expect(throws: (any Error).self) { try NativeCaptureRequest.decode(Data(repeating: 32, count: 65_537)) }
        #expect(throws: (any Error).self) { try hello.request("hello", extra: ["pid": 42]) }
        #expect(throws: (any Error).self) { try hello.request("start", extra: ["windowID": 42]) }
        #expect(throws: (any Error).self) { try hello.request("pull", extra: ["generation": UUID().uuidString, "readSequence": 0]) }
        #expect(throws: (any Error).self) { try hello.request("input") }
    }

    @Test func rejectedPeerCannotReachCatalogOrNativeCreation() async throws {
        let backend = CaptureBackend()
        await backend.reject()
        let owner = makeOwner(backend)
        let wire = CaptureWireFixture()
        let result = await owner.execute(try wire.request("hello"))
        #expect(status(result) == "unauthorized")
        #expect(await backend.nativeCalls == 0)
        #expect(await owner.drain().joined)
    }

    @Test func exactConnectionSessionBootAndLoadFencePrecedeNativeSeam() async throws {
        let backend = CaptureBackend()
        let owner = makeOwner(backend)
        let wire = try await handshake(owner)
        for field in ["bootID", "connectionID", "sessionID", "loadID"] {
            var stale = wire
            stale.fields[field] = UUID().uuidString
            #expect(status(await owner.execute(try stale.request("catalog"))) == "stale")
        }
        #expect(await backend.nativeCalls == 0)
        #expect(await owner.drain().joined)
    }

    @Test func servicePreservesFiniteCaptureFailureWithoutPublishingPixels() async throws {
        for failure in [NativeWindowCaptureError.permissionUnavailable, .sourceUnavailable] {
            for stage in ["start", "pull"] {
                let backend = CaptureBackend(), owner = makeOwner(backend)
                let wire = try await handshake(owner), selected = try handle(await owner.execute(try wire.request("catalog")))
                backend.producer.startRelease.signal(); backend.producer.joinRelease.signal()
                if stage == "start" { backend.producer.failStart(failure) }
                else {
                    _ = await owner.execute(try wire.request("start", extra: ["handle": selected]))
                    backend.producer.failPull(failure)
                }
                let response = CaptureTestResponse(), service = NativeCaptureService(session: owner)
                let fields: [String: Any] = stage == "start" ? ["handle": selected] : ["generation": backend.producer.generation.uuidString, "readSequence": 1]
                service.executeCaptureRequest(try wire.data(stage, extra: fields)) { response.resolve(.init(control: $0, jpeg: $1)) }
                let value = await response.value()
                #expect(status(value) == String(describing: failure))
                #expect(value.jpeg == nil && !owner.fence.admits())
                #expect(await owner.drain().joined)
            }
        }
    }

    @Test func serviceRevocationStillFencesAPendingCaptureFailure() async throws {
        let backend = CaptureBackend(), owner = makeOwner(backend)
        let wire = try await handshake(owner), selected = try handle(await owner.execute(try wire.request("catalog")))
        backend.producer.failStart(.sourceUnavailable); backend.producer.startRelease.signal()
        let response = CaptureTestResponse(), service = NativeCaptureService(session: owner)
        service.executeCaptureRequest(try wire.data("start", extra: ["handle": selected])) { response.resolve(.init(control: $0, jpeg: $1)) }
        await backend.producer.joinEntered.wait()
        owner.fence.close(); backend.producer.joinRelease.signal()
        let value = await response.value()
        #expect(status(value) == "stale" && value.jpeg == nil)
        #expect(await owner.drain().joined)
    }

    @Test func provenanceLossAcrossCatalogAwaitDiscardsAllHandles() async throws {
        let backend = CaptureBackend(holdCatalog: true)
        let owner = makeOwner(backend)
        let wire = try await handshake(owner)
        let request = try wire.request("catalog")
        let work = Task { await owner.execute(request) }
        await backend.catalogEntered.wait()
        await backend.reject()
        backend.catalogRelease.signal()
        #expect(status(await work.value) == "stale")
        #expect(await backend.nativeCalls == 1)
        #expect(await owner.drain().joined)
    }

    @Test func duplicateCatalogJoinsAndChangedPayloadRejects() async throws {
        let backend = CaptureBackend(holdCatalog: true)
        let owner = makeOwner(backend)
        let wire = try await handshake(owner)
        let request = try wire.request("catalog")
        let first = Task { await owner.execute(request) }
        await backend.catalogEntered.wait()
        let duplicate = Task { await owner.execute(request) }
        let changed = try wire.request("start", command: try #require(request.commandID), extra: ["handle": UUID().uuidString])
        #expect(status(await owner.execute(changed)) == "invalidRequest")
        backend.catalogRelease.signal()
        let a = await first.value, b = await duplicate.value
        #expect(a.control == b.control)
        #expect(await backend.nativeCalls == 1)
        #expect(await owner.drain().joined)
    }

    @Test func disconnectDuringStartRetainsGlobalCapacityUntilRealJoin() async throws {
        let backend = CaptureBackend()
        let slot = NativeCaptureSlot()
        let fence = NativeCaptureFence { true }
        let (id, owner) = try #require(slot.attach(fence: fence, operations: backend.operations))
        let (otherID, _) = try #require(slot.attach(fence: NativeCaptureFence { true }, operations: backend.operations))
        let wire = try await handshake(owner)
        let catalog = await owner.execute(try wire.request("catalog"))
        let source = try handle(catalog)
        let start = Task { await owner.execute(try wire.request("start", extra: ["handle": source])) }
        await backend.producer.startEntered.wait()
        slot.peerLost(id)
        #expect(!fence.admits())
        #expect(!slot.reserveStream(otherID))
        #expect(backend.producer.stopRequested)
        backend.producer.startRelease.signal()
        await backend.producer.joinEntered.wait()
        #expect(!slot.reserveStream(otherID))
        backend.producer.joinRelease.signal()
        #expect(status(try await start.value) == "stale", "Lost peer authority must not be reported as source availability")
        #expect(await owner.drain().joined)
        // Explicit service drain permanently closes admission, even after join.
        #expect(await slot.drainForServiceRetirement())
        #expect(slot.attach(fence: NativeCaptureFence { true }, operations: backend.operations) == nil)
    }

    @Test func stopDuringCatalogJoinsAcceptedSelectionWithoutStarting() async throws {
        let backend = CaptureBackend(holdCatalog: true)
        let owner = makeOwner(backend)
        let wire = try await handshake(owner)
        let catalog = Task { await owner.execute(try wire.request("catalog")) }
        await backend.catalogEntered.wait()
        owner.fence.close() // synchronous connection invalidation boundary
        let stop = Task { await owner.execute(try wire.request("stop")) }
        backend.catalogRelease.signal()
        #expect(status(try await catalog.value) == "stale")
        #expect(status(try await stop.value) == "joined")
        #expect(!backend.producer.stopRequested, "No producer should have been constructed")
    }

    @Test func failedNativeRetirementNeverFreesSlotOrPermitsServiceRetirement() async throws {
        let backend = CaptureBackend(joined: false)
        let slot = NativeCaptureSlot()
        let (_, owner) = try #require(slot.attach(fence: NativeCaptureFence { true }, operations: backend.operations))
        let successorBackend = CaptureBackend()
        let (_, successor) = try #require(slot.attach(fence: NativeCaptureFence { true }, operations: successorBackend.operations))
        let wire = try await handshake(owner), next = try await handshake(successor)
        let source = try handle(await owner.execute(try wire.request("catalog")))
        let successorSource = try handle(await successor.execute(try next.request("catalog")))
        backend.producer.startRelease.signal()
        #expect(status(await owner.execute(try wire.request("start", extra: ["handle": source]))) == "started")
        backend.producer.joinRelease.signal()
        #expect(status(await owner.execute(try wire.request("stop"))) == "retirementFailed")
        // Test capacity BEFORE service-wide closure could trivially deny everyone.
        #expect(status(await successor.execute(try next.request("start", extra: ["handle": successorSource]))) == "busy")
        #expect(!(await slot.drainForServiceRetirement()))
        #expect(slot.attach(fence: NativeCaptureFence { true }, operations: backend.operations) == nil)
    }

    @Test func frameReadsHaveNoControlCommandIdentity() throws {
        let wire = CaptureWireFixture(fields: ["bootID": UUID().uuidString,
            "connectionID": UUID().uuidString, "sessionID": UUID().uuidString, "loadID": UUID().uuidString])
        let fields: [String: Any] = ["generation": UUID().uuidString, "readSequence": 1]
        let read = try wire.request("pull", extra: fields)
        #expect(read.commandID == nil)
        var forged = fields
        forged["commandID"] = UUID().uuidString
        #expect(throws: (any Error).self) { try wire.request("pull", extra: forged) }
        #expect(throws: (any Error).self) { try wire.request("stop", extra: ["readSequence": 1]) }
    }

    @Test func foreignGenerationAndRepeatedReadCannotConsumeFrame() async throws {
        let backend = CaptureBackend()
        let owner = makeOwner(backend)
        let wire = try await handshake(owner)
        let source = try handle(await owner.execute(try wire.request("catalog")))
        backend.producer.startRelease.signal()
        _ = await owner.execute(try wire.request("start", extra: ["handle": source]))
        #expect(status(await owner.execute(try wire.request("pull", extra: ["generation": UUID().uuidString, "readSequence": 1]))) == "stale")
        #expect(backend.producer.pulls == 0)
        let pull = try wire.request("pull", extra: ["generation": backend.producer.generation.uuidString, "readSequence": 2])
        #expect(status(await owner.execute(pull)) == "empty")
        #expect(status(await owner.execute(pull)) == "stale")
        #expect(backend.producer.pulls == 1)
        backend.producer.joinRelease.signal()
        #expect(await owner.drain().joined)
    }

    @Test func frameEnvelopePreservesBytesAndFencesForeignOrRetiredOutput() async throws {
        for scenario in ["valid", "foreign", "oversized", "retired"] {
            let backend = CaptureBackend()
            let owner = makeOwner(backend)
            let wire = try await handshake(owner)
            let source = try handle(await owner.execute(try wire.request("catalog")))
            backend.producer.startRelease.signal(); backend.producer.joinRelease.signal()
            _ = await owner.execute(try wire.request("start", extra: ["handle": source]))
            // Opaque fixture bytes test transport, not JPEG/native pixel fidelity.
            let bytes = Data([1, 2, 3, 4])
            let frame = NativeCaptureHostFrame(generation: scenario == "foreign" ? UUID() : backend.producer.generation,
                sequence: 5, jpeg: bytes, width: scenario == "oversized" ? 1281 : 16, height: 16)
            let afterTake: (@Sendable () -> Void)?
            if scenario == "retired" { afterTake = { owner.fence.close() } } else { afterTake = nil }
            backend.producer.offer(frame, afterTake: afterTake)
            let service = NativeCaptureService(session: owner), response = CaptureTestResponse()
            service.executeCaptureRequest(try wire.data("pull", extra: [
                "generation": backend.producer.generation.uuidString, "readSequence": 1
            ])) { control, jpeg in response.resolve(.init(control: control, jpeg: jpeg)) }
            let result = await response.value()
            if scenario == "valid" {
                #expect(status(result) == "frame")
                #expect(result.jpeg == bytes)
                let fields = try #require(JSONSerialization.jsonObject(with: result.control) as? [String: Any])
                #expect(fields["commandID"] == nil)
                #expect(fields["readSequence"] as? Int == 1)
                #expect(fields["sequence"] as? String == "5")
            } else {
                #expect(status(result) != "frame")
                #expect(result.jpeg == nil)
                #expect(backend.producer.stopRequested)
            }
            #expect(await owner.drain().joined)
        }
    }

    @Test func boundedTextCountsBytesNotCombiningGraphemes() {
        let combining = "a" + String(repeating: "\u{0301}", count: 50_000)
        #expect(combining.count == 1)
        #expect(NativeCaptureText.bounded(combining).utf8.count <= 256)
        #expect(NativeCaptureText.bounded(String(repeating: "😀", count: 200)).utf8.count <= 256)
    }

    @Test func inertCatalogDoesNotOwnStreamAndJoinedDiagnosticReleasesCapacity() async throws {
        let backend = CaptureBackend(diagnostic: "stopFailed")
        let slot = NativeCaptureSlot()
        let (_, first) = try #require(slot.attach(fence: NativeCaptureFence { true }, operations: backend.operations))
        let (_, second) = try #require(slot.attach(fence: NativeCaptureFence { true }, operations: backend.operations))
        let a = try await handshake(first), b = try await handshake(second)
        let ah = try handle(await first.execute(try a.request("catalog")))
        let bh = try handle(await second.execute(try b.request("catalog")))
        backend.producer.startRelease.signal()
        #expect(status(await first.execute(try a.request("start", extra: ["handle": ah]))) == "started")
        #expect(status(await second.execute(try b.request("start", extra: ["handle": bh]))) == "busy")
        backend.producer.joinRelease.signal()
        let stopped = await first.execute(try a.request("stop"))
        #expect(status(stopped) == "joined")
        #expect(String(decoding: stopped.control, as: UTF8.self).contains("stopFailed"))
        #expect(status(await second.execute(try b.request("start", extra: ["handle": bh]))) == "started")
        #expect(await second.drain().joined)
    }

    @Test func demandExpiryRequestsStopButDoesNotFreeUnjoinedStream() async throws {
        let clock = CaptureTestClock()
        let backend = CaptureBackend(clock: clock)
        let slot = NativeCaptureSlot()
        let (_, owner) = try #require(slot.attach(fence: NativeCaptureFence { true }, operations: backend.operations))
        let (_, other) = try #require(slot.attach(fence: NativeCaptureFence { true }, operations: backend.operations))
        let wire = try await handshake(owner), next = try await handshake(other)
        let source = try handle(await owner.execute(try wire.request("catalog")))
        let otherSource = try handle(await other.execute(try next.request("catalog")))
        let work = Task { await owner.execute(try wire.request("start", extra: ["handle": source])) }
        await backend.producer.startEntered.wait(); await clock.entered.wait()
        clock.fire.signal()
        await backend.producer.stopEntered.wait()
        #expect(status(await other.execute(try next.request("start", extra: ["handle": otherSource]))) == "busy")
        backend.producer.startRelease.signal(); backend.producer.joinRelease.signal()
        _ = try await work.value
        #expect(await owner.drain().joined)
        #expect(await other.drain().joined)
    }

    @Test func stopHasAdmissionIndependentOfEightBlockedReplyWaiters() async throws {
        let backend = CaptureBackend()
        let owner = makeOwner(backend)
        let wire = try await handshake(owner)
        let source = try handle(await owner.execute(try wire.request("catalog")))
        let service = NativeCaptureService(session: owner)
        let data = try wire.data("start", extra: ["handle": source])
        for _ in 0..<8 { service.executeCaptureRequest(data) { _, _ in } }
        await backend.producer.startEntered.wait()
        let stopped = CaptureTestResponse()
        service.executeCaptureRequest(try wire.data("stop")) { control, jpeg in stopped.resolve(.init(control: control, jpeg: jpeg)) }
        await backend.producer.stopEntered.wait()
        backend.producer.startRelease.signal(); backend.producer.joinRelease.signal()
        #expect(status(await stopped.value()) == "joined")
    }

    @Test func handshakeAndConnectionBoundsAreDistinctFromStreamCapacity() throws {
        let slot = NativeCaptureSlot(), backend = CaptureBackend()
        let pending = try (0..<4).map { _ in try #require(slot.beginHandshake(NativeCaptureHandshake())) }
        #expect(slot.beginHandshake(NativeCaptureHandshake()) == nil)
        slot.abandonHandshake(pending[0])
        #expect(slot.beginHandshake(NativeCaptureHandshake()) != nil)
        #expect(!slot.reserveStream(pending[1]), "Unauthenticated handshake has no session or native reservation")
        let session = slot.finishHandshake(pending[1], fence: NativeCaptureFence { true }, operations: backend.operations)
        #expect(session != nil)
        #expect(slot.reserveStream(pending[1]))
        slot.releaseStream(pending[1])
    }

    @Test func serviceRetirementJoinsCancelledPeerValidation() async throws {
        let slot = NativeCaptureSlot(), handshake = NativeCaptureHandshake()
        let id = try #require(slot.beginHandshake(handshake))
        let entered = CaptureTestLatch(), cancelled = CaptureTestLatch(), release = CaptureTestLatch(), finished = CaptureTestLatch()
        handshake.install(Task {
            await withTaskCancellationHandler {
                entered.signal(); await release.wait()
            } onCancel: { cancelled.signal() }
            slot.abandonHandshake(id)
        })
        await entered.wait()
        let retirement = Task { let joined = await slot.drainForServiceRetirement(); finished.signal(); return joined }
        await cancelled.wait()
        #expect(!finished.isReady)
        #expect(slot.finishHandshake(id, fence: NativeCaptureFence { true }, operations: CaptureBackend().operations) == nil)
        release.signal()
        #expect(await retirement.value)
    }

    @Test func retiredHandshakeJoinsALateInstalledTask() async {
        let handshake = NativeCaptureHandshake(), cancelled = CaptureTestLatch(), release = CaptureTestLatch(), finished = CaptureTestLatch()
        handshake.retire()
        let joined = Task { await handshake.join(); finished.signal() }
        handshake.install(Task {
            await withTaskCancellationHandler { await release.wait() } onCancel: { cancelled.signal() }
        })
        await cancelled.wait(); #expect(!finished.isReady)
        release.signal(); await joined.value; #expect(finished.isReady)
    }

    @Test func admittedHandshakeCannotBeInvalidatedByAnAlreadyWokenDeadline() {
        let handshake = NativeCaptureHandshake()
        var activations = 0
        #expect(handshake.activate { activations += 1 })
        #expect(!handshake.expire())
        #expect(!handshake.activate { activations += 1 })
        #expect(activations == 1)
        handshake.retire()
        #expect(!handshake.activate { activations += 1 })
    }

    @Test func expiredHandshakeCannotActivateAfterValidationReturns() async {
        let handshake = NativeCaptureHandshake()
        let gate = CaptureTestLatch(), returned = CaptureTestResponse()
        let validation = Task {
            await gate.wait()
            let activated = handshake.activate { }
            returned.resolve(.error(activated ? .unavailable : .stale))
        }
        handshake.install(validation)
        #expect(handshake.expire())
        #expect(validation.isCancelled)
        gate.signal()
        await validation.value
        #expect(status(await returned.value()) == "stale")
    }

    @Test func cleanSuspensionKeepsOnlyTheExactTargetAndCreatesAFreshStream() async throws {
        let first = CaptureTestProducer(joined: true), second = CaptureTestProducer(joined: true)
        first.startRelease.signal(); second.startRelease.signal(); second.joinRelease.signal()
        let sequence = CaptureProducerSequence([first, second])
        let operations = NativeCaptureOperations(validate: { true }, catalog: { _ in
            sequence.catalogued()
            return [NativeCaptureTarget(kind: .window, applicationName: "Fixture", title: "Selected", width: 1000, height: 800, make: { _, _ in sequence.make() }),
                    NativeCaptureTarget(kind: .window, applicationName: "Fixture", title: "Other", width: 1000, height: 800, make: { _, _ in sequence.make() })]
        }, automationEndpoint: { nil })
        let slot = NativeCaptureSlot()
        let (_, owner) = try #require(slot.attach(fence: NativeCaptureFence { true }, operations: operations))
        let (other, _) = try #require(slot.attach(fence: NativeCaptureFence { true }, operations: operations))
        let wire = try await handshake(owner), catalog = await owner.execute(try wire.request("catalog"))
        let selected = try handle(catalog)
        let object = try #require(JSONSerialization.jsonObject(with: catalog.control) as? [String: Any])
        let entries = try #require(object["sources"] as? [[String: Any]])
        let initial = await owner.execute(try wire.request("start", extra: ["handle": selected]))
        #expect(status(initial) == "started")
        let suspension = Task { await owner.execute(try wire.request("suspend")) }
        await first.stopEntered.wait(); await first.joinEntered.wait()
        #expect(!slot.reserveStream(other))
        #expect(status(await owner.execute(try wire.request("start", extra: ["handle": selected]))) == "stale")
        first.joinRelease.signal()
        #expect(status(try await suspension.value) == "joined")
        #expect(slot.reserveStream(other)); slot.releaseStream(other)
        #expect(status(await owner.execute(try wire.request("start", extra: ["handle": try #require(entries[1]["handle"])]))) == "stale")
        let resumed = await owner.execute(try wire.request("start", extra: ["handle": selected]))
        #expect(status(resumed) == "started")
        let resumedObject = try #require(JSONSerialization.jsonObject(with: resumed.control) as? [String: Any])
        #expect(resumedObject["generation"] as? String == second.generation.uuidString)
        #expect(first.generation != second.generation)
        #expect(sequence.catalogs == 1 && sequence.makes == 2)
        #expect(await owner.drain().joined)
    }

    @Test func displayCropIsBoundedAndCannotChangeWhenResumed() async throws {
        let first = CaptureTestProducer(joined: true), second = CaptureTestProducer(joined: true)
        first.startRelease.signal(); first.joinRelease.signal()
        second.startRelease.signal(); second.joinRelease.signal()
        let sequence = CaptureProducerSequence([first, second])
        let crop = NativeCaptureRegion(x: 10, y: 20, width: 30, height: 40)
        let operations = NativeCaptureOperations(validate: { true }, catalog: { _ in
            [NativeCaptureTarget(kind: .display, applicationName: "Mac", title: "Display", width: 100, height: 100, make: { region, _ in
                #expect(region == crop)
                return sequence.make()
            })]
        }, automationEndpoint: { nil })
        let slot = NativeCaptureSlot()
        let (_, owner) = try #require(slot.attach(fence: NativeCaptureFence { true }, operations: operations))
        let wire = try await handshake(owner), catalog = await owner.execute(try wire.request("catalog"))
        let selected = try handle(catalog)
        let outside: [String: Any] = ["handle": selected, "region": ["x": 99, "y": 0, "width": 2, "height": 2]]
        #expect(status(await owner.execute(try wire.request("start", extra: outside))) == "invalidRequest")
        #expect(sequence.makes == 0)
        let exact: [String: Any] = ["handle": selected, "region": ["x": 10, "y": 20, "width": 30, "height": 40]]
        #expect(status(await owner.execute(try wire.request("start", extra: exact))) == "started")
        #expect(status(await owner.execute(try wire.request("suspend"))) == "joined")
        let changed: [String: Any] = ["handle": selected, "region": ["x": 11, "y": 20, "width": 30, "height": 40]]
        #expect(status(await owner.execute(try wire.request("start", extra: changed))) == "stale")
        #expect(sequence.makes == 1)
        #expect(status(await owner.execute(try wire.request("start", extra: exact))) == "started")
        #expect(sequence.makes == 2)
        #expect(await owner.drain().joined)
    }

    @Test func suspensionDuringStartJoinsTheAdmittedWorkWithoutClosingSelection() async throws {
        let backend = CaptureBackend(), owner = makeOwner(backend)
        let wire = try await handshake(owner), selected = try handle(await owner.execute(try wire.request("catalog")))
        let starting = Task { await owner.execute(try wire.request("start", extra: ["handle": selected])) }
        await backend.producer.startEntered.wait()
        let suspension = Task { await owner.execute(try wire.request("suspend")) }
        await backend.producer.stopEntered.wait()
        backend.producer.startRelease.signal()
        #expect(status(try await starting.value) == "stale")
        await backend.producer.joinEntered.wait(); backend.producer.joinRelease.signal()
        #expect(status(try await suspension.value) == "joined")
        #expect(owner.fence.admits())
        #expect(status(await owner.execute(try wire.request("start", extra: ["handle": selected]))) == "started")
        #expect(await owner.drain().joined)
    }

    @Test(arguments: [false, true]) func uncleanSuspensionCannotResume(joined: Bool) async throws {
        let backend = CaptureBackend(joined: joined, diagnostic: joined ? "diagnostic" : nil)
        backend.producer.startRelease.signal(); backend.producer.joinRelease.signal()
        let slot = NativeCaptureSlot()
        let (_, owner) = try #require(slot.attach(fence: NativeCaptureFence { true }, operations: backend.operations))
        let (other, _) = try #require(slot.attach(fence: NativeCaptureFence { true }, operations: backend.operations))
        let wire = try await handshake(owner), selected = try handle(await owner.execute(try wire.request("catalog")))
        #expect(status(await owner.execute(try wire.request("start", extra: ["handle": selected]))) == "started")
        #expect(status(await owner.execute(try wire.request("suspend"))) == (joined ? "joined" : "retirementFailed"))
        #expect(status(await owner.execute(try wire.request("start", extra: ["handle": selected]))) == "stale")
        #expect(slot.reserveStream(other) == joined)
        if joined { slot.releaseStream(other) }
        #expect(await owner.drain().joined == joined)
    }

    @Test func terminalStopDuringSuspensionJoinsWithoutReopeningScope() async throws {
        let backend = CaptureBackend(), owner = makeOwner(backend)
        backend.producer.startRelease.signal()
        let wire = try await handshake(owner), selected = try handle(await owner.execute(try wire.request("catalog")))
        #expect(status(await owner.execute(try wire.request("start", extra: ["handle": selected]))) == "started")
        let suspension = Task { await owner.execute(try wire.request("suspend")) }
        await backend.producer.joinEntered.wait()
        let stop = Task { await owner.execute(try wire.request("stop")) }
        for _ in 0..<1_000 where owner.fence.admits() { await Task.yield() }
        #expect(!owner.fence.admits(), "Terminal Stop must enter before the suspended producer joins")
        backend.producer.joinRelease.signal()
        #expect(status(try await suspension.value) == "joined")
        #expect(status(try await stop.value) == "joined")
        #expect(!owner.fence.admits())
        #expect(status(await owner.execute(try wire.request("start", extra: ["handle": selected]))) == "stale")
    }

    @Test func automationEndpointIsReadOnlyAndBoundToTheAuthenticatedSession() async throws {
        let generation = UUID(), slot = NativeCaptureSlot()
        let operations = NativeCaptureOperations(validate: { true }, catalog: { _ in [] },
            automationEndpoint: { NativeAutomationEndpoint(socket: "/tmp/tron-cua-\(generation.uuidString.lowercased())/s", generation: generation) })
        let (_, owner) = try #require(slot.attach(fence: NativeCaptureFence { true }, operations: operations))
        let wire = try await handshake(owner)
        let reply = await owner.execute(try wire.request("automationEndpoint"))
        #expect(status(reply) == "automationEndpoint")
        let object = try #require(JSONSerialization.jsonObject(with: reply.control) as? [String: Any])
        #expect((object["generation"] as? String)?.lowercased() == generation.uuidString.lowercased())
        #expect(reply.jpeg == nil)
        var wrong = wire; wrong.fields["sessionID"] = UUID().uuidString
        #expect(status(await owner.execute(try wrong.request("automationEndpoint"))) == "stale")
        #expect(throws: (any Error).self) { try wire.request("automationEndpoint", extra: ["socket": "/forged"]) }
        #expect(await owner.drain().joined)
    }

    private func makeOwner(_ backend: CaptureBackend) -> NativeCaptureSession {
        let slot = NativeCaptureSlot()
        return slot.attach(fence: NativeCaptureFence { true }, operations: backend.operations)!.1
    }
    private func handshake(_ owner: NativeCaptureSession) async throws -> CaptureWireFixture {
        let wire = CaptureWireFixture()
        let response = await owner.execute(try wire.request("hello"))
        #expect(status(response) == "ready")
        let object = try #require(JSONSerialization.jsonObject(with: response.control) as? [String: Any])
        return CaptureWireFixture(fields: Dictionary(uniqueKeysWithValues: ["bootID", "connectionID", "sessionID", "loadID"].map { ($0, object[$0] as! String) }))
    }
    private func status(_ response: NativeCaptureResponse) -> String? {
        (try? JSONSerialization.jsonObject(with: response.control) as? [String: Any])?["status"] as? String
    }
    private func handle(_ response: NativeCaptureResponse) throws -> String {
        let object = try #require(JSONSerialization.jsonObject(with: response.control) as? [String: Any])
        let entries = try #require(object["sources"] as? [[String: Any]])
        return try #require(entries.first?["handle"] as? String)
    }
}

private final class CaptureProducerSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CaptureTestProducer]
    private var catalogCount = 0
    private var makeCount = 0
    init(_ values: [CaptureTestProducer]) { self.values = values }
    var catalogs: Int { lock.withLock { catalogCount } }
    var makes: Int { lock.withLock { makeCount } }
    func catalogued() { lock.withLock { catalogCount += 1 } }
    func make() -> CaptureTestProducer { lock.withLock { makeCount += 1; return values.removeFirst() } }
}

private struct CaptureWireFixture: Sendable {
    var fields: [String: String] = ["loadID": UUID().uuidString]
    func request(_ operation: String, command: UUID = UUID(), extra: [String: Any] = [:]) throws -> NativeCaptureRequest {
        try NativeCaptureRequest.decode(data(operation, command: command, extra: extra))
    }
    func data(_ operation: String, command: UUID = UUID(), extra: [String: Any] = [:]) throws -> Data {
        var values: [String: Any] = fields
        values.merge(["version": 1, "operation": operation]) { _, new in new }
        if operation != "pull" { values["commandID"] = command.uuidString }
        values.merge(extra) { _, new in new }
        return try JSONSerialization.data(withJSONObject: values)
    }
}

private actor CaptureBackend {
    nonisolated let catalogEntered = CaptureTestLatch()
    nonisolated let catalogRelease = CaptureTestLatch()
    nonisolated let producer: CaptureTestProducer
    private let clock: CaptureTestClock?
    private var valid = true
    private(set) var nativeCalls = 0
    init(holdCatalog: Bool = false, joined: Bool = true, diagnostic: String? = nil, clock: CaptureTestClock? = nil) {
        producer = CaptureTestProducer(joined: joined, diagnostic: diagnostic)
        self.clock = clock
        if !holdCatalog { catalogRelease.signal() }
    }
    func reject() { valid = false }
    private func validate() -> Bool { valid }
    nonisolated var operations: NativeCaptureOperations {
        var operations = NativeCaptureOperations(validate: { await self.validate() }, catalog: { _ in await self.catalog() }, automationEndpoint: { nil })
        if let clock { operations.now = { 0 }; operations.waitUntil = { await clock.wait($0) } }
        return operations
    }
    private func catalog() async -> [NativeCaptureTarget] {
        nativeCalls += 1; catalogEntered.signal()
        await catalogRelease.wait()
        return [NativeCaptureTarget(kind: .window, applicationName: "Fixture", title: "Synthetic", width: 1000, height: 800, make: { [producer] _, _ in producer })]
    }
}
private final class CaptureTestProducer: NativeCaptureProducing, @unchecked Sendable {
    let generation = UUID()
    let startEntered = CaptureTestLatch(), startRelease = CaptureTestLatch()
    let joinEntered = CaptureTestLatch(), joinRelease = CaptureTestLatch()
    private let lock = NSLock()
    private var stopped = false
    private var reads = 0
    private var offered: NativeCaptureHostFrame?
    private var afterTake: (@Sendable () -> Void)?
    private var startFailure: NativeWindowCaptureError?
    private var pullFailure: NativeWindowCaptureError?
    func failStart(_ failure: NativeWindowCaptureError) { lock.withLock { startFailure = failure } }
    func failPull(_ failure: NativeWindowCaptureError) { lock.withLock { pullFailure = failure } }
    private let joined: Bool
    private let diagnostic: String?
    init(joined: Bool, diagnostic: String? = nil) { self.joined = joined; self.diagnostic = diagnostic }
    var stopRequested: Bool { lock.withLock { stopped } }
    var pulls: Int { lock.withLock { reads } }
    let stopEntered = CaptureTestLatch()
    func requestStop() { lock.withLock { stopped = true }; stopEntered.signal() }
    func start() async -> NativeWindowCaptureAvailability {
        startEntered.signal(); await startRelease.wait()
        return lock.withLock { startFailure.map { .unavailable($0) } ?? .available(generation) }
    }
    func join() async -> NativeCaptureRetirement {
        joinEntered.signal(); await joinRelease.wait()
        return NativeCaptureRetirement(joined: joined, diagnostic: diagnostic)
    }
    func offer(_ frame: NativeCaptureHostFrame, afterTake: (@Sendable () -> Void)? = nil) {
        lock.withLock { offered = frame; self.afterTake = afterTake }
    }
    func take(generation: UUID) throws -> NativeCaptureHostFrame? {
        if let failure = lock.withLock({ pullFailure }) { throw failure }
        let result = lock.withLock { reads += 1; let result = (offered, afterTake); offered = nil; afterTake = nil; return result }
        result.1?()
        return result.0
    }
}
private final class CaptureTestLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var ready = false
    var isReady: Bool { lock.withLock { ready } }
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func signal() {
        let waiters = lock.withLock { ready = true; defer { self.waiters.removeAll() }; return self.waiters }
        for waiter in waiters { waiter.resume() }
    }
    func wait() async {
        await withCheckedContinuation { continuation in
            let immediate = lock.withLock { if ready { return true }; waiters.append(continuation); return false }
            if immediate { continuation.resume() }
        }
    }
}

private extension NativeCaptureSlot {
    func attach(fence: NativeCaptureFence, operations: NativeCaptureOperations) -> (UUID, NativeCaptureSession)? {
        let handshake = NativeCaptureHandshake(); handshake.install(Task {})
        guard let id = beginHandshake(handshake), let session = finishHandshake(id, fence: fence, operations: operations) else { return nil }
        abandonHandshake(id) // Fixture admission performs no OS validation.
        return (id, session)
    }
}
private final class CaptureTestClock: Sendable {
    let entered = CaptureTestLatch(), fire = CaptureTestLatch()
    func wait(_ deadline: UInt64) async {
        entered.signal(); await fire.wait()
    }
}
private final class CaptureTestResponse: @unchecked Sendable {
    private let lock = NSLock()
    private let ready = CaptureTestLatch()
    private var result: NativeCaptureResponse?
    func resolve(_ result: NativeCaptureResponse) { lock.withLock { self.result = result }; ready.signal() }
    func value() async -> NativeCaptureResponse { await ready.wait(); return lock.withLock { result! } }
}
