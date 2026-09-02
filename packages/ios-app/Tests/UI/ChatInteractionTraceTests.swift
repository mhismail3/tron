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
        #expect(records.last?.record.event == "chat.submission.checkpoint")
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
            state: .init(viewportMode: .pinned, distanceFromBottom: 12)
        )

        let record = trace.diagnosticRecords(limit: 1).first?.record
        #expect(record?.event == "chat.command.issued")
        #expect(record?.message.contains("destination=opening-tail") == true)
        #expect(record?.message.contains(privateTarget) == false)
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
}
