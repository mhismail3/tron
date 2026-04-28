import Testing
import Foundation
@testable import TronMobile

@Suite("System RPC Types")
struct SystemRPCTypesTests {
    @Test("system.ping params encode protocol version and client version")
    func pingParamsEncodeHandshake() throws {
        let params = SystemPingParams(protocolVersion: 1, clientVersion: "1.2.3")
        let data = try JSONEncoder().encode(params)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["protocolVersion"] as? Int == 1)
        #expect(json["clientVersion"] as? String == "1.2.3")
    }
}
