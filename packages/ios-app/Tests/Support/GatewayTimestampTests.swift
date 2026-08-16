import Foundation
import Testing
@testable import TronMobile

@Suite("Shared gateway timestamp presentation")
struct GatewayTimestampTests {
    @Test("fractional and whole-second timestamps retain parsing and output")
    func parsing() throws {
        let whole = try #require(GatewayTimestamp.parse("2026-01-02T03:04:05Z"))
        let fractional = try #require(GatewayTimestamp.parse("2026-01-02T03:04:05.000Z"))
        #expect(whole == fractional)
        #expect(GatewayTimestamp.string(from: whole) == "2026-01-02T03:04:05Z")
        #expect(GatewayTimestamp.parse("invalid") == nil)
    }

    @Test("relative labels preserve the established formatter semantics")
    func relative() throws {
        let reference = try #require(GatewayTimestamp.parse("2026-01-02T04:04:05Z"))
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let date = try #require(GatewayTimestamp.parse("2026-01-02T03:04:05Z"))
        #expect(
            GatewayTimestamp.relativeDescription("2026-01-02T03:04:05Z", relativeTo: reference)
                == formatter.localizedString(for: date, relativeTo: reference)
        )
    }

    @Test("shared formatter access remains deterministic under concurrency")
    func concurrency() async {
        await withTaskGroup(of: String.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    GatewayTimestamp.relativeDescription(
                        "2026-01-02T03:04:05.123Z",
                        relativeTo: Date(timeIntervalSince1970: 1_767_326_645)
                    )
                }
            }
            var values = Set<String>()
            for await value in group { values.insert(value) }
            #expect(values.count == 1)
        }
    }
}
