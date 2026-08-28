import AuthenticationServices
import Foundation
import Network
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
              parts[2].hasPrefix("HTTP/1."),
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
              codeItems.count + errorItems.count >= 1 else { return nil }
        if let expectedState = capture.expectedState {
            guard stateItems.first?.value == expectedState else { return nil }
        }
        for line in lines.dropFirst() {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                guard value == "0" else { return nil }
            }
            if lower.hasPrefix("transfer-encoding:") { return nil }
        }
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

@MainActor
final class ProviderOAuthLoopbackListener {
    enum ListenerError: LocalizedError {
        case unavailable
        case cancelled
        case timedOut

        var errorDescription: String? {
            switch self {
            case .unavailable: "The iPhone could not open the provider callback listener."
            case .cancelled: "Provider login was cancelled."
            case .timedOut: "The provider callback listener did not become ready."
            }
        }
    }

    private let capture: ProviderOAuthCallbackCapture
    private let handoffNonce: String
    private let onCapture: @MainActor (ProviderOAuthCapturedCallback) -> Void
    private var listeners: [NWListener] = []
    private var connections: [NWConnection] = []
    private var startupContinuation: CheckedContinuation<Void, Error>?
    private var pendingStartupResult: Result<Void, Error>?
    private var startupTimeout: Task<Void, Never>?
    private var terminalListenerIDs = Set<ObjectIdentifier>()
    private var ready = false
    private var consumed = false

    init(
        capture: ProviderOAuthCallbackCapture,
        handoffNonce: String,
        onCapture: @escaping @MainActor (ProviderOAuthCapturedCallback) -> Void
    ) {
        self.capture = capture
        self.handoffNonce = handoffNonce
        self.onCapture = onCapture
    }

    func start() async throws {
        guard listeners.isEmpty else { return }
        guard let port = NWEndpoint.Port(rawValue: capture.port) else { throw ListenerError.unavailable }
        let hosts: [NWEndpoint.Host]
        switch capture.host {
        case "localhost": hosts = ["127.0.0.1", "::1"]
        case "127.0.0.1": hosts = ["127.0.0.1"]
        case "::1": hosts = ["::1"]
        default: throw ListenerError.unavailable
        }
        do {
            for host in hosts {
                let parameters = NWParameters.tcp
                // Never opt into port sharing: the authorization callback must
                // have one process owner. IPv4 and IPv6 use distinct loopback
                // local endpoints even though the numeric port is equal.
                parameters.allowLocalEndpointReuse = false
                parameters.requiredLocalEndpoint = .hostPort(host: host, port: port)
                let listener = try NWListener(using: parameters, on: port)
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    Task { @MainActor in self?.handle(state, listener: listener) }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    Task { @MainActor in self?.accept(connection) }
                }
                listeners.append(listener)
                listener.start(queue: .global(qos: .userInitiated))
            }
        } catch {
            stop()
            throw error
        }
        startupTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, !self.ready else { return }
            self.finishStartup(.failure(ListenerError.timedOut))
            self.stop()
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                startupContinuation = continuation
                if let pendingStartupResult {
                    self.pendingStartupResult = nil
                    finishStartup(pendingStartupResult)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishStartup(.failure(ListenerError.cancelled))
                self?.stop()
            }
        }
    }

    func stop() {
        startupTimeout?.cancel()
        startupTimeout = nil
        for connection in connections { connection.cancel() }
        connections.removeAll()
        for listener in listeners {
            listener.stateUpdateHandler = nil
            listener.newConnectionHandler = nil
            listener.cancel()
        }
        listeners.removeAll()
        terminalListenerIDs.removeAll()
        if !ready { finishStartup(.failure(ListenerError.cancelled)) }
    }

    private func handle(_ state: NWListener.State, listener: NWListener?) {
        guard listener != nil else { return }
        switch state {
        case .ready:
            guard !ready else { return }
            ready = true
            finishStartup(.success(()))
        case .failed:
            if let listener { terminalListenerIDs.insert(ObjectIdentifier(listener)) }
            if !ready && terminalListenerIDs.count == listeners.count {
                finishStartup(.failure(ListenerError.unavailable))
                stop()
            }
        case .cancelled:
            if let listener { terminalListenerIDs.insert(ObjectIdentifier(listener)) }
            if !ready && terminalListenerIDs.count == listeners.count {
                finishStartup(.failure(ListenerError.cancelled))
            }
        default: break
        }
    }

    private func finishStartup(_ result: Result<Void, Error>) {
        guard let continuation = startupContinuation else {
            if pendingStartupResult == nil { pendingStartupResult = result }
            return
        }
        startupContinuation = nil
        startupTimeout?.cancel()
        startupTimeout = nil
        continuation.resume(with: result)
    }

    private func accept(_ connection: NWConnection) {
        guard !consumed, isLoopback(connection.endpoint) else {
            connection.cancel()
            return
        }
        connections.append(connection)
        connection.start(queue: .global(qos: .userInitiated))
        receive(connection, accumulated: Data())
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, !self.consumed else { connection.cancel(); return }
                var next = accumulated
                if let data { next.append(data) }
                if next.count > ProviderOAuthURLPolicy.maximumRequestBytes {
                    self.reject(connection, status: 413)
                    return
                }
                if next.range(of: Data("\r\n\r\n".utf8)) != nil {
                    self.process(connection, request: next)
                    return
                }
                if error != nil || isComplete {
                    self.reject(connection, status: 400)
                    return
                }
                self.receive(connection, accumulated: next)
            }
        }
    }

    private func process(_ connection: NWConnection, request: Data) {
        guard !consumed,
              let callback = ProviderOAuthURLPolicy.parseRequestTarget(request, capture: capture) else {
            reject(connection, status: 400)
            return
        }
        consumed = true
        onCapture(callback)
        let location = "com.tron.mobile.oauth://callback/\(handoffNonce)"
        let response = "HTTP/1.1 302 Found\r\nLocation: \(location)\r\nCache-Control: no-store\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        for listener in listeners { listener.cancel() }
        listeners.removeAll()
    }

    private func reject(_ connection: NWConnection, status: Int) {
        let response = "HTTP/1.1 \(status) Invalid Request\r\nCache-Control: no-store\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        let value = String(describing: host).lowercased()
        return value == "127.0.0.1"
            || value == "localhost"
            || value == "::1"
            || value == "[::1]"
            || value.hasPrefix("::1%")
            || value.hasPrefix("[::1%")
            || value.hasPrefix("::ffff:127.0.0.1")
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
    private var handoffNonce: String?
    private weak var presentationWindowScene: UIWindowScene?
    private var completed = false

    var isRunning: Bool { webSession != nil }

    func start(
        authorizationURL: URL,
        capture: ProviderOAuthCallbackCapture,
        onComplete: @escaping @MainActor (ProviderOAuthCapturedCallback) -> Void,
        onCancel: @escaping @MainActor () -> Void,
        onError: @escaping @MainActor (Error) -> Void
    ) async throws {
        cancel()
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            throw BrowserError.unavailable
        }
        presentationWindowScene = windowScene
        guard let admittedCapture = ProviderOAuthURLPolicy.callbackCapture(
            authorizationURL: authorizationURL,
            gatewayCapture: capture
        ) else { throw BrowserError.invalidAuthorizationURL }
        let nonce = UUID().uuidString.lowercased()
        handoffNonce = nonce
        completed = false
        captured = nil
        let listener = ProviderOAuthLoopbackListener(capture: admittedCapture, handoffNonce: nonce) { [weak self] callback in
            guard let self, !self.completed else { return }
            self.captured = callback
        }
        self.listener = listener
        do { try await listener.start() }
        catch {
            cancel()
            throw error
        }
        guard !Task.isCancelled else { cancel(); throw CancellationError() }
        let session = ASWebAuthenticationSession(
            url: authorizationURL,
            callbackURLScheme: "com.tron.mobile.oauth"
        ) { [weak self] callbackURL, error in
            Task { @MainActor in
                guard let self, !self.completed else { return }
                if let error,
                   (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                    self.finish()
                    onCancel()
                    return
                }
                if let error {
                    self.finish()
                    onError(error)
                    return
                }
                guard let callbackURL,
                      callbackURL.scheme == "com.tron.mobile.oauth",
                      callbackURL.host == "callback",
                      callbackURL.path == "/\(nonce)" else {
                    self.finish()
                    onError(BrowserError.invalidHandoff)
                    return
                }
                guard let captured = self.captured else {
                    self.finish()
                    onError(BrowserError.missingCallback)
                    return
                }
                self.completed = true
                self.finish(retainCompletion: true)
                onComplete(captured)
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        webSession = session
        guard session.start() else {
            cancel()
            throw BrowserError.unavailable
        }
    }

    func cancel() {
        webSession?.cancel()
        finish()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        guard let windowScene = presentationWindowScene else {
            preconditionFailure("Provider browser started without a presentation scene")
        }
        return windowScene.windows.first(where: \.isKeyWindow)
            ?? ASPresentationAnchor(windowScene: windowScene)
    }

    private func finish(retainCompletion: Bool = false) {
        listener?.stop()
        listener = nil
        webSession = nil
        captured = nil
        handoffNonce = nil
        presentationWindowScene = nil
        if !retainCompletion { completed = false }
    }
}
