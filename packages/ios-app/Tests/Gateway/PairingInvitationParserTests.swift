import Foundation
import Testing
@testable import TronMobile

@Suite("One-time gateway pairing invitation")
struct PairingInvitationParserTests {
    @Test("parses a one-time code without a bearer token")
    func parses() throws {
        let url = try #require(URL(string: "tron://pair?host=100.64.0.1&port=9847&code=ABCDEFGH&machineId=m1&label=Mac"))
        let value = try #require(PairingInvitationParser.parse(url))
        #expect(value.host == "100.64.0.1")
        #expect(value.code == "ABCDEFGH")
        #expect(url.query?.contains("token=") == false)
    }

    @Test(arguments: [
        "tron://pair?host=https://invalid&port=9847&code=ABCDEFGH",
        "tron://pair?host=user@host&port=9847&code=ABCDEFGH",
        "tron://pair?host=host/path&port=9847&code=ABCDEFGH",
        "tron://pair?host=host&port=0&code=ABCDEFGH",
        "tron://pair?host=host&host=other&port=9847&code=ABCDEFGH",
        "tron://pair?host=host&port=9847&port=9848&code=ABCDEFGH",
        "tron://pair?host=host&port=9847&code=ABCDEFGH&code=IJKLMNOP",
        "tron://pair?host=host&port=9847&code=ABCDEFGH&label=One&label=Two",
        "tron://pair?host=host&port=9847&code=short",
    ])
    func rejectsMalformed(_ raw: String) {
        #expect(URL(string: raw).flatMap(PairingInvitationParser.parse) == nil)
    }
}
