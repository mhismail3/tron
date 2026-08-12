import Foundation
import Testing
@testable import TronMobile

@Suite("Dynamic protocol JSON")
struct JSONValueTests {
    @Test("round trips nested extension details")
    func roundTrip() throws {
        let value: JSONValue = .object(["items": .array([.string("one"), .number(2), .bool(true), .null])])
        let data = try JSONEncoder.gateway.encode(value)
        #expect(try JSONDecoder.gateway.decode(JSONValue.self, from: data) == value)
    }
}
