import Darwin
import Foundation
import Testing
@testable import TronMobile

@Suite("Provider OAuth browser callback policy")
struct ProviderOAuthBrowserTests {
    @MainActor
    @Test("fixed IPv4 and IPv6 loopback sockets bind the same port")
    func fixedEndpointSocketBinding() throws {
        let ipv4 = try ProviderOAuthLoopbackListener.makeBoundSocket(family: AF_INET, port: 0)
        defer { Darwin.close(ipv4) }
        let port = try boundPort(ipv4, family: AF_INET)
        #expect(port > 0)
        do {
            let duplicate = try ProviderOAuthLoopbackListener.makeBoundSocket(family: AF_INET, port: port)
            Darwin.close(duplicate)
            Issue.record("A second listener claimed the same IPv4 loopback port")
        } catch { }

        let ipv6 = try ProviderOAuthLoopbackListener.makeBoundSocket(family: AF_INET6, port: port)
        defer { Darwin.close(ipv6) }
        #expect(try boundPort(ipv6, family: AF_INET6) == port)
    }

    @MainActor
    @Test("repeated listener cancellation releases the fixed port before restart")
    func repeatedCancellationAndRebind() async throws {
        let reservation = try ProviderOAuthLoopbackListener.makeBoundSocket(family: AF_INET, port: 0)
        let port = try boundPort(reservation, family: AF_INET)
        Darwin.close(reservation)
        let capture = ProviderOAuthCallbackCapture(
            id: "capture",
            host: "127.0.0.1",
            port: port,
            path: "/auth/callback"
        )

        for iteration in 0..<20 {
            let listener = ProviderOAuthLoopbackListener(
                capture: capture,
                handoffNonce: "nonce-\(iteration)"
            ) { _ in }
            try await listener.start()
            await listener.stopAndWait()
        }

        let rebound = try ProviderOAuthLoopbackListener.makeBoundSocket(family: AF_INET, port: port)
        Darwin.close(rebound)
    }

    @MainActor
    @Test("one-shot listener accepts fragmented exact-path callback and releases its port")
    func oneShotListenerRoundTrip() async throws {
        let reservation = try ProviderOAuthLoopbackListener.makeBoundSocket(family: AF_INET, port: 0)
        let port = try boundPort(reservation, family: AF_INET)
        Darwin.close(reservation)

        var captured: ProviderOAuthCapturedCallback?
        var capture = ProviderOAuthCallbackCapture(
            id: "capture",
            host: "127.0.0.1",
            port: port,
            path: "/auth/callback"
        )
        capture.expectedState = "expected"
        let listener = ProviderOAuthLoopbackListener(
            capture: capture,
            handoffNonce: "handoff-nonce"
        ) { callback in
            captured = callback
        }
        try await listener.start()

        let invalid = try await sendLoopbackRequestAsync(
            port: port,
            fragments: [Data("GET /wrong?code=nope&state=expected HTTP/1.1\r\n\r\n".utf8)]
        )
        #expect(String(decoding: invalid, as: UTF8.self).contains("400 Invalid Request"))

        let response = try await sendLoopbackRequestAsync(
            port: port,
            fragments: [
                Data("GET /auth/callback?code=temporary".utf8),
                Data("&state=expected HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8),
            ]
        )
        let responseText = String(decoding: response, as: UTF8.self)
        #expect(responseText.contains("302 Found"))
        #expect(responseText.contains("Location: com.tron.mobile.oauth://callback/handoff-nonce"))
        #expect(!responseText.contains("temporary"))
        #expect(captured?.percentEncodedQuery == "code=temporary&state=expected")

        await listener.stopAndWait()
        let rebound = try ProviderOAuthLoopbackListener.makeBoundSocket(family: AF_INET, port: port)
        Darwin.close(rebound)
    }

    @Test("browser handoff admits only the exact nonce URL without data")
    func browserHandoffPolicy() throws {
        let nonce = "expected-nonce"
        #expect(ProviderOAuthURLPolicy.admitsBrowserHandoff(
            try #require(URL(string: "com.tron.mobile.oauth://callback/expected-nonce")),
            nonce: nonce
        ))
        let rejected = [
            "com.tron.mobile.oauth://callback/wrong",
            "com.tron.mobile.oauth://callback/expected-nonce?code=temporary",
            "com.tron.mobile.oauth://callback/expected-nonce#fragment",
            "com.tron.mobile.oauth://user@callback/expected-nonce",
            "com.tron.mobile.oauth://callback:123/expected-nonce",
            "other.scheme://callback/expected-nonce",
        ]
        for rawURL in rejected {
            #expect(!ProviderOAuthURLPolicy.admitsBrowserHandoff(
                try #require(URL(string: rawURL)),
                nonce: nonce
            ))
        }
    }

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
            "GET /oauth/callback?code=one&error=denied HTTP/1.1\r\nHost: localhost\r\n\r\n",
            "GET /oauth/callback?code=x HTTP/1.9\r\nHost: localhost\r\n\r\n",
            "GET /oauth/callback?code=x HTTP/1.1\r\n\r\n",
            "GET /oauth/callback?code=x HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n",
            "GET /oauth/callback?code=x HTTP/1.1\r\nHost localhost\r\n\r\n",
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

    private func boundPort(_ fileDescriptor: Int32, family: Int32) throws -> UInt16 {
        if family == AF_INET {
            var address = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let result = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.getsockname(fileDescriptor, $0, &length)
                }
            }
            #expect(result == 0)
            #expect(address.sin_addr.s_addr == CFSwapInt32HostToBig(INADDR_LOOPBACK))
            return address.sin_port.bigEndian
        }

        var address = sockaddr_in6()
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fileDescriptor, $0, &length)
            }
        }
        #expect(result == 0)
        var actual = address.sin6_addr
        var expected = in6addr_loopback
        #expect(withUnsafePointer(to: &actual) { actualPointer in
            withUnsafePointer(to: &expected) { expectedPointer in
                memcmp(actualPointer, expectedPointer, MemoryLayout<in6_addr>.size) == 0
            }
        })
        return address.sin6_port.bigEndian
    }
}

private enum LoopbackSocketTestError: Error {
    case syscall(Int32)
}

private func sendLoopbackRequestAsync(port: UInt16, fragments: [Data]) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
        Thread.detachNewThread {
            do { continuation.resume(returning: try sendLoopbackRequest(port: port, fragments: fragments)) }
            catch { continuation.resume(throwing: error) }
        }
    }
}

private func sendLoopbackRequest(port: UInt16, fragments: [Data]) throws -> Data {
    let fileDescriptor = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    guard fileDescriptor >= 0 else { throw LoopbackSocketTestError.syscall(errno) }
    defer { Darwin.close(fileDescriptor) }

    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    guard setsockopt(
        fileDescriptor,
        SOL_SOCKET,
        SO_RCVTIMEO,
        &timeout,
        socklen_t(MemoryLayout<timeval>.size)
    ) == 0 else { throw LoopbackSocketTestError.syscall(errno) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: CFSwapInt32HostToBig(INADDR_LOOPBACK))
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fileDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else { throw LoopbackSocketTestError.syscall(errno) }

    for fragment in fragments {
        try fragment.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let sent = Darwin.send(
                    fileDescriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset,
                    0
                )
                guard sent > 0 else { throw LoopbackSocketTestError.syscall(errno) }
                offset += sent
            }
        }
    }
    _ = Darwin.shutdown(fileDescriptor, SHUT_WR)

    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 1_024)
    while true {
        let count = buffer.withUnsafeMutableBytes {
            Darwin.recv(fileDescriptor, $0.baseAddress, $0.count, 0)
        }
        if count > 0 {
            response.append(contentsOf: buffer.prefix(count))
            if response.range(of: Data("\r\n\r\n".utf8)) != nil { return response }
        } else if count == 0 {
            return response
        } else if errno == EINTR {
            continue
        } else {
            throw LoopbackSocketTestError.syscall(errno)
        }
    }
}
