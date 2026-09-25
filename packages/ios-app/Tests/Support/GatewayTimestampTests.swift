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
        #expect(GatewayTimestamp.preciseString(from: whole).hasPrefix("2026-01-02T03:04:05."))
        #expect(GatewayTimestamp.parse("invalid") == nil)
    }

    @Test("ordering uses instants across fractional precision and offsets")
    func semanticOrdering() {
        #expect(GatewayTimestamp.isNewer("2026-01-02T03:04:05.900Z", than: "2026-01-02T03:04:05Z"))
        let offset = GatewayTimestamp.isNewer("2026-01-02T04:04:05+01:00", than: "2026-01-02T03:04:05Z")
        let canonical = GatewayTimestamp.isNewer("2026-01-02T03:04:05Z", than: "2026-01-02T04:04:05+01:00")
        #expect(offset != canonical)
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
