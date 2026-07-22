import CoreGraphics
import Testing
@testable import TronMobile

@MainActor
@Suite("Chat Viewport Measurements Tests")
struct ChatViewportMeasurementsTests {
    @Test("Unmeasured viewport cannot satisfy initial reveal")
    func unmeasuredViewportIsNotRevealReady() {
        let measurements = ChatViewportMeasurements()

        #expect(measurements.initialDistanceFromBottom == .infinity)
        #expect(!ChatTranscriptRevealPolicy.isReadyToReveal(
            hasScrollProxy: true,
            consecutiveBottomSamples: 2,
            distanceFromBottom: measurements.initialDistanceFromBottom
        ))
    }

    @Test("Viewport remains unmeasured until the bottom anchor materializes")
    func viewportWaitsForBottomAnchor() {
        let measurements = ChatViewportMeasurements()

        measurements.recordViewportHeight(800)

        #expect(measurements.messageViewportHeight == 800)
        #expect(measurements.initialDistanceFromBottom == .infinity)
    }

    @Test("Materialized bottom anchor owns initial distance")
    func bottomAnchorOwnsInitialDistance() {
        let measurements = ChatViewportMeasurements()
        measurements.recordViewportHeight(800)

        measurements.recordInitialBottomAnchor(maxY: 800)

        #expect(measurements.initialBottomAnchorMaxY == 800)
        #expect(measurements.initialDistanceFromBottom == 0)
    }

    @Test("Absent bottom anchor returns initial distance to unmeasured")
    func absentBottomAnchorReturnsToUnmeasured() {
        let measurements = ChatViewportMeasurements()
        measurements.recordViewportHeight(800)
        measurements.recordInitialBottomAnchor(maxY: 800)
        #expect(measurements.initialDistanceFromBottom == 0)

        measurements.recordInitialBottomAnchor(maxY: nil)

        #expect(measurements.initialBottomAnchorMaxY == nil)
        #expect(measurements.initialDistanceFromBottom == .infinity)
    }

    @Test("Anchor can arrive before viewport geometry and nonfinite anchors are ignored")
    func anchorAndViewportOrderingIsSafe() {
        let measurements = ChatViewportMeasurements()

        measurements.recordInitialBottomAnchor(maxY: .infinity)
        #expect(measurements.initialBottomAnchorMaxY == nil)

        measurements.recordInitialBottomAnchor(maxY: 988)
        #expect(measurements.initialDistanceFromBottom == .infinity)

        measurements.recordViewportHeight(800)

        #expect(measurements.initialDistanceFromBottom == 188)
    }

    @Test("Zero viewport invalidates stale height without recomputing the anchor")
    func zeroViewportInvalidatesStaleHeight() {
        let measurements = ChatViewportMeasurements()
        measurements.recordViewportHeight(800)
        measurements.recordInitialBottomAnchor(maxY: 1_000)
        #expect(measurements.initialDistanceFromBottom == 200)

        measurements.recordViewportHeight(0)
        measurements.recordInitialBottomAnchor(maxY: 700)

        #expect(measurements.messageViewportHeight == 0)
        #expect(measurements.initialDistanceFromBottom == .infinity)

        measurements.recordViewportHeight(600)
        #expect(measurements.initialDistanceFromBottom == 100)
    }

    @Test("Scroll geometry distinguishes undersized and overflowing transcripts")
    func scrollGeometryOwnsOverflowClassification() {
        let measurements = ChatViewportMeasurements()

        measurements.recordScrollGeometry(
            contentHeight: 700,
            viewportHeight: 1_200,
            bottomInset: 80
        )
        #expect(measurements.hasScrollGeometry)
        #expect(!measurements.hasScrollableOverflow)
        #expect(measurements.scrollContentHeight == 700)
        #expect(measurements.messageViewportHeight == 1_200)

        measurements.recordScrollGeometry(
            contentHeight: 1_500,
            viewportHeight: 800,
            bottomInset: 80
        )
        #expect(measurements.hasScrollableOverflow)
        #expect(measurements.scrollBottomInset == 80)
    }

    @Test("Invalid scroll geometry cannot replace the last valid classification")
    func invalidScrollGeometryIsIgnored() {
        let measurements = ChatViewportMeasurements()
        measurements.recordScrollGeometry(
            contentHeight: 700,
            viewportHeight: 1_200,
            bottomInset: 80
        )

        measurements.recordScrollGeometry(
            contentHeight: .infinity,
            viewportHeight: 0,
            bottomInset: .nan
        )

        #expect(measurements.hasScrollGeometry)
        #expect(!measurements.hasScrollableOverflow)
        #expect(measurements.scrollContentHeight == 700)
    }
}
