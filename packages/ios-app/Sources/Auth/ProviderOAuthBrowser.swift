import AuthenticationServices
import Darwin
import Dispatch
import Foundation
import UIKit

struct ProviderOAuthCallbackCapture: Hashable, Sendable {
    let id: String
    let host: String
    let port: UInt16
    let path: String
    var expectedState: String? = nil
}

struct ProviderOAuthCapturedCallback: Hashable, Sendable {
    let url: URL
    let percentEncodedQuery: String
}

enum ProviderOAuthURLPolicy {
    static let maximumAuthorizationURLBytes = 128 * 1_024
    static let maximumRequestBytes = 24 * 1_024
    static let maximumRequestTargetBytes = 16 * 1_024

    static func admitsExternalWebURL(_ url: URL) -> Bool {
        guard url.absoluteString.utf8.count <= maximumAuthorizationURLBytes,
              url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.fragment == nil,
              url.host?.isEmpty == false else { return false }
        return true
    }

    static func callbackCapture(
        authorizationURL: URL,
        gatewayCapture: ProviderOAuthCallbackCapture
    ) -> ProviderOAuthCallbackCapture? {
        guard admitsExternalWebURL(authorizationURL),
              let components = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false) else { return nil }
        let callbackItems = (components.queryItems ?? []).filter {
            $0.name == "redirect_uri" || $0.name == "callback_url"
        }
        let stateItems = (components.queryItems ?? []).filter { $0.name == "state" }
        guard callbackItems.count == 1,
              stateItems.count <= 1,
              let rawCallback = callbackItems[0].value,
              let callbackURL = URL(string: rawCallback),
              callbackURL.scheme?.lowercased() == "http",
              callbackURL.user == nil,
              callbackURL.password == nil,
              callbackURL.query == nil,
              callbackURL.fragment == nil,
              let callbackHost = normalizedLoopbackHost(callbackURL.host),
              let callbackPort = callbackURL.port,
              (1...65_535).contains(callbackPort) else { return nil }
        let path = callbackURL.path.isEmpty ? "/" : callbackURL.path
        guard gatewayCapture.id.utf8.count <= 100,
              gatewayCapture.host == callbackHost,
              Int(gatewayCapture.port) == callbackPort,
              gatewayCapture.path == path,
              path.utf8.count <= 2_048,
              path.hasPrefix("/") else { return nil }
        var admitted = gatewayCapture
        admitted.expectedState = stateItems.first?.value
        return admitted
    }

    private static func validHTTPHeaderName(_ name: Substring) -> Bool {
        !name.isEmpty && name.utf8.allSatisfy { byte in
            switch byte {
            case 48...57, 65...90, 97...122:
                true
            case 33, 35...39, 42, 43, 45, 46, 94, 95, 96, 124, 126:
                true
            default:
                false
            }
        }
    }

    static func admitsBrowserHandoff(_ url: URL, nonce: String) -> Bool {
        url.scheme == "com.tron.mobile.oauth"
            && url.host == "callback"
            && url.path == "/\(nonce)"
            && url.user == nil
            && url.password == nil
            && url.port == nil
            && url.query == nil
            && url.fragment == nil
    }

    static func normalizedLoopbackHost(_ value: String?) -> String? {
        guard let value else { return nil }
        switch value.lowercased() {
        case "localhost": return "localhost"
        case "127.0.0.1": return "127.0.0.1"
        case "::1", "[::1]": return "::1"
        default: return nil
        }
    }

    static func parseRequestTarget(
        _ request: Data,
        capture: ProviderOAuthCallbackCapture
    ) -> ProviderOAuthCapturedCallback? {
        guard request.count <= maximumRequestBytes,
              let text = String(data: request, encoding: .utf8),
              let headerEnd = text.range(of: "\r\n\r\n"),
              headerEnd.upperBound == text.endIndex else { return nil }
        let lines = text[..<headerEnd.lowerBound].components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0] == "GET",
              parts[2] == "HTTP/1.0" || parts[2] == "HTTP/1.1",
              parts[1].utf8.count <= maximumRequestTargetBytes else { return nil }
        let target = String(parts[1])
        guard target.hasPrefix("/"), !target.hasPrefix("//"), !target.contains("#"),
              let components = URLComponents(string: "http://localhost\(target)"),
              components.path == capture.path,
              let query = components.percentEncodedQuery,
              !query.isEmpty,
              query.utf8.count <= maximumRequestTargetBytes else { return nil }
        let queryItems = components.queryItems ?? []
        let codeItems = queryItems.filter { $0.name == "code" }
        let errorItems = queryItems.filter { $0.name == "error" }
        let stateItems = queryItems.filter { $0.name == "state" }
        guard codeItems.count <= 1,
              errorItems.count <= 1,
              stateItems.count <= 1,
              codeItems.count + errorItems.count == 1 else { return nil }
        if let expectedState = capture.expectedState {
            guard stateItems.first?.value == expectedState else { return nil }
        }
        var contentLengthCount = 0
        var hostCount = 0
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { return nil }
            let name = line[..<colon]
            let value = line[line.index(after: colon)...]
            guard validHTTPHeaderName(name),
                  value.utf8.allSatisfy({ $0 == 9 || ($0 >= 32 && $0 != 127) }) else { return nil }
            switch name.lowercased() {
            case "content-length":
                contentLengthCount += 1
                guard contentLengthCount == 1,
                      value.trimmingCharacters(in: .whitespaces) == "0" else { return nil }
            case "transfer-encoding":
                return nil
            case "host":
                hostCount += 1
                guard hostCount == 1,
                      !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            default:
                break
            }
        }
        if parts[2] == "HTTP/1.1", hostCount != 1 { return nil }
        var callback = URLComponents()
        callback.scheme = "http"
        callback.host = capture.host == "::1" ? "::1" : capture.host
        callback.port = Int(capture.port)
        callback.path = capture.path
        callback.percentEncodedQuery = query
        guard let url = callback.url else { return nil }
        return ProviderOAuthCapturedCallback(url: url, percentEncodedQuery: query)
    }
}

final class ProviderOAuthLoopbackListener: @unchecked Sendable {
    enum ListenerError: LocalizedError {
        case unavailable

        var errorDescription: String? {
            "The iPhone could not open the provider callback listener."
        }
    }

    private final class SocketSource {
        let fileDescriptor: Int32
        let source: DispatchSourceRead
        private var cancelled = false

        init(fileDescriptor: Int32, source: DispatchSourceRead) {
            self.fileDescriptor = fileDescriptor
            self.source = source
        }

        func cancel() {
            guard !cancelled else { return }
            cancelled = true
            source.setEventHandler { }
            source.cancel()
        }
    }

    private struct ClientState {
        let socket: SocketSource
        let deadlineID: UUID
        var request = Data()
        var response: Data?
        var responseOffset = 0
        var writeSource: DispatchSourceWrite?
    }

    private enum Lifecycle { case idle, running, stopping, stopped }

    private let capture: ProviderOAuthCallbackCapture
    private let handoffNonce: String
    private let onCapture: @MainActor @Sendable (ProviderOAuthCapturedCallback) -> Void
    private let socketQueue = DispatchQueue(label: "com.tron.mobile.oauth-loopback", qos: .userInitiated)
    private var lifecycle = Lifecycle.idle
    private var listeners: [Int32: SocketSource] = [:]
    private var clients: [Int32: ClientState] = [:]
    private var openDescriptors = Set<Int32>()
    private var pendingStartFailure: CheckedContinuation<Void, Error>?
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var consumed = false

    init(
        capture: ProviderOAuthCallbackCapture,
        handoffNonce: String,
        onCapture: @escaping @MainActor @Sendable (ProviderOAuthCapturedCallback) -> Void
    ) {
        self.capture = capture
        self.handoffNonce = handoffNonce
        self.onCapture = onCapture
    }

    func start() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                socketQueue.async { [self] in startOnQueue(continuation) }
            }
        } onCancel: {
            stop()
        }
        guard !Task.isCancelled else {
            await stopAndWait()
            throw CancellationError()
        }
    }

    func stop() {
        socketQueue.async { [self] in stopOnQueue() }
    }

    func stopAndWait() async {
        await withCheckedContinuation { continuation in
            socketQueue.async { [self] in
                stopOnQueue()
                if lifecycle == .stopped {
                    continuation.resume()
                } else {
                    stopWaiters.append(continuation)
                }
            }
        }
    }

    private func startOnQueue(_ continuation: CheckedContinuation<Void, Error>) {
        guard lifecycle == .idle else {
            continuation.resume(throwing: ListenerError.unavailable)
            return
        }
        let families: [Int32]
        switch capture.host {
        case "localhost": families = [AF_INET, AF_INET6]
        case "127.0.0.1": families = [AF_INET]
        case "::1": families = [AF_INET6]
        default:
            lifecycle = .stopped
            continuation.resume(throwing: ListenerError.unavailable)
            return
        }
        do {
            for family in families {
                let fileDescriptor = try Self.makeBoundSocket(family: family, port: capture.port)
                installListener(fileDescriptor)
            }
            lifecycle = .running
            continuation.resume()
        } catch {
            pendingStartFailure = continuation
            lifecycle = .stopping
            stopOnQueue()
        }
    }

    private func stopOnQueue() {
        guard lifecycle != .stopped else { return }
        lifecycle = .stopping
        for client in clients.values {
            client.writeSource?.cancel()
            client.socket.cancel()
        }
        clients.removeAll()
        for listener in listeners.values { listener.cancel() }
        listeners.removeAll()
        finishStoppingIfPossible()
    }

    /// Network.framework rejects a fixed `requiredLocalEndpoint` listener with
    /// POSIX EINVAL on physical iPhone. A directly bound POSIX socket gives the
    /// callback an actual loopback-only local address instead of exposing the
    /// one-shot HTTP endpoint on Wi-Fi, cellular, or Tailscale interfaces.
    static func makeBoundSocket(family: Int32, port: UInt16) throws -> Int32 {
        guard family == AF_INET || family == AF_INET6 else { throw ListenerError.unavailable }
        let fileDescriptor = Darwin.socket(family, SOCK_STREAM, IPPROTO_TCP)
        guard fileDescriptor >= 0 else { throw ListenerError.unavailable }
        do {
            var reuseAddress: Int32 = 1
            guard setsockopt(
                fileDescriptor,
                SOL_SOCKET,
                SO_REUSEADDR,
                &reuseAddress,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0 else { throw ListenerError.unavailable }
            var noSignal: Int32 = 1
            guard setsockopt(
                fileDescriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSignal,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0 else { throw ListenerError.unavailable }
            if family == AF_INET6 {
                var ipv6Only: Int32 = 1
                guard setsockopt(
                    fileDescriptor,
                    IPPROTO_IPV6,
                    IPV6_V6ONLY,
                    &ipv6Only,
                    socklen_t(MemoryLayout<Int32>.size)
                ) == 0 else { throw ListenerError.unavailable }
            }
            try setNonblocking(fileDescriptor)
            let bound: Int32
            if family == AF_INET {
                var address = sockaddr_in()
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = port.bigEndian
                address.sin_addr = in_addr(s_addr: CFSwapInt32HostToBig(INADDR_LOOPBACK))
                bound = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(fileDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            } else {
                var address = sockaddr_in6()
                address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                address.sin6_family = sa_family_t(AF_INET6)
                address.sin6_port = port.bigEndian
                address.sin6_addr = in6addr_loopback
                bound = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(fileDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                    }
                }
            }
            guard bound == 0, Darwin.listen(fileDescriptor, 4) == 0 else {
                throw ListenerError.unavailable
            }
            return fileDescriptor
        } catch {
            Darwin.close(fileDescriptor)
            throw error
        }
    }

    private static func setNonblocking(_ fileDescriptor: Int32) throws {
        let flags = fcntl(fileDescriptor, F_GETFL, 0)
        guard flags >= 0,
              fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw ListenerError.unavailable
        }
    }

    private func installListener(_ fileDescriptor: Int32) {
        let source = DispatchSource.makeReadSource(
            fileDescriptor: fileDescriptor,
            queue: socketQueue
        )
        let socket = SocketSource(fileDescriptor: fileDescriptor, source: source)
        source.setEventHandler { [weak self] in
            self?.acceptConnections(from: fileDescriptor)
        }
        source.setCancelHandler { [weak self] in
            Darwin.close(fileDescriptor)
            self?.descriptorDidClose(fileDescriptor)
        }
        openDescriptors.insert(fileDescriptor)
        listeners[fileDescriptor] = socket
        source.activate()
    }

    private func acceptConnections(from listenerDescriptor: Int32) {
        guard lifecycle == .running, listeners[listenerDescriptor] != nil else { return }
        while true {
            var peer = sockaddr_storage()
            var peerLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let clientDescriptor = withUnsafeMutablePointer(to: &peer) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(listenerDescriptor, $0, &peerLength)
                }
            }
            if clientDescriptor < 0 {
                guard errno == EAGAIN || errno == EWOULDBLOCK else { stop() ; return }
                return
            }
            guard !consumed, clients.count < 8, Self.isLoopback(peer) else {
                Darwin.close(clientDescriptor)
                continue
            }
            do {
                try Self.setNonblocking(clientDescriptor)
                var noSignal: Int32 = 1
                guard setsockopt(
                    clientDescriptor,
                    SOL_SOCKET,
                    SO_NOSIGPIPE,
                    &noSignal,
                    socklen_t(MemoryLayout<Int32>.size)
                ) == 0 else { throw ListenerError.unavailable }
                installClient(clientDescriptor)
            } catch {
                Darwin.close(clientDescriptor)
            }
        }
    }

    private func installClient(_ fileDescriptor: Int32) {
        let source = DispatchSource.makeReadSource(
            fileDescriptor: fileDescriptor,
            queue: socketQueue
        )
        let socket = SocketSource(fileDescriptor: fileDescriptor, source: source)
        let deadlineID = UUID()
        source.setEventHandler { [weak self] in
            self?.receive(from: fileDescriptor)
        }
        source.setCancelHandler { [weak self] in
            Darwin.close(fileDescriptor)
            self?.descriptorDidClose(fileDescriptor)
        }
        openDescriptors.insert(fileDescriptor)
        clients[fileDescriptor] = ClientState(socket: socket, deadlineID: deadlineID)
        source.activate()
        socketQueue.asyncAfter(deadline: .now() + .seconds(5)) { [weak self] in
            guard let self,
                  let client = clients[fileDescriptor],
                  client.deadlineID == deadlineID,
                  client.response == nil else { return }
            reject(fileDescriptor, status: 408)
        }
    }

    private func receive(from fileDescriptor: Int32) {
        guard lifecycle == .running, let existing = clients[fileDescriptor] else {
            closeClient(fileDescriptor)
            return
        }
        guard !consumed, existing.response == nil else { return }
        var client = existing
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.recv(fileDescriptor, $0.baseAddress, $0.count, 0)
            }
            if count > 0 {
                client.request.append(contentsOf: buffer.prefix(count))
                if client.request.count > ProviderOAuthURLPolicy.maximumRequestBytes {
                    clients[fileDescriptor] = client
                    reject(fileDescriptor, status: 413)
                    return
                }
                if client.request.range(of: Data("\r\n\r\n".utf8)) != nil {
                    clients[fileDescriptor] = client
                    process(fileDescriptor, request: client.request)
                    return
                }
                continue
            }
            if count == 0 {
                clients[fileDescriptor] = client
                reject(fileDescriptor, status: 400)
                return
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                clients[fileDescriptor] = client
                return
            }
            clients[fileDescriptor] = client
            reject(fileDescriptor, status: 400)
            return
        }
    }

    private func process(_ fileDescriptor: Int32, request: Data) {
        guard !consumed,
              let callback = ProviderOAuthURLPolicy.parseRequestTarget(request, capture: capture) else {
            reject(fileDescriptor, status: 400)
            return
        }
        consumed = true
        DispatchQueue.main.sync {
            MainActor.assumeIsolated { onCapture(callback) }
        }
        let location = "com.tron.mobile.oauth://callback/\(handoffNonce)"
        queueResponse(fileDescriptor, statusLine: "302 Found", location: location)
        let otherClients = clients.keys.filter { $0 != fileDescriptor }
        for descriptor in otherClients { closeClient(descriptor) }
        for listener in listeners.values { listener.cancel() }
        listeners.removeAll()
    }

    private func reject(_ fileDescriptor: Int32, status: Int) {
        guard clients[fileDescriptor] != nil else { return }
        queueResponse(fileDescriptor, statusLine: "\(status) Invalid Request", location: nil)
    }

    private func queueResponse(_ fileDescriptor: Int32, statusLine: String, location: String?) {
        guard var client = clients[fileDescriptor], client.response == nil else { return }
        let locationHeader = location.map { "Location: \($0)\r\n" } ?? ""
        client.response = Data(
            "HTTP/1.1 \(statusLine)\r\n\(locationHeader)Cache-Control: no-store\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8
        )
        let source = DispatchSource.makeWriteSource(
            fileDescriptor: fileDescriptor,
            queue: socketQueue
        )
        source.setEventHandler { [weak self] in self?.flushResponse(fileDescriptor) }
        client.writeSource = source
        clients[fileDescriptor] = client
        source.activate()
    }

    private func flushResponse(_ fileDescriptor: Int32) {
        guard var client = clients[fileDescriptor], let response = client.response else { return }
        while client.responseOffset < response.count {
            let sent = response.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return 0 }
                return Darwin.send(
                    fileDescriptor,
                    baseAddress.advanced(by: client.responseOffset),
                    bytes.count - client.responseOffset,
                    0
                )
            }
            if sent < 0, errno == EINTR { continue }
            if sent < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                clients[fileDescriptor] = client
                return
            }
            guard sent > 0 else {
                closeClient(fileDescriptor)
                return
            }
            client.responseOffset += sent
        }
        clients[fileDescriptor] = client
        _ = Darwin.shutdown(fileDescriptor, SHUT_WR)
        closeClient(fileDescriptor)
    }

    private func closeClient(_ fileDescriptor: Int32) {
        guard let client = clients.removeValue(forKey: fileDescriptor) else { return }
        client.writeSource?.cancel()
        client.socket.cancel()
    }

    private func descriptorDidClose(_ fileDescriptor: Int32) {
        openDescriptors.remove(fileDescriptor)
        finishStoppingIfPossible()
    }

    private func finishStoppingIfPossible() {
        guard lifecycle == .stopping, openDescriptors.isEmpty else { return }
        lifecycle = .stopped
        let startFailure = pendingStartFailure
        pendingStartFailure = nil
        let waiters = stopWaiters
        stopWaiters.removeAll()
        startFailure?.resume(throwing: ListenerError.unavailable)
        for waiter in waiters { waiter.resume() }
    }

    private static func isLoopback(_ address: sockaddr_storage) -> Bool {
        switch Int32(address.ss_family) {
        case AF_INET:
            var address = address
            return withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee.sin_addr.s_addr == CFSwapInt32HostToBig(INADDR_LOOPBACK)
                }
            }
        case AF_INET6:
            var address = address
            var loopback = in6addr_loopback
            return withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { ipv6 in
                    var candidate = ipv6.pointee.sin6_addr
                    return withUnsafePointer(to: &candidate) { actual in
                        withUnsafePointer(to: &loopback) { expected in
                            memcmp(actual, expected, MemoryLayout<in6_addr>.size) == 0
                        }
                    }
                }
            }
        default:
            return false
        }
    }
}

@MainActor
final class ProviderOAuthBrowserSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    enum BrowserError: LocalizedError {
        case invalidAuthorizationURL
        case unavailable
        case invalidHandoff
        case missingCallback

        var errorDescription: String? {
            switch self {
            case .invalidAuthorizationURL: "Tron rejected an invalid provider authorization URL."
            case .unavailable: "Provider login could not open on this iPhone."
            case .invalidHandoff: "The provider returned an invalid login handoff."
            case .missingCallback: "The provider login returned without an authorization callback."
            }
        }
    }

    private var webSession: ASWebAuthenticationSession?
    private var listener: ProviderOAuthLoopbackListener?
    private var captured: ProviderOAuthCapturedCallback?
    private var activeGeneration: UUID?
    private weak var presentationWindowScene: UIWindowScene?

    var isRunning: Bool { webSession != nil }

    func start(
        authorizationURL: URL,
        capture: ProviderOAuthCallbackCapture,
        onComplete: @escaping @MainActor (ProviderOAuthCapturedCallback) -> Void,
        onCancel: @escaping @MainActor () -> Void,
        onError: @escaping @MainActor (Error) -> Void
    ) async throws {
        let previousListener = retireCurrentSession()
        let generation = UUID()
        activeGeneration = generation
        if let previousListener { await previousListener.stopAndWait() }
        guard activeGeneration == generation, !Task.isCancelled else {
            throw CancellationError()
        }
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            activeGeneration = nil
            throw BrowserError.unavailable
        }
        presentationWindowScene = windowScene
        guard let admittedCapture = ProviderOAuthURLPolicy.callbackCapture(
            authorizationURL: authorizationURL,
            gatewayCapture: capture
        ) else {
            activeGeneration = nil
            presentationWindowScene = nil
            throw BrowserError.invalidAuthorizationURL
        }
        let nonce = UUID().uuidString.lowercased()
        captured = nil
        let listener = ProviderOAuthLoopbackListener(capture: admittedCapture, handoffNonce: nonce) { [weak self] callback in
            guard let self, self.activeGeneration == generation else { return }
            self.captured = callback
        }
        self.listener = listener
        do { try await listener.start() }
        catch {
            guard activeGeneration == generation else { throw CancellationError() }
            let retired = retireCurrentSession()
            if let retired { await retired.stopAndWait() }
            throw error
        }
        guard activeGeneration == generation, !Task.isCancelled else {
            await listener.stopAndWait()
            throw CancellationError()
        }
        let session = ASWebAuthenticationSession(
            url: authorizationURL,
            callbackURLScheme: "com.tron.mobile.oauth"
        ) { [weak self] callbackURL, error in
            Task { @MainActor in
                guard let self, self.activeGeneration == generation else { return }
                if let error,
                   (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                    self.finish(generation: generation)
                    onCancel()
                    return
                }
                if let error {
                    self.finish(generation: generation)
                    onError(error)
                    return
                }
                guard let callbackURL,
                      ProviderOAuthURLPolicy.admitsBrowserHandoff(callbackURL, nonce: nonce) else {
                    self.finish(generation: generation)
                    onError(BrowserError.invalidHandoff)
                    return
                }
                guard let captured = self.captured else {
                    self.finish(generation: generation)
                    onError(BrowserError.missingCallback)
                    return
                }
                self.finish(generation: generation)
                onComplete(captured)
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        webSession = session
        guard session.start() else {
            let retired = retireCurrentSession()
            if let retired { await retired.stopAndWait() }
            throw BrowserError.unavailable
        }
    }

    func cancel() {
        retireCurrentSession()?.stop()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        guard let windowScene = presentationWindowScene else {
            preconditionFailure("Provider browser started without a presentation scene")
        }
        return windowScene.windows.first(where: \.isKeyWindow)
            ?? ASPresentationAnchor(windowScene: windowScene)
    }

    private func finish(generation: UUID) {
        guard activeGeneration == generation else { return }
        retireCurrentSession()?.stop()
    }

    @discardableResult
    private func retireCurrentSession() -> ProviderOAuthLoopbackListener? {
        activeGeneration = nil
        webSession?.cancel()
        webSession = nil
        let retiredListener = listener
        listener = nil
        captured = nil
        presentationWindowScene = nil
        return retiredListener
    }
}
