import Foundation
import Testing
@testable import TronMobile

@Suite("Bounded dynamic JSON")
struct JSONValueBoundaryTests {
    @Test("node, collection, and depth budgets fail closed")
    func structuralBudgets() throws {
        let limits = JSONValueDecodingLimits(
            maximumDepth: 8,
            maximumNodes: 3,
            maximumCollectionMembers: 2,
            maximumStringBytes: 16,
            maximumTotalStringBytes: 32
        )
        #expect(try decode("[0,1]", limits: limits) == .array([.number(0), .number(1)]))
        #expect(throws: DecodingError.self) { try decode("[0,1,2]", limits: limits) }
        #expect(throws: DecodingError.self) { try decode(#"{"a":0,"b":1,"c":2}"#, limits: limits) }

        let shallow = JSONValueDecodingLimits(
            maximumDepth: 1,
            maximumNodes: 20,
            maximumCollectionMembers: 10,
            maximumStringBytes: 16,
            maximumTotalStringBytes: 32
        )
        #expect(try decode("[0]", limits: shallow) == .array([.number(0)]))
        #expect(throws: DecodingError.self) { try decode("[[0]]", limits: shallow) }
    }

    @Test("individual and aggregate UTF-8 string budgets include object keys")
    func stringBudgets() throws {
        let limits = JSONValueDecodingLimits(
            maximumDepth: 8,
            maximumNodes: 20,
            maximumCollectionMembers: 10,
            maximumStringBytes: 4,
            maximumTotalStringBytes: 6
        )
        #expect(try decode(#""éé""#, limits: limits) == .string("éé"))
        #expect(throws: DecodingError.self) { try decode(#""ééé""#, limits: limits) }
        #expect(try decode(#"["abc","def"]"#, limits: limits) == .array([.string("abc"), .string("def")]))
        #expect(throws: DecodingError.self) { try decode(#"["abc","defg"]"#, limits: limits) }
        #expect(throws: DecodingError.self) { try decode(#"{"long-key":null}"#, limits: limits) }
    }

    @Test("dynamic numbers are finite and exact integers are range safe")
    func numericSafety() throws {
        #expect(JSONValue.number(42).intValue == 42)
        #expect(JSONValue.number(42.5).intValue == nil)
        #expect(JSONValue.number(Double(Int.min)).intValue == Int.min)
        #expect(JSONValue.number(Double(Int.max)).intValue == nil)
        #expect(JSONValue.number(Double.greatestFiniteMagnitude).intValue == nil)
        #expect(JSONValue.number(.infinity).intValue == nil)
        #expect(throws: DecodingError.self) {
            try JSONDecoder.gateway.decode(JSONValue.self, from: Data("1e400".utf8))
        }
        #expect(throws: EncodingError.self) { try JSONEncoder.gateway.encode(JSONValue.number(.nan)) }
        #expect(throws: EncodingError.self) { try JSONEncoder.gateway.encode(JSONValue.number(.infinity)) }
    }

    @Test("decoder reuse cannot leak one document's accounting into the next")
    func reusedDecoder() throws {
        let limits = JSONValueDecodingLimits(
            maximumDepth: 8,
            maximumNodes: 3,
            maximumCollectionMembers: 3,
            maximumStringBytes: 8,
            maximumTotalStringBytes: 8
        )
        let decoder = JSONDecoder.gateway(jsonValueLimits: limits)
        let data = Data("[0,1]".utf8)
        #expect(try decoder.decode(JSONValue.self, from: data) == .array([.number(0), .number(1)]))
        #expect(try decoder.decode(JSONValue.self, from: data) == .array([.number(0), .number(1)]))
    }

    @Test("ordinary Foundation decoding retains aggregate node bounds")
    func ordinaryDecoderIsBounded() {
        let child = "[0,0,0,0]"
        let source = "[" + Array(repeating: child, count: 8_192).joined(separator: ",") + "]"
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(JSONValue.self, from: Data(source.utf8))
        }
    }

    @Test("inbound frames are rejected before oversized JSON decoding")
    func inboundFrameBound() {
        let data = Data(repeating: 0x20, count: GatewayFramePolicy.maximumInboundBytes + 1)
        #expect(throws: GatewayFailure.self) {
            try GatewayFrameDecoder.gateway.decode(data)
        }
    }

    @Test("gateway coders are fresh and safe for concurrent protocol decoding")
    func concurrentCoders() async throws {
        try await withThrowingTaskGroup(of: JSONValue.self) { group in
            for index in 0..<100 {
                group.addTask {
                    let data = Data(#"{"index":\#(index),"value":"ok"}"#.utf8)
                    return try JSONDecoder.gateway.decode(JSONValue.self, from: data)
                }
            }
            var count = 0
            for try await value in group {
                #expect(value.objectValue?["value"] == .string("ok"))
                count += 1
            }
            #expect(count == 100)
        }
    }

    private func decode(
        _ source: String,
        limits: JSONValueDecodingLimits
    ) throws -> JSONValue {
        try JSONDecoder.gateway(jsonValueLimits: limits).decode(
            JSONValue.self,
            from: Data(source.utf8)
        )
    }
}
