import Foundation
import Testing
@testable import TronMobile

@Suite("Session summary presentation")
struct SessionSummaryPresentationTests {
    @Test("dashboard activity timestamp is relative")
    func relativeTimestamp() {
        let now = Date(timeIntervalSince1970: 10_000)
        let updated = ISO8601DateFormatter().string(from: now.addingTimeInterval(-2 * 60 * 60))
        let session = SessionSummary(
            id: "session",
            name: "Session",
            cwd: "/tmp/project",
            parentSessionId: nil,
            createdAt: updated,
            updatedAt: updated,
            messageCount: 1,
            firstMessage: "hello",
            phase: .idle
        )

        #expect(session.relativeActivityDescription(relativeTo: now).contains("2"))
    }
}
