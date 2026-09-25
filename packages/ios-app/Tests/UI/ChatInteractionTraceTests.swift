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
