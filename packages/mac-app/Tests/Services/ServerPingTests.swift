import Foundation
import Testing
@testable import TronMac

/// Tests for the JSON-RPC response decoder behind `ServerPing`. The
/// network ping itself is not unit-tested (URLSession mocking is
/// expensive); we cover the decode path which is where every
/// JSON-shape edge lives.
@Suite("ServerPing.decode")
struct ServerPingDecodeTests {
    @Test("happy path: full result object")
    func happyDecode() throws {
        let body = """
        {"jsonrpc":"2.0","id":1,"result":{"serverVersion":"0.5.0","port":9847,"tailscaleIp":"100.64.0.1","paired":true}}
        """
        let info = try #require(ServerPing.decode(data: Data(body.utf8)))
        #expect(info.version == "0.5.0")
        #expect(info.port == 9847)
        #expect(info.tailscaleIp == "100.64.0.1")
        #expect(info.paired == true)
    }

    @Test("missing optional fields fall back to defaults")
    func missingOptionalFields() throws {
        let body = """
        {"jsonrpc":"2.0","id":1,"result":{}}
        """
        let info = try #require(ServerPing.decode(data: Data(body.utf8)))
        #expect(info.version == "")
        #expect(info.port == TronPaths.defaultServerPort)
        #expect(info.tailscaleIp == nil)
        #expect(info.paired == false)
    }

    @Test("error response (no result) returns nil")
    func errorResponseReturnsNil() throws {
        let body = """
        {"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"method not found"}}
        """
        #expect(ServerPing.decode(data: Data(body.utf8)) == nil)
    }

    @Test("malformed JSON returns nil")
    func malformedJSONReturnsNil() throws {
        #expect(ServerPing.decode(data: Data("garbage".utf8)) == nil)
        #expect(ServerPing.decode(data: Data()) == nil)
    }

    @Test("paired defaults to false when field is missing")
    func pairedDefaults() throws {
        let body = """
        {"result":{"serverVersion":"0.5.0","port":1234}}
        """
        let info = try #require(ServerPing.decode(data: Data(body.utf8)))
        #expect(info.paired == false)
    }
}
