import Foundation
import Testing
@testable import TronMobile

@Suite("Chat interaction trace")
struct ChatInteractionTraceTests {
    @Test("trace remains bounded and newest-first in diagnostics")
    func boundedRing() {
        let trace = ChatInteractionTrace()
        trace.resetForTesting()
        let context = trace.beginContext(retainedPresentation: true)

        for index in 0..<(ChatInteractionTrace.maximumRecords + 20) {
            trace.submission(
                .checkpoint,
                context: context,
                state: .init(presentationEpoch: index)
            )
        }

        let records = trace.diagnosticRecords(limit: 1_000)
        #expect(records.count == ChatInteractionTrace.maximumRecords)
        #expect(records.first?.record.message.contains(
            "presentation=\(ChatInteractionTrace.maximumRecords + 19)"
        ) == true)
        #expect(records.last?.record.event == "chat.context.begin")
        #expect(zip(records, records.dropFirst()).allSatisfy { pair in
            pair.0.record.timestamp > pair.1.record.timestamp
        })
    }

    @Test("diagnostic priority survives routine ring pressure")
    func priorityRetention() {
        let trace = ChatInteractionTrace()
        trace.resetForTesting()
        let context = trace.beginContext(retainedPresentation: false)
        for index in 0..<(ChatInteractionTrace.maximumRecords - 2) {
            trace.submission(
                .checkpoint,
                context: context,
                state: .init(presentationEpoch: index)
            )
        }
        trace.anomaly(
            .openingLostProjection,
            context: context,
            state: .init(canonicalRows: 10)
        )
        for index in 0..<40 {
            trace.geometry(
                .meaningfulChange,
                context: context,
                state: .init(layoutEpoch: index)
            )
        }

        let records = trace.diagnosticRecords(limit: 1_000)
        #expect(records.count == ChatInteractionTrace.maximumRecords)
        #expect(records.contains { $0.record.event == "chat.anomaly.opening-lost-projection" })
        #expect(records.contains { $0.record.message.contains("layout=39") })
    }

    @Test("command diagnostics use an ordinal that survives generic token redaction")
    func commandOrdinalIsExportSafe() throws {
        let trace = ChatInteractionTrace()
        let context = trace.beginContext(retainedPresentation: false)
        trace.command(
            .issued,
            context: context,
            command: ChatScrollCommand(
                token: 7, presentation: 1, origin: .presentation,
                destination: .openingTail("private-row"), animation: .disabled
            ),
            state: .empty
        )
        let record = try #require(trace.diagnosticRecords(limit: 1).first?.record)
        #expect(record.message.contains("commandOrdinal=7"))
        #expect(!record.message.contains("token="))
        #expect(!record.message.contains("private-row"))
        #expect(IOSClientDiagnosticBuffer.redactedMessage(record.message)
            .contains("commandOrdinal=7"))
    }

    @Test("opening target identity and content cannot enter command diagnostics")
    func commandIdentityIsRedacted() {
        let trace = ChatInteractionTrace()
        let context = trace.beginContext(retainedPresentation: false)
        let privateTarget = "private-session-row-prompt-path"
        let command = ChatScrollCommand(
            token: 7,
            presentation: 3,
            origin: .presentation,
            destination: .openingTail(privateTarget),
            animation: .disabled
        )

        trace.command(
            .issued,
            context: context,
            command: command,
            state: .init(
                viewportMode: .pinned,
                distanceFromBottom: 12,
                hasCommand: false,
                hasAppliedTarget: true,
                hasPendingRelease: true
            )
        )

        let record = trace.diagnosticRecords(limit: 1).first?.record
        #expect(record?.event == "chat.command.issued")
        #expect(record?.message.contains("destination=opening-tail") == true)
        #expect(record?.message.contains(privateTarget) == false)
        #expect(record?.message.contains("command=0 target=1 release=1") == true)
    }

    @Test("identity correlation is bounded, local, and content-free under trace pressure")
    func boundedIdentityCorrelation() throws {
        let trace = ChatInteractionTrace()
        let context = trace.beginContext(retainedPresentation: true)
        let privateID = "private-prompt-identity"
        let physical = try #require(trace.identityToken(privateID))
        #expect(trace.identityToken(privateID) == physical)
        let semantic = try #require(trace.identityToken("private-canonical-identity"))
        trace.lease(.canonicalHandoff, context: context, token: 7,
                    reason: .canonicalAcknowledgement,
                    state: .init(geometryRevision: 3, semanticRevision: 9,
                                 markerRevision: 5, materializationRevision: 2,
                                 repairAttempts: 1, layoutSettled: false,
                                 physicalRowToken: physical, semanticRowToken: semantic,
                                 rowMinY: 340, rowHeight: 44))
        for index in 0..<300 {
            _ = trace.identityToken("evicted-\(index)")
            trace.geometry(.meaningfulChange, context: context, state: .empty)
        }
        #expect(trace.identityToken(privateID) != physical)
        #expect(trace.identityToken(String(repeating: "sensitive", count: 1_000)) == nil)
        let records = trace.diagnosticRecords(limit: 1_000)
        #expect(records.count == ChatInteractionTrace.maximumRecords)
        #expect(records.contains { $0.record.message.contains("schema=2 app=") })
        let handoff = try #require(records.first { $0.record.event == "chat.lease.canonical-handoff" })
        #expect(handoff.record.message.contains("geometryRev=3 semanticRev=9 markerRev=5"))
        #expect(handoff.record.message.contains("physicalRow=\(physical) semanticRow=\(semantic)"))
        #expect(!records.contains { $0.record.message.contains("private-") || $0.record.message.contains("sensitive") })
    }

    @Test("availability diagnostics explain blocked actions using only closed inputs")
    func availabilityDiagnostics() throws {
        let trace = ChatInteractionTrace()
        let context = trace.beginContext(retainedPresentation: false)
        var value = ChatInteractionTrace.Availability(
            connected: true, reconciling: false, mountedAuthority: true,
            projectionAvailable: true, openingTask: true, transcriptReady: false,
            scrollAllowsSubmission: false, scrollCommand: true, submissionPending: false,
            uploading: false, sending: false, commandReady: false, attachmentsReady: true,
            sceneActive: true, viewportActive: true, publicationActive: true
        )
        trace.availability(value, context: context, blockedAction: true)
        let blocked = try #require(trace.diagnosticRecords(limit: 1).first?.record)
        #expect(blocked.event == "chat.composer.admission-blocked")
        #expect(blocked.message.contains("authority=1 projection=1 openingTask=1 ready=0"))
        #expect(blocked.message.contains("commandReady=0 attachmentsReady=1"))
        value.openingTask = false
        value.transcriptReady = true
        value.scrollAllowsSubmission = true
        value.scrollCommand = false
        value.commandReady = true
        trace.availability(value, context: context)
        let ready = try #require(trace.diagnosticRecords(limit: 1).first?.record)
        #expect(ready.event == "chat.composer.availability")
        #expect(ready.message.contains("commandReady=1 attachmentsReady=1"))
    }

    @Test("an unchanged composer availability repeat does not spend a ring slot")
    func availabilityRepeatsAreDiscarded() {
        let trace = ChatInteractionTrace()
        trace.resetForTesting()
        let context = trace.beginContext(retainedPresentation: false)
        let waiting = Self.availabilitySample()
        trace.availability(waiting, context: context)
        trace.availability(waiting, context: context)
        var ready = waiting
        ready.transcriptReady = false
        trace.availability(ready, context: context)
        // A blocked admission is one discrete user action, not a repeat sample.
        trace.availability(waiting, context: context, blockedAction: true)

        let events = trace.diagnosticRecords(limit: 1_000).map(\.record.event)
        #expect(events.filter { $0 == "chat.composer.availability" }.count == 2)
        #expect(events.filter { $0 == "chat.composer.admission-blocked" }.count == 1)
    }

    @Test("geometry survives composer availability noise under ring pressure")
    func geometrySurvivesAvailabilityNoise() {
        let trace = ChatInteractionTrace()
        trace.resetForTesting()
        let context = trace.beginContext(retainedPresentation: false)
        // Alternating values are real transitions, so every sample is retained
        // and only eviction can reclaim its slot.
        for index in 0..<(ChatInteractionTrace.maximumRecords - 2) {
            var value = Self.availabilitySample()
            value.sceneActive = index.isMultiple(of: 2)
            trace.availability(value, context: context, state: .init(presentationEpoch: index))
        }
        for index in 0..<40 {
            trace.geometry(.meaningfulChange, context: context, state: .init(layoutEpoch: index))
        }

        let records = trace.diagnosticRecords(limit: 1_000)
        #expect(records.count == ChatInteractionTrace.maximumRecords)
        #expect(records.filter { $0.record.event?.hasPrefix("chat.geometry.") == true }.count == 40)
        // Every eviction came from the availability samples, oldest first.
        #expect(records.filter { $0.record.event == "chat.composer.availability" }
            .count == ChatInteractionTrace.maximumRecords - 2 - 39)
        #expect(records.contains {
            $0.record.event == "chat.composer.availability"
                && $0.record.message.contains("presentation=39")
        })
        #expect(!records.contains {
            $0.record.event == "chat.composer.availability"
                && $0.record.message.contains("presentation=38")
        })
    }

    @Test("protected edges outlive composer availability noise")
    func protectedEdgesSurviveAvailabilityNoise() {
        let trace = ChatInteractionTrace()
        trace.resetForTesting()
        let context = trace.beginContext(retainedPresentation: false)
        trace.command(
            .issued,
            context: context,
            command: ChatScrollCommand(
                token: 7, presentation: 1, origin: .presentation,
                destination: .tail, animation: .disabled
            ),
            state: .empty
        )
        trace.lease(
            .boundedFallback, context: context, token: 7, reason: .attemptLimit, state: .empty
        )
        trace.anomaly(.submissionLostTail, context: context, state: .empty)
        for index in 0..<(ChatInteractionTrace.maximumRecords + 40) {
            var value = Self.availabilitySample()
            value.sceneActive = index.isMultiple(of: 2)
            trace.availability(value, context: context, state: .init(presentationEpoch: index))
        }

        let records = trace.diagnosticRecords(limit: 1_000)
        #expect(records.count == ChatInteractionTrace.maximumRecords)
        #expect(records.contains { $0.record.event == "chat.context.begin" })
        #expect(records.contains { $0.record.event == "chat.command.issued" })
        #expect(records.contains { $0.record.event == "chat.lease.bounded-fallback" })
        #expect(records.contains { $0.record.event == "chat.anomaly.submission-lost-tail" })
        // Only availability was reclaimed: the four protected edges still hold
        // the rest of the ring.
        #expect(records.filter { $0.record.event == "chat.composer.availability" }
            .count == ChatInteractionTrace.maximumRecords - 4)
    }

    @Test("compact and queued lease diagnostics expose ordering without exporting row IDs")
    @MainActor
    func compactLeaseDiagnostics() throws {
        let trace = ChatInteractionTrace()
        let context = trace.beginContext(retainedPresentation: false)
        let coordinator = ChatScrollCoordinator()
        coordinator.configureInteractionTrace(trace, context: context)
        defer { coordinator.cancel() }
        #expect(coordinator.discreteTailInserted(renderedID: "private-first-row"))
        #expect(coordinator.discreteTailInserted(renderedID: "private-next-row"))
        coordinator.recordEntranceDiagnostic(.admitted, renderedID: "private-first-row", observedLayoutEpoch: 0)
        coordinator.recordEntranceDiagnostic(.completed, renderedID: "private-first-row", observedLayoutEpoch: 0)
        let records = trace.diagnosticRecords(limit: 256)
        let queued = try #require(records.first { $0.record.event == "chat.lease.queued" })
        #expect(queued.record.message.contains("reason=target-owned"))
        #expect(queued.record.message.contains("pendingPhysicalRow="))
        #expect(records.contains { $0.record.event == "chat.entrance.admitted" })
        #expect(records.first?.record.event == "chat.entrance.completed")
        #expect(records.first?.record.message.contains("observedLayout=0") == true)
        #expect(!records.contains { $0.record.message.contains("private-") })
    }

    @Test("coordinator diagnostics use physical position and name semantic handoff distinctly")
    @MainActor
    func coordinatorDiagnosticsExposePhysicalPositionAndSemanticHandoff() throws {
        let trace = ChatInteractionTrace()
        let context = trace.beginContext(retainedPresentation: false)
        let coordinator = ChatScrollCoordinator()
        coordinator.configureInteractionTrace(trace, context: context)
        let spine = ChatPhysicalRowSpineIdentity(
            timelineIDs: ChatTranscriptIDs(canonical: ["older", "terminal"], live: []),
            runtimeIDs: [], lifecycleID: nil, queueIDs: [], aliases: [], fusion: nil,
            hasEarlierMessages: false
        )
        coordinator.projectionInstalled(
            structure: spine,
            terminalPhysicalID: "terminal",
            physicalRowPositions: ["older": 0, "terminal": 1],
            physicalTerminalPosition: 1
        )
        #expect(coordinator.discreteTailInserted(
            renderedID: "running", physicalTargetID: "older"
        ))
        let command = try #require(coordinator.command)
        #expect(trace.diagnosticRecords(limit: 256).contains {
            $0.record.event == "chat.command.issued"
                && $0.record.message.contains("requestedFromTerminal=-1")
        })
        #expect(coordinator.commandApplied(command))
        coordinator.reconcileMaterializationRows { $0 == "older" ? "completed" : nil }
        let handoff = try #require(trace.diagnosticRecords(limit: 256).first {
            $0.record.event == "chat.lease.semantic-handoff"
        })
        #expect(handoff.record.message.contains("physicalRow="))
        #expect(handoff.record.message.contains("semanticRow="))
        #expect(handoff.record.message.contains("rowEvidence="))
        #expect(!(handoff.record.event?.contains("canonical") ?? true))
        coordinator.discreteTailInserted(renderedID: "pending-running", physicalTargetID: "terminal")
        coordinator.reconcileMaterializationRows {
            $0 == "terminal" ? "pending-completed" : "completed"
        }
        let pendingHandoff = try #require(trace.diagnosticRecords(limit: 256).first {
            $0.record.event == "chat.lease.semantic-handoff"
        })
        let currentOwner = try #require(trace.identityToken("pending-completed"))
        #expect(pendingHandoff.record.message.contains("pendingSemanticRow=\(currentOwner)"))
        coordinator.cancel()
    }

    @Test("retirement revokes checkpoints without masking an active lost projection")
    @MainActor
    func retiredContextCannotAdmitCheckpoint() {
        let ledger = ChatInteractionTraceLedger()
        ledger.installContext(1)
        let submission = ledger.beginSubmission()
        #expect(ledger.ownsContext(1))
        #expect(ledger.ownsSubmission(submission))
        #expect(ChatInteractionAnomalyPolicy.lostProjection(expectedRows: 40, currentRows: 0))
        ledger.retire()
        #expect(ledger.context == 1)
        #expect(!ledger.ownsContext(1))
        #expect(!ledger.ownsSubmission(submission))
        ledger.installContext(2)
        #expect(!ledger.ownsContext(1))
        #expect(ledger.ownsContext(2))
    }

    @Test("anomaly policy distinguishes automatic displacement from reader ownership")
    func anomalyPolicy() {
        let atTail = ChatTranscriptGeometry(
            offsetY: 300,
            contentHeight: 900,
            containerHeight: 600
        )
        let displaced = ChatTranscriptGeometry(
            offsetY: 0,
            contentHeight: 1_200,
            containerHeight: 600
        )

        #expect(!ChatInteractionAnomalyPolicy.displacedPinnedViewport(
            expectedPinned: true,
            currentMode: .pinned,
            isUserInteracting: false,
            isPositionedByUser: false,
            geometry: atTail,
            tailClassification: .aligned
        ))
        #expect(ChatInteractionAnomalyPolicy.displacedPinnedViewport(
            expectedPinned: true,
            currentMode: .pinned,
            isUserInteracting: false,
            isPositionedByUser: false,
            geometry: displaced,
            tailClassification: .aboveViewport
        ))
        #expect(!ChatInteractionAnomalyPolicy.displacedPinnedViewport(
            expectedPinned: true,
            currentMode: .anchored,
            isUserInteracting: false,
            isPositionedByUser: false,
            geometry: displaced,
            tailClassification: .aboveViewport
        ))
        #expect(!ChatInteractionAnomalyPolicy.displacedPinnedViewport(
            expectedPinned: true,
            currentMode: .pinned,
            isUserInteracting: true,
            isPositionedByUser: true,
            geometry: displaced,
            tailClassification: .aboveViewport
        ))
        #expect(ChatInteractionAnomalyPolicy.lostProjection(expectedRows: 4, currentRows: 0))
        #expect(!ChatInteractionAnomalyPolicy.lostProjection(expectedRows: 0, currentRows: 0))

        let installedUnderflow = ChatTranscriptGeometry(
            offsetY: -198,
            contentHeight: 676,
            containerHeight: 758,
            bottomInset: 82,
            visibleTopY: 0,
            visibleBottomY: 758
        )
        #expect(!ChatInteractionAnomalyPolicy.displacedPinnedViewport(
            expectedPinned: true,
            currentMode: .pinned,
            isUserInteracting: false,
            isPositionedByUser: false,
            geometry: installedUnderflow,
            tailClassification: .belowViewport
        ))
    }

    @Test("observed tail edges retain evidence but exclude user-owned displacement")
    @MainActor
    func nativeTailEdgeDiagnostics() throws {
        let trace = ChatInteractionTrace()
        let context = trace.beginContext(retainedPresentation: true)
        let coordinator = ChatScrollCoordinator()
        coordinator.configureInteractionTrace(trace, context: context)
        let aligned = CGRect(x: 0, y: 663, width: 100, height: 12)
        let displaced = CGRect(x: 0, y: 700, width: 100, height: 12)
        let atTail = ChatTranscriptGeometry(offsetY: 300, contentHeight: 675, containerHeight: 675)
        coordinator.geometryChanged(previous: .zero, current: atTail)
        coordinator.semanticFrameChanged(renderedID: "transcript-bottom", layoutEpoch: coordinator.layoutEpoch, frame: aligned)
        coordinator.geometryChanged(previous: atTail, current: atTail)
        let latestBeforeDisplacement = ChatTranscriptGeometry(
            offsetY: 360, contentHeight: 700, containerHeight: 675
        )
        // The marker has not changed, but the SwiftUI viewport sample has. The next
        // marker edge must carry this immediately preceding geometry.
        coordinator.geometryChanged(previous: atTail, current: latestBeforeDisplacement)
        coordinator.semanticFrameChanged(renderedID: "transcript-bottom", layoutEpoch: coordinator.layoutEpoch, frame: displaced)
        for index in 0..<300 {
            trace.geometry(.meaningfulChange, context: context,
                           state: .init(layoutEpoch: index))
        }
        let first = try #require(trace.diagnosticRecords(limit: 256).first {
            $0.record.event == "chat.tail.first-displacement"
        })
        #expect(first.record.level == "warning")
        #expect(first.record.message.contains("beforeTail=aligned"))
        #expect(first.record.message.contains("beforeOffset=360.0"))
        #expect(first.record.message.contains("beforeContent=700.0"))
        #expect(first.record.message.contains("tail=above-viewport"))
        #expect(first.record.message.contains("tailEvidence=swiftui-marker"))
        #expect(first.record.message.contains("geometrySource=swiftui-estimate"))
        coordinator.semanticFrameChanged(renderedID: "transcript-bottom", layoutEpoch: coordinator.layoutEpoch, frame: aligned)
        #expect(trace.diagnosticRecords(limit: 256).contains {
            $0.record.event == "chat.tail.recovered"
        })
        let lossCount = trace.diagnosticRecords(limit: 256).filter {
            $0.record.event == "chat.tail.first-displacement"
        }.count
        coordinator.scrollPositionChanged(isPositionedByUser: true)
        coordinator.semanticFrameChanged(renderedID: "transcript-bottom", layoutEpoch: coordinator.layoutEpoch, frame: displaced)
        #expect(trace.diagnosticRecords(limit: 256).filter {
            $0.record.event == "chat.tail.first-displacement"
        }.count == lossCount)
        coordinator.cancel()
    }

    @Test("anomalies are actionable local error records")
    func anomalySeverity() {
        let trace = ChatInteractionTrace()
        let context = trace.beginContext(retainedPresentation: true)

        trace.anomaly(
            .openingViewportDisplaced,
            context: context,
            state: .init(
                canonicalRows: 42,
                viewportMode: .pinned,
                distanceFromBottom: 900,
                containerHeight: 700,
                isPastBottomEdge: false
            )
        )

        let record = trace.diagnosticRecords(limit: 1).first
        #expect(record?.profileLabel == "iOS client · Chat trace")
        #expect(record?.record.level == "error")
        #expect(record?.record.event == "chat.anomaly.opening-viewport-displaced")
        #expect(record?.record.message.contains("canonicalRows=42") == true)
    }

    private static func availabilitySample() -> ChatInteractionTrace.Availability {
        ChatInteractionTrace.Availability(
            connected: true, reconciling: false, mountedAuthority: true,
            projectionAvailable: true, openingTask: false, transcriptReady: true,
            scrollAllowsSubmission: true, scrollCommand: false, submissionPending: false,
            uploading: false, sending: false, commandReady: true, attachmentsReady: true,
            sceneActive: true, viewportActive: true, publicationActive: true
        )
    }
}
