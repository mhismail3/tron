import Testing
import CoreGraphics
@testable import TronMobile

struct ContextWindowSliderTests {
    private func scale(maximum: Int = 1_050_000, defaultValue: Int = 272_000, minimum: Int = 37_408) -> ContextWindowSliderScale {
        ContextWindowSliderScale(
            limits: ContextWindowLimits(minimum: minimum, maximum: maximum, default: defaultValue, longContextThreshold: nil),
            defaultValue: defaultValue
        )
    }

    @Test("Detents keep exact bounds and defaults without crowded million-token quarters")
    func detents() {
        #expect(scale().detents == [37_408, 272_000, 500_000, 750_000, 1_050_000])
        #expect(scale(maximum: 1_048_576, defaultValue: 200_000).detents == [37_408, 200_000, 500_000, 750_000, 1_048_576])
        #expect(scale(maximum: 1_000_000, defaultValue: 1_000_000).detents == [37_408, 200_000, 500_000, 750_000, 1_000_000])
        #expect(scale(maximum: 200_000, defaultValue: 200_000).detents == [37_408, 50_000, 100_000, 150_000, 200_000])
        #expect(scale(maximum: 128_000, defaultValue: 128_000, minimum: 1_024).detents == [1_024, 32_000, 64_000, 96_000, 128_000])
        #expect(scale(maximum: 1_050_000, defaultValue: 600_000, minimum: 600_000).detents == [600_000, 750_000, 1_050_000])
    }

    @Test("Continuous attraction stays monotonic, bounded, and exact at each detent")
    func attraction() {
        let scale = scale()
        for width in [180.0, 320.0, 420.0] {
            var previous = -1.0
            for step in 0...2_000 {
                let raw = Double(step) / 2_000
                let value = scale.attractedProgress(raw, trackWidth: width)
                #expect(value >= previous)
                #expect((0...1).contains(value))
                // No more than a tiny fraction of one sample: no detent jump.
                if previous >= 0 { #expect(value - previous < 0.001) }
                previous = value
            }
            for detent in scale.detents {
                let progress = scale.progress(for: detent)
                #expect(scale.attractedProgress(progress, trackWidth: width) == progress)
                #expect(scale.settledTokens(at: progress + 4 / width, trackWidth: width) == detent)
            }
            let near = scale.progress(for: 500_000) + 8 / width
            #expect(scale.attractedProgress(near, trackWidth: width) < near)
            let free = scale.progress(for: 630_000)
            #expect(scale.settledTokens(at: free, trackWidth: width) == 630_000)
        }
    }

    @Test("Nearby defaults and bounds do not introduce attraction discontinuities")
    func adjacentWells() {
        for scale in [scale(defaultValue: 38_000), scale(maximum: 200_000, defaultValue: 200_000)] {
            var previous = 0.0
            for step in 0...10_000 {
                let progress = scale.attractedProgress(Double(step) / 10_000, trackWidth: 180)
                #expect(progress >= previous)
                #expect(progress - previous < 0.0002)
                previous = progress
            }
        }
    }

    @Test("Endpoints, single-value models, and accessible stepping remain valid")
    func bounds() {
        let scale = scale()
        #expect(scale.tokens(at: -1) == 37_408)
        #expect(scale.tokens(at: 2) == 1_050_000)
        #expect(scale.adjacentDetent(to: 300_000, increasing: true) == 500_000)
        #expect(scale.adjacentDetent(to: 300_000, increasing: false) == 272_000)
        #expect(scale.adjacentDetent(to: 1_050_000, increasing: true) == 1_050_000)
        let fixed = self.scale(maximum: 1_024, defaultValue: 1_024, minimum: 1_024)
        #expect(fixed.detents == [1_024])
        #expect(fixed.progress(for: 1_024) == 0)
        #expect(fixed.tokens(at: 0.5) == 1_024)
    }

    @Test("A preview preserves inheritance until edited and default explicitly resets")
    func draft() {
        var inherited = ContextWindowSliderDraft(value: 272_000, selection: nil)
        #expect(!inherited.changed)
        #expect(inherited.selection == nil)
        inherited.select(630_123, defaultValue: 272_000)
        #expect(inherited.changed)
        #expect(inherited.selection == 630_123)
        inherited.select(272_000, defaultValue: 272_000)
        #expect(inherited.selection == nil)
        let bounded = ContextWindowSliderDraft(value: 1_050_000, selection: 2_000_000)
        #expect(!bounded.changed)
        #expect(bounded.selection == 2_000_000)
    }

    @MainActor @Test("Default label stays on the endpoint row beside a colliding bound, wrapping only without room")
    func defaultLabelPlacement() {
        let sizes = [CGSize(width: 60, height: 16), CGSize(width: 64, height: 16), CGSize(width: 84, height: 16)]
        let inset = ContextWindowSliderLabelsLayout.trackInset
        // Default at the maximum: same row, fully left of the maximum label.
        let atMax = ContextWindowSliderLabelsLayout.placement(sizes: sizes, width: 340, defaultProgress: 1)
        #expect(atMax.height == 16)
        #expect(atMax.centers[1].y == atMax.centers[2].y)
        #expect(atMax.centers[1].x + 32 <= atMax.centers[2].x - 42)
        // Default at the minimum: same row, fully right of the minimum label.
        let atMin = ContextWindowSliderLabelsLayout.placement(sizes: sizes, width: 340, defaultProgress: 0)
        #expect(atMin.height == 16)
        #expect(atMin.centers[1].x - 32 >= atMin.centers[0].x + 30)
        // A default clear of both bounds keeps its exact track position.
        let middle = ContextWindowSliderLabelsLayout.placement(sizes: sizes, width: 340, defaultProgress: 0.5)
        #expect(middle.centers[1].x == inset + 0.5 * (340 - 2 * inset))
        // Too narrow for one row: wraps below, but never past either edge.
        let narrow = ContextWindowSliderLabelsLayout.placement(sizes: sizes, width: 190, defaultProgress: 1)
        #expect(narrow.height > 16)
        #expect(narrow.centers[1].x + 32 <= 190)
    }
}
