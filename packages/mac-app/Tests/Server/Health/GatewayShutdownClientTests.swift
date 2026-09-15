import Foundation
import Testing
@testable import TronMac

@Suite("Gateway shutdown admission decoding")
struct GatewayShutdownClientTests {
    @Test func acceptsOnlyTheExactStoppingResponse() throws {
        let data = Data(#"{"type":"response","id":"quit-command","ok":true,"result":{"stopping":true,"scheduled":true,"activeSessionIds":["session"]}}"#.utf8)
        let result = try #require(try GatewayShutdownClient.decode(data, expectedID: "quit-command"))
        #expect(result.stopping && result.scheduled)
        #expect(try GatewayShutdownClient.decode(data, expectedID: "another-command") == nil)
    }
    @Test func rejectsRestartOrAmbiguousSuccessShapes() {
        for result in [#"{"restarting":true,"scheduled":false,"activeSessionIds":[]}"#,
                       #"{"stopping":false,"scheduled":false,"activeSessionIds":[]}"#,
                       #"{"stopping":true,"scheduled":false,"activeSessionIds":[""]}"#, "{}"] {
            let data = Data("{\"type\":\"response\",\"id\":\"quit-command\",\"ok\":true,\"result\":\(result)}".utf8)
            #expect(throws: GatewayRestartClient.Failure.self) { try GatewayShutdownClient.decode(data, expectedID: "quit-command") }
        }
    }
    @Test func gatewayRefusalRemainsARefusal() {
        let data = Data(#"{"type":"response","id":"quit-command","ok":false,"error":{"code":"busy","message":"Wait for update","retryable":true}}"#.utf8)
        #expect(throws: GatewayRestartClient.Failure.gateway(code: "busy", message: "Wait for update", retryable: true)) {
            try GatewayShutdownClient.decode(data, expectedID: "quit-command")
        }
    }
}
