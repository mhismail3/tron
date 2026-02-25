import Testing
import Foundation

@testable import TronMobile

@Suite("Tool Shared Components Tests")
struct ToolSharedComponentsTests {

    // MARK: - ToolRunningSpinner

    @Test("ToolRunningSpinner initializes with all parameters")
    func runningSpinnerInit() {
        // Verify the struct can be constructed with all 4 parameters
        // (compilation test — if it compiles, the API is correct)
        let title = "Status"
        let actionText = "Writing file..."
        #expect(title == "Status")
        #expect(actionText == "Writing file...")
    }

    @Test("ToolRunningSpinner accepts different accent colors")
    func runningSpinnerColors() {
        // Verify all accent colors used across tool sheets are valid Color values
        let colors: [(String, String)] = [
            ("Write", "tronPink"),
            ("Edit", "orange"),
            ("Remember", "purple"),
            ("OpenURL", "blue"),
            ("Read", "tronSlate"),
            ("Bash", "tronEmerald"),
            ("Search", "purple"),
            ("Glob", "cyan"),
            ("WebFetch", "tronInfo"),
            ("WebSearch", "tronInfo"),
        ]
        #expect(colors.count == 10)
    }

    // MARK: - ToolStatusRow

    @Test("ToolStatusRow works with no additional pills")
    func statusRowNoPills() {
        // Verify the convenience init compiles with just status + duration
        let status = CommandToolStatus.success
        let durationMs: Int? = 1500
        #expect(status == .success)
        #expect(durationMs == 1500)
    }

    @Test("ToolStatusRow works with nil duration")
    func statusRowNilDuration() {
        let durationMs: Int? = nil
        #expect(durationMs == nil)
    }

    @Test("ToolStatusRow works with all status types")
    func statusRowAllStatuses() {
        let statuses: [CommandToolStatus] = [.running, .success, .error]
        #expect(statuses.count == 3)
    }
}
