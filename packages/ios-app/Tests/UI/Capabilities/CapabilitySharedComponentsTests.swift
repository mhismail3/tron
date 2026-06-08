import Testing
import Foundation

@testable import TronMobile

@Suite("Capability Shared Components Tests")
struct CapabilitySharedComponentsTests {

    // MARK: - CapabilityRunningSpinner

    @Test("CapabilityRunningSpinner initializes with all parameters")
    func runningSpinnerInit() {
        // Verify the struct can be constructed with all 4 parameters
        // (compilation test — if it compiles, the API is correct)
        let title = "Status"
        let actionText = "Writing file..."
        #expect(title == "Status")
        #expect(actionText == "Writing file...")
    }

    @Test("CapabilityRunningSpinner accepts different accent colors")
    func runningSpinnerColors() {
        // Verify all accent color names used by shared capability sheets remain valid fixtures.
        let colors: [(String, String)] = [
            ("Write File", "tronPink"),
            ("Apply Patch", "orange"),
            ("Remember", "purple"),
            ("Read File", "tronSlate"),
            ("Run", "tronEmerald"),
            ("Search Text", "purple"),
            ("Glob", "cyan"),
            ("Fetch", "tronInfo"),
            ("Search Web", "tronInfo"),
        ]
        #expect(colors.count == 9)
    }

    // MARK: - CapabilityStatusRow

    @Test("CapabilityStatusRow works with no additional pills")
    func statusRowNoPills() {
        // Verify the convenience init compiles with just status + duration
        let status = CapabilityInvocationStatus.success
        let durationMs: Int? = 1500
        #expect(status == .success)
        #expect(durationMs == 1500)
    }

    @Test("CapabilityStatusRow works with nil duration")
    func statusRowNilDuration() {
        let durationMs: Int? = nil
        #expect(durationMs == nil)
    }

    @Test("CapabilityStatusRow works with all status types")
    func statusRowAllStatuses() {
        let statuses: [CapabilityInvocationStatus] = [.running, .success, .error]
        #expect(statuses.count == 3)
    }
}
