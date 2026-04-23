import Testing
@testable import TronMobile

/// `PairingURLParser` is the single deep-link / paste / QR surface for
/// the onboarding & re-pair flows (Phase 3.6 + 4). These tests pin down
/// the strict-validation contract — anything that ships through this
/// parser later runs against the user's Keychain, so silent failures
/// would land bad tokens in production.
@Suite("PairingURLParser")
struct PairingURLParserTests {

    // MARK: - Happy path

    @Test("Parses a fully-populated tron://pair URL")
    func parsesHappyPath() {
        let url = "tron://pair?host=100.64.0.1&port=9847&token=abc123"
        let result = PairingURLParser.parse(url)
        #expect(result == .success(.init(host: "100.64.0.1", port: 9847, token: "abc123", label: nil)))
    }

    @Test("Tolerates leading/trailing whitespace from clipboard pastes")
    func trimsWhitespace() {
        let url = "  tron://pair?host=h&port=1&token=t\n"
        if case .success(let payload) = PairingURLParser.parse(url) {
            #expect(payload.host == "h")
            #expect(payload.port == 1)
            #expect(payload.token == "t")
        } else {
            Issue.record("expected success")
        }
    }

    @Test("Optional label is round-tripped")
    func roundTripsLabel() {
        let url = PairingURLParser.makeURL(host: "1.2.3.4", port: 9847, token: "tok", label: "My Mac")!
        if case .success(let payload) = PairingURLParser.parse(url.absoluteString) {
            #expect(payload.label == "My Mac")
        } else {
            Issue.record("expected success with label")
        }
    }

    @Test("Unrecognized query parameters are dropped (forward-compat)")
    func ignoresUnknownParams() {
        let url = "tron://pair?host=h&port=9&token=t&futureFlag=enabled"
        #expect((try? PairingURLParser.parse(url).get()) != nil)
    }

    @Test("Round-trip through makeURL preserves all required fields")
    func roundTripsRequiredFields() {
        let original = PairingURLParser.PairingPayload(
            host: "100.64.213.113", port: 9847, token: "AbC-_xyz123", label: nil
        )
        let url = PairingURLParser.makeURL(host: original.host, port: original.port, token: original.token)!
        let parsed = try? PairingURLParser.parse(url.absoluteString).get()
        #expect(parsed == original)
    }

    // MARK: - Schemes & hosts

    @Test("Rejects non-tron schemes")
    func rejectsWrongScheme() {
        let result = PairingURLParser.parse("https://pair?host=h&port=1&token=t")
        if case .failure(let err) = result {
            #expect(err == .wrongScheme("https"))
        } else { Issue.record("expected scheme rejection") }
    }

    @Test("Rejects tron URLs that aren't on the pair host")
    func rejectsWrongHostComponent() {
        let result = PairingURLParser.parse("tron://session/abc?host=h&port=1&token=t")
        if case .failure(let err) = result {
            if case .wrongHostComponent = err {
                // ok
            } else {
                Issue.record("expected wrongHostComponent, got \(err)")
            }
        } else { Issue.record("expected failure") }
    }

    @Test("Scheme matching is case-insensitive")
    func acceptsMixedCaseScheme() {
        #expect((try? PairingURLParser.parse("TRON://pair?host=h&port=1&token=t").get()) != nil)
    }

    // MARK: - Missing fields

    @Test("Missing host classified as missingHost")
    func missingHostClassified() {
        let result = PairingURLParser.parse("tron://pair?port=1&token=t")
        if case .failure(let err) = result {
            #expect(err == .missingHost)
        } else { Issue.record("expected missingHost") }
    }

    @Test("Missing port classified as missingPort")
    func missingPortClassified() {
        let result = PairingURLParser.parse("tron://pair?host=h&token=t")
        if case .failure(let err) = result {
            #expect(err == .missingPort)
        } else { Issue.record("expected missingPort") }
    }

    @Test("Missing token classified as missingToken")
    func missingTokenClassified() {
        let result = PairingURLParser.parse("tron://pair?host=h&port=1")
        if case .failure(let err) = result {
            #expect(err == .missingToken)
        } else { Issue.record("expected missingToken") }
    }

    @Test("Empty values count as missing")
    func emptyValuesAreMissing() {
        let result = PairingURLParser.parse("tron://pair?host=&port=1&token=t")
        if case .failure(let err) = result {
            #expect(err == .missingHost)
        } else { Issue.record("expected missingHost") }
    }

    // MARK: - Port validation

    @Test("Non-numeric port is invalidPort")
    func nonNumericPortRejected() {
        let result = PairingURLParser.parse("tron://pair?host=h&port=abc&token=t")
        if case .failure(let err) = result {
            #expect(err == .invalidPort("abc"))
        } else { Issue.record("expected invalidPort") }
    }

    @Test("Out-of-range port is invalidPort")
    func outOfRangePortRejected() {
        let result = PairingURLParser.parse("tron://pair?host=h&port=99999&token=t")
        if case .failure(let err) = result {
            #expect(err == .invalidPort("99999"))
        } else { Issue.record("expected invalidPort") }
    }

    @Test("Zero port is rejected")
    func zeroPortRejected() {
        let result = PairingURLParser.parse("tron://pair?host=h&port=0&token=t")
        if case .failure(let err) = result {
            #expect(err == .invalidPort("0"))
        } else { Issue.record("expected invalidPort for 0") }
    }

    // MARK: - Malformed URLs

    @Test("Garbage input returns malformedURL or wrongScheme")
    func garbageRejected() {
        // URLComponents accepts a lot, so the practical guarantee is "doesn't succeed".
        let result = PairingURLParser.parse("not a url at all")
        switch result {
        case .success: Issue.record("garbage parsed as success")
        case .failure: break
        }
    }
}
