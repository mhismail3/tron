import Foundation
import Testing
@testable import TronMac

private func queryValue(_ name: String, in url: URL) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?
        .first(where: { $0.name == name })?
        .value
}

/// Tests the Mac-owned `tron://pair` emitter. Runtime parsing belongs to the
/// iOS `PairingURLParser`, so these assertions inspect emitted URL fields
/// without introducing a second production parser.
@Suite("PairingURLBuilder")
struct PairingURLBuilderTests {
    @Test("required fields are emitted for iOS")
    func emitsRequiredFields() throws {
        let payload = PairingPayload(host: "100.64.0.1", port: 9847, token: "abc123xyz", label: nil)
        let url = try #require(PairingURLBuilder.makeURL(payload))

        #expect(url.scheme == "tron")
        #expect(url.host == "pair")
        #expect(queryValue("host", in: url) == payload.host)
        #expect(queryValue("port", in: url) == "9847")
        #expect(queryValue("token", in: url) == payload.token)
        #expect(queryValue("label", in: url) == nil)
    }

    @Test("server name label is emitted")
    func emitsLabel() throws {
        let payload = PairingPayload(host: "100.64.0.1", port: 9847, token: "tok", label: "Studio Mac")
        let url = try #require(PairingURLBuilder.makeURL(payload))
        #expect(queryValue("label", in: url) == "Studio Mac")
    }

    @Test("blank server name label is omitted")
    func omitsBlankLabel() throws {
        let payload = PairingPayload(host: "100.64.0.1", port: 9847, token: "tok", label: "  \n")
        let url = try #require(PairingURLBuilder.makeURL(payload))
        #expect(queryValue("label", in: url) == nil)
    }

    @Test("trailing whitespace in host/token is trimmed")
    func whitespaceTrimming() throws {
        let payload = PairingPayload(host: "  100.64.0.1\n", port: 9847, token: "\ttok  ", label: nil)
        let url = try #require(PairingURLBuilder.makeURL(payload))
        #expect(queryValue("host", in: url) == "100.64.0.1")
        #expect(queryValue("token", in: url) == "tok")
    }

    @Test("empty host rejected")
    func emptyHostRejected() {
        let payload = PairingPayload(host: "", port: 9847, token: "tok", label: nil)
        #expect(PairingURLBuilder.makeURL(payload) == nil)
    }

    @Test("whitespace-only host rejected")
    func whitespaceOnlyHostRejected() {
        let payload = PairingPayload(host: "   \n\t", port: 9847, token: "tok", label: nil)
        #expect(PairingURLBuilder.makeURL(payload) == nil)
    }

    @Test("empty token rejected")
    func emptyTokenRejected() {
        let payload = PairingPayload(host: "100.64.0.1", port: 9847, token: "", label: nil)
        #expect(PairingURLBuilder.makeURL(payload) == nil)
    }

    @Test("zero, negative, and oversized ports are rejected")
    func invalidPortRejected() {
        #expect(PairingURLBuilder.makeURL(PairingPayload(host: "1.2.3.4", port: 0, token: "t", label: nil)) == nil)
        #expect(PairingURLBuilder.makeURL(PairingPayload(host: "1.2.3.4", port: -1, token: "t", label: nil)) == nil)
        #expect(PairingURLBuilder.makeURL(PairingPayload(host: "1.2.3.4", port: 65_536, token: "t", label: nil)) == nil)
    }

    @Test("port boundaries match the iOS parser")
    func portBoundaries() throws {
        let payload = PairingPayload(host: "1.2.3.4", port: 65_535, token: "t", label: nil)
        let url = try #require(PairingURLBuilder.makeURL(payload))
        #expect(queryValue("port", in: url) == "65535")
    }

    @Test("percent-encoded label characters retain their value")
    func percentEncodedLabel() throws {
        let payload = PairingPayload(host: "1.2.3.4", port: 9847, token: "t", label: "Studio's Mac")
        let url = try #require(PairingURLBuilder.makeURL(payload))
        #expect(queryValue("label", in: url) == "Studio's Mac")
    }

    @Test("hostnames are canonicalized for iOS")
    func hostnameAsHost() throws {
        let payload = PairingPayload(host: "My-Mac.Tail-Scale.Ts.Net.", port: 9847, token: "t", label: nil)
        let url = try #require(PairingURLBuilder.makeURL(payload))
        #expect(queryValue("host", in: url) == "my-mac.tail-scale.ts.net")
    }

    @Test("IPv6 host is emitted unbracketed")
    func ipv6HostAccepted() throws {
        let payload = PairingPayload(host: "FD7A:115C:A1E0::1", port: 9847, token: "t", label: nil)
        let url = try #require(PairingURLBuilder.makeURL(payload))
        #expect(queryValue("host", in: url) == "fd7a:115c:a1e0::1")
    }

    @Test("full URL, path, userinfo, bracketed host, and invalid IP are rejected")
    func malformedHostsRejected() {
        for host in [
            "https://100.64.0.1",
            "100.64.0.1/engine",
            "user@100.64.0.1",
            "[fd7a:115c:a1e0::1]",
            "999.1.1.1",
            "mac..tailnet.ts.net",
        ] {
            #expect(
                PairingURLBuilder.makeURL(PairingPayload(host: host, port: 9847, token: "t", label: nil)) == nil,
                "expected \(host) to be rejected"
            )
        }
    }
}
