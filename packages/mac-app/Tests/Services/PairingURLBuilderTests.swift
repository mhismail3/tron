import Foundation
import Testing
@testable import TronMac

/// Tests the `PairingURLBuilder` — `tron://pair?host=…&port=…&token=…`
/// URL builder + parser. The parser must be a strict inverse of the
/// builder so the QR codes the Mac wrapper emits round-trip cleanly
/// through the iOS app's `PairingURLParser`.
@Suite("PairingURLBuilder")
struct PairingURLBuilderTests {
    @Test("happy path: host + port + token round-trips")
    func happyRoundTrip() throws {
        let payload = PairingPayload(host: "100.64.0.1", port: 9847, token: "abc123xyz", label: nil)
        let url = try #require(PairingURLBuilder.makeURL(payload))
        #expect(url.scheme == "tron")
        #expect(url.host == "pair")

        let parsed = try #require(PairingURLBuilder.parse(url))
        #expect(parsed == payload)
    }

    @Test("label is preserved in round-trip")
    func labelRoundTrip() throws {
        let payload = PairingPayload(host: "100.64.0.1", port: 9847, token: "tok", label: "My Mac")
        let url = try #require(PairingURLBuilder.makeURL(payload))
        let parsed = try #require(PairingURLBuilder.parse(url))
        #expect(parsed == payload)
    }

    @Test("trailing whitespace in host/token is trimmed")
    func whitespaceTrimming() throws {
        let payload = PairingPayload(host: "  100.64.0.1\n", port: 9847, token: "\ttok  ", label: nil)
        let url = try #require(PairingURLBuilder.makeURL(payload))
        let parsed = try #require(PairingURLBuilder.parse(url))
        #expect(parsed.host == "100.64.0.1")
        #expect(parsed.token == "tok")
    }

    @Test("empty host rejected")
    func emptyHostRejected() throws {
        let payload = PairingPayload(host: "", port: 9847, token: "tok", label: nil)
        #expect(PairingURLBuilder.makeURL(payload) == nil)
    }

    @Test("whitespace-only host rejected")
    func whitespaceOnlyHostRejected() throws {
        let payload = PairingPayload(host: "   \n\t", port: 9847, token: "tok", label: nil)
        #expect(PairingURLBuilder.makeURL(payload) == nil)
    }

    @Test("empty token rejected")
    func emptyTokenRejected() throws {
        let payload = PairingPayload(host: "100.64.0.1", port: 9847, token: "", label: nil)
        #expect(PairingURLBuilder.makeURL(payload) == nil)
    }

    @Test("zero/negative port rejected")
    func invalidPortRejected() throws {
        #expect(PairingURLBuilder.makeURL(PairingPayload(host: "1.2.3.4", port: 0, token: "t", label: nil)) == nil)
        #expect(PairingURLBuilder.makeURL(PairingPayload(host: "1.2.3.4", port: -1, token: "t", label: nil)) == nil)
    }

    @Test("parse rejects wrong scheme")
    func parseRejectsWrongScheme() throws {
        let url = try #require(URL(string: "https://pair?host=1.2.3.4&port=9847&token=t"))
        #expect(PairingURLBuilder.parse(url) == nil)
    }

    @Test("parse rejects wrong host segment")
    func parseRejectsWrongHost() throws {
        let url = try #require(URL(string: "tron://connect?host=1.2.3.4&port=9847&token=t"))
        #expect(PairingURLBuilder.parse(url) == nil)
    }

    @Test("parse rejects missing host field")
    func parseRejectsMissingHostField() throws {
        let url = try #require(URL(string: "tron://pair?port=9847&token=t"))
        #expect(PairingURLBuilder.parse(url) == nil)
    }

    @Test("parse rejects missing port field")
    func parseRejectsMissingPortField() throws {
        let url = try #require(URL(string: "tron://pair?host=1.2.3.4&token=t"))
        #expect(PairingURLBuilder.parse(url) == nil)
    }

    @Test("parse rejects non-numeric port")
    func parseRejectsNonNumericPort() throws {
        let url = try #require(URL(string: "tron://pair?host=1.2.3.4&port=abc&token=t"))
        #expect(PairingURLBuilder.parse(url) == nil)
    }

    @Test("parse rejects missing token field")
    func parseRejectsMissingTokenField() throws {
        let url = try #require(URL(string: "tron://pair?host=1.2.3.4&port=9847"))
        #expect(PairingURLBuilder.parse(url) == nil)
    }

    @Test("parse returns nil for empty label string")
    func parseEmptyLabelIsNil() throws {
        let url = try #require(URL(string: "tron://pair?host=1.2.3.4&port=9847&token=t&label="))
        let parsed = try #require(PairingURLBuilder.parse(url))
        #expect(parsed.label == nil)
    }

    @Test("parse survives percent-encoded characters in label")
    func percentEncodedLabel() throws {
        let payload = PairingPayload(host: "1.2.3.4", port: 9847, token: "t", label: "Mohsin's Mac")
        let url = try #require(PairingURLBuilder.makeURL(payload))
        let parsed = try #require(PairingURLBuilder.parse(url))
        #expect(parsed.label == "Mohsin's Mac")
    }

    @Test("hostnames (not just IPs) are accepted")
    func hostnameAsHost() throws {
        let payload = PairingPayload(host: "my-mac.tail-scale.ts.net", port: 9847, token: "t", label: nil)
        let url = try #require(PairingURLBuilder.makeURL(payload))
        let parsed = try #require(PairingURLBuilder.parse(url))
        #expect(parsed.host == "my-mac.tail-scale.ts.net")
    }
}
