import Foundation
import Testing

@testable import TronMac

@Suite("MenuBarLogReader")
struct MenuBarLogReaderTests {

    @Test("unexpected response envelope is malformed")
    func unexpectedResponseEnvelopeIsMalformed() throws {
        let data = """
        {"type":"response","id":"mac-system-logs","ok":true,"result":{"entries":[]}}
        """.data(using: .utf8)!

        #expect(MenuBarLogReader.decodeFrame(data: data) == .malformed)
    }

    @Test("matching log frames require an unambiguous response envelope", arguments: [
        #"{"type":"event","id":"mac-system-logs","ok":true,"result":{"records":[]}}"#,
        #"{"id":"mac-system-logs","ok":true,"result":{"records":[]}}"#,
        #"{"type":"response","id":"mac-system-logs","result":{"records":[]}}"#,
        #"{"type":"response","id":"mac-system-logs","ok":"true","result":{"records":[]}}"#,
        #"{"type":"response","id":"mac-system-logs","ok":1,"result":{"records":[]}}"#,
        #"{"type":"response","id":"mac-system-logs","ok":true,"error":{"message":"failed"},"result":{"records":[]}}"#,
        #"{"type":"response","id":"mac-system-logs","ok":false,"error":{"message":"failed"},"result":{"records":[]}}"#,
    ])
    func rejectsInvalidMatchingEnvelope(body: String) {
        #expect(MenuBarLogReader.decodeFrame(data: Data(body.utf8)) == .malformed)
    }
}
