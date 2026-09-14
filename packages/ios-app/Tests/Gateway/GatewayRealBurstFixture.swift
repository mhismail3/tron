import Compression
import Foundation
@testable import TronMobile

private final class GatewayRealBurstFixtureBundleToken: NSObject {}

// Lossless raw-deflate capture of the Gateway RuntimeSlot prompt burst:
// source dcad5d679e3761ee903ed73056552f4f331f8b0f, source JSON SHA256
// de54530be65d8593c299fab50c89f6d7e2bcf8d00064a70b8a65d93af63bef35.
// The compressed resource is kept small while retaining exact decoded frames.
struct GatewayRealBurstFixture: Decodable {
    struct CapturedEvent: Decodable {
        let topic: String
        let payload: JSONValue

        var gatewayEvent: GatewayEvent {
            GatewayEvent(
                type: "event",
                topic: topic,
                sessionId: payload.objectValue?["sessionId"]?.stringValue,
                payload: payload
            )
        }

        var frame: JSONValue {
            .object([
                "type": .string("event"),
                "topic": .string(topic),
                "payload": payload,
            ])
        }
    }

    struct Receipt: Decodable { let operationId: String }

    let source: JSONValue
    let expectedAcceptedReceipt: Receipt
    let events: [CapturedEvent]
    let finalSnapshot: SessionSnapshot

    func snapshot(at index: Int) throws -> SessionSnapshot {
        guard events.indices.contains(index) else { throw FixtureError.invalidIndex }
        return try JSONDecoder.gateway.decode(
            SessionSnapshot.self,
            from: JSONEncoder.gateway.encode(events[index].payload)
        )
    }

    static func load() throws -> GatewayRealBurstFixture {
        guard let url = Bundle(
            for: GatewayRealBurstFixtureBundleToken.self
        ).url(forResource: "gateway-real-burst", withExtension: "json.zlib") else {
            throw FixtureError.missingResource
        }
        let compressed = try Data(contentsOf: url)
        var expanded = Data(repeating: 0, count: 8 * 1_024 * 1_024)
        let count = expanded.withUnsafeMutableBytes { destination in
            compressed.withUnsafeBytes { source in
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!,
                    destination.count,
                    source.bindMemory(to: UInt8.self).baseAddress!,
                    source.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard count > 0 else { throw FixtureError.invalidCompression }
        expanded.count = count
        return try JSONDecoder().decode(Self.self, from: expanded)
    }

    enum FixtureError: Error {
        case missingResource
        case invalidCompression
        case invalidIndex
    }
}
