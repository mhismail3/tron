import Foundation
import Testing
@testable import TronMobile

@Suite("Provider OAuth browser callback policy")
struct ProviderOAuthBrowserTests {
    @Test("built-in loopback callback descriptors are admitted")
    func builtInDescriptors() throws {
        let cases: [(String, String, UInt16, String)] = [
            (
                "https://claude.ai/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A53692%2Fcallback&state=verifier",
                "localhost", 53_692, "/callback"
            ),
            (
                "https://auth.openai.com/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&state=random",
                "localhost", 1_455, "/auth/callback"
            ),
            (
                "https://openrouter.ai/auth?callback_url=http%3A%2F%2F127.0.0.1%3A49152%2Foauth%2Fcallback%2Fnonce",
                "127.0.0.1", 49_152, "/oauth/callback/nonce"
            ),
            (
                "https://radius.example/authorize?redirect_uri=http%3A%2F%2F127.0.0.1%3A1456%2Foauth%2Fcallback&state=random",
                "127.0.0.1", 1_456, "/oauth/callback"
            ),
        ]

        for (rawURL, host, port, path) in cases {
            let gateway = ProviderOAuthCallbackCapture(id: "capture", host: host, port: port, path: path)
            let result = ProviderOAuthURLPolicy.callbackCapture(
                authorizationURL: try #require(URL(string: rawURL)),
                gatewayCapture: gateway
            )
            #expect(result?.id == gateway.id)
            #expect(result?.host == host)
            #expect(result?.port == port)
            #expect(result?.path == path)
            #expect(result?.expectedState == (rawURL.contains("state=") ? (rawURL.contains("verifier") ? "verifier" : "random") : nil))
        }
    }

    @Test("callback descriptor cannot select a non-loopback or mismatched destination")
    func rejectsUntrustedDestinations() throws {
        let external = try #require(URL(string:
            "https://provider.example/authorize?redirect_uri=http%3A%2F%2F192.168.1.4%3A1455%2Fcallback"
        ))
        let plausible = ProviderOAuthCallbackCapture(
            id: "capture", host: "127.0.0.1", port: 1_455, path: "/callback"
        )
        #expect(ProviderOAuthURLPolicy.callbackCapture(
            authorizationURL: external,
            gatewayCapture: plausible
        ) == nil)

        let valid = try #require(URL(string:
            "https://provider.example/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fcallback"
        ))
        let wrongPort = ProviderOAuthCallbackCapture(
            id: "capture", host: "localhost", port: 1_456, path: "/callback"
        )
        #expect(ProviderOAuthURLPolicy.callbackCapture(
            authorizationURL: valid,
            gatewayCapture: wrongPort
        ) == nil)
        #expect(!ProviderOAuthURLPolicy.admitsExternalWebURL(
            try #require(URL(string: "http://provider.example/authorize"))
        ))
        #expect(!ProviderOAuthURLPolicy.admitsExternalWebURL(
            try #require(URL(string: "file:///tmp/callback"))
        ))
    }

    @Test("HTTP callback parser preserves the full encoded query and exact destination")
    func parsesExactRequest() throws {
        let capture = ProviderOAuthCallbackCapture(
            id: "capture", host: "localhost", port: 1_455, path: "/auth/callback"
        )
        let request = Data(
            "GET /auth/callback?code=a%2Bb&state=expected HTTP/1.1\r\nHost: localhost:1455\r\nContent-Length: 0\r\n\r\n".utf8
        )
        let callback = try #require(ProviderOAuthURLPolicy.parseRequestTarget(request, capture: capture))
        #expect(callback.percentEncodedQuery == "code=a%2Bb&state=expected")
        #expect(callback.url.host == "localhost")
        #expect(callback.url.port == 1_455)
        #expect(callback.url.path == "/auth/callback")
        #expect(URLComponents(url: callback.url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value == "a+b")
    }

    @Test("HTTP callback parser rejects wrong routes, bodies, absolute targets and missing results")
    func rejectsMalformedRequests() {
        let capture = ProviderOAuthCallbackCapture(
            id: "capture", host: "127.0.0.1", port: 1_456, path: "/oauth/callback"
        )
        let invalid = [
            "POST /oauth/callback?code=x HTTP/1.1\r\n\r\n",
            "GET /other?code=x HTTP/1.1\r\n\r\n",
            "GET http://attacker.invalid/oauth/callback?code=x HTTP/1.1\r\n\r\n",
            "GET /oauth/callback?state=x HTTP/1.1\r\n\r\n",
            "GET /oauth/callback?code=x HTTP/1.1\r\nContent-Length: 1\r\n\r\nx",
            "GET /oauth/callback?code=x#fragment HTTP/1.1\r\n\r\n",
            "GET /oauth/callback?code=one&code=two HTTP/1.1\r\n\r\n",
            "GET /oauth/callback?error=denied&error=again HTTP/1.1\r\n\r\n",
        ]
        for request in invalid {
            #expect(ProviderOAuthURLPolicy.parseRequestTarget(Data(request.utf8), capture: capture) == nil)
        }
        var stateful = capture
        stateful.expectedState = "expected"
        #expect(ProviderOAuthURLPolicy.parseRequestTarget(
            Data("GET /oauth/callback?code=x&state=wrong HTTP/1.1\r\n\r\n".utf8),
            capture: stateful
        ) == nil)
    }

    @Test("IPv6 loopback callbacks round trip without accepting other IPv6 hosts")
    func ipv6Loopback() throws {
        let capture = ProviderOAuthCallbackCapture(
            id: "capture", host: "::1", port: 9_999, path: "/callback"
        )
        let authorization = try #require(URL(string:
            "https://provider.example/auth?redirect_uri=http%3A%2F%2F%5B%3A%3A1%5D%3A9999%2Fcallback"
        ))
        let admitted = ProviderOAuthURLPolicy.callbackCapture(
            authorizationURL: authorization,
            gatewayCapture: capture
        )
        #expect(admitted?.host == "::1")
        #expect(admitted?.port == 9_999)
        #expect(ProviderOAuthURLPolicy.normalizedLoopbackHost("::2") == nil)
    }
}
