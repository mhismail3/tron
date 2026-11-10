import CryptoKit
import Foundation
import Network
import NIOCore
import NIOSSH
import NIOTransportServices

public struct MacTerminalEndpoint: Codable, Equatable, Sendable {
    public var hosts: [String]
    public var port: Int
    public var username: String
    public var hostKeys: [String]

    public init(hosts: [String], port: Int = 44222, username: String, hostKeys: [String]) {
        self.hosts = hosts
        self.port = port
        self.username = username
        self.hostKeys = hostKeys
    }
}

public enum MacTerminalError: Error, Equatable, Sendable, LocalizedError {
    case notOnTailnet
    case macUnreachable
    case serviceStopped
    case hostKeyMismatch(presented: String)
    case authenticationRefused
    case noPinnedHostKey
    case shellRefused
    case tmuxMissing
    case invalidEndpoint
    case disconnected(String)

    public var errorDescription: String? {
        switch self {
        case .notOnTailnet:
            "This iPhone is not on your tailnet. Open Tailscale, connect, then try again."
        case .macUnreachable:
            "The Mac did not answer over Tailscale. Check that it is awake and connected to Tailscale."
        case .serviceStopped:
            "Tron’s private SSH service is stopped on the Mac. Enable it through the connected Gateway or recover it on the Mac. Stock Remote Login is not used."
        case .hostKeyMismatch(let presented):
            "The Mac presented a different SSH host key (\(presented)) than the one pinned when this iPhone was enrolled. Tron did not connect. Verify the private service’s fingerprint on the Mac, then explicitly refresh SSH enrollment through the connected Gateway. Tron never repins automatically."
        case .authenticationRefused:
            "The Mac refused this iPhone's key. It may have been revoked from the private SSH service. Enable Mac Terminal again while the Gateway is running."
        case .noPinnedHostKey:
            "No Mac host key is pinned. Enable Mac Terminal again while the Gateway is running."
        case .tmuxMissing:
            "tmux is not installed on the Mac. Install tmux on the Mac, then reconnect. Tron did not start a replacement shell."
        case .invalidEndpoint:
            "Mac Terminal requires a numeric Tailscale address and a valid pinned SSH endpoint. Re-enable Mac Terminal through the trusted Gateway."
        case .shellRefused:
            "The Mac accepted the connection but refused to start a shell."
        case .disconnected(let reason):
            "The connection to the Mac closed: \(reason)"
        }
    }
}

public enum MacTerminalPrivateKey: Sendable {
    case secureEnclave(SecureEnclave.P256.Signing.PrivateKey)
    case software(P256.Signing.PrivateKey)

    var sshKey: NIOSSHPrivateKey {
        switch self {
        case .secureEnclave(let key): NIOSSHPrivateKey(secureEnclaveP256Key: key)
        case .software(let key): NIOSSHPrivateKey(p256Key: key)
        }
    }

    public var openSSHPublicKey: String { String(openSSHPublicKey: sshKey.publicKey) }
}

public enum MacTerminalEvent: Sendable, Equatable {
    case output([UInt8])
    case diagnostic([UInt8])
    case closed(status: Int?)
}

public func macTerminalFingerprint(_ key: NIOSSHPublicKey) -> String {
    let line = String(openSSHPublicKey: key)
    let parts = line.split(separator: " ")
    guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return line }
    let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
    return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
}

public func macTerminalHasTailnetAddress() -> Bool {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return false }
    defer { freeifaddrs(head) }
    for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
        guard let address = pointer.pointee.ifa_addr else { continue }
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let host = UInt32(bigEndian: ipv4)
            if host & 0xFFC0_0000 == 0x6440_0000 { return true }
        default:
            continue
        }
    }
    return false
}

public func macTerminalIsTailnetHost(_ host: String) -> Bool {
    var v4 = in_addr()
    if host.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
        return UInt32(bigEndian: v4.s_addr) & 0xFFC0_0000 == 0x6440_0000
    }
    return false
}

public final class MacTerminalSession: Sendable {
    public let events: AsyncStream<MacTerminalEvent>
    private let connection: Channel
    private let shell: Channel

    init(events: AsyncStream<MacTerminalEvent>, connection: Channel, shell: Channel) {
        self.events = events
        self.connection = connection
        self.shell = shell
    }

    public func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        var buffer = shell.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        shell.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer)), promise: nil)
    }

    public func resize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return }
        let request = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: columns, terminalRowHeight: rows,
            terminalPixelWidth: 0, terminalPixelHeight: 0
        )
        shell.triggerUserOutboundEvent(request, promise: nil)
    }

    public func close() {
        connection.close(promise: nil)
    }
}

public enum MacTerminalClient {
    public static func connect(
        endpoint: MacTerminalEndpoint,
        privateKey: MacTerminalPrivateKey,
        sessionName: String,
        columns: Int,
        rows: Int,
        term: String = "xterm-256color",
        connectTimeout: TimeAmount = .seconds(8)
    ) async throws -> MacTerminalSession {
        guard !sessionName.isEmpty, sessionName.count <= 80,
              sessionName.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else {
            throw MacTerminalError.invalidEndpoint
        }
        let command = "export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin; "
            + "if ! command -v tmux >/dev/null 2>&1; then printf 'TRON_TMUX_MISSING\\n'; exit 127; fi; "
            + "printf 'TRON_TMUX_READY\\n'; exec tmux -L tron-mobile -f /dev/null -u new-session -A -s \(sessionName) \\; set-option -t \(sessionName) status off"
        return try await dial(endpoint: endpoint, privateKey: privateKey,
                              request: .shell(term: term, columns: columns, rows: rows, command: command),
                              connectTimeout: connectTimeout)
    }

    private static func dial(
        endpoint: MacTerminalEndpoint,
        privateKey: MacTerminalPrivateKey,
        request: ChannelRequest,
        connectTimeout: TimeAmount
    ) async throws -> MacTerminalSession {
        let pinned = Set(endpoint.hostKeys.compactMap { try? NIOSSHPublicKey(openSSHPublicKey: $0) })
        guard !pinned.isEmpty else { throw MacTerminalError.noPinnedHostKey }
        let hosts = endpoint.hosts.filter(macTerminalIsTailnetHost)
        guard !hosts.isEmpty, (1024...65535).contains(endpoint.port), !endpoint.username.isEmpty else {
            throw MacTerminalError.invalidEndpoint
        }
        var refused = false
        var lastError: MacTerminalError = .macUnreachable
        for host in hosts {
            do {
                return try await open(
                    host: host, endpoint: endpoint, pinned: pinned, privateKey: privateKey.sshKey,
                    request: request, connectTimeout: connectTimeout
                )
            } catch let error as MacTerminalError {
                switch error {
                case .serviceStopped: refused = true
                case .macUnreachable: break
                default: throw error
                }
                lastError = error
            }
        }
        throw refused ? MacTerminalError.serviceStopped : lastError
    }

    private static func open(
        host: String,
        endpoint: MacTerminalEndpoint,
        pinned: Set<NIOSSHPublicKey>,
        privateKey: NIOSSHPrivateKey,
        request: ChannelRequest,
        connectTimeout: TimeAmount,
        handshakeTimeout: TimeAmount = .seconds(15)
    ) async throws -> MacTerminalSession {
        let outcome = HandshakeOutcome()
        let group = NIOTSEventLoopGroup.singleton
        let bootstrap = NIOTSConnectionBootstrap(group: group)
            .connectTimeout(connectTimeout)
            .channelOption(NIOTSChannelOptions.waitForActivity, value: false)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let handler = NIOSSHHandler(
                        role: .client(.init(
                            userAuthDelegate: PinnedKeyAuthentication(
                                username: endpoint.username, privateKey: privateKey, outcome: outcome),
                            serverAuthDelegate: PinnedHostKey(pinned: pinned, outcome: outcome)
                        )),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    )
                    try channel.pipeline.syncOperations.addHandler(handler)
                    try channel.pipeline.syncOperations.addHandler(ConnectionErrorHandler(outcome: outcome))
                }
            }

        let connection: Channel
        do {
            connection = try await bootstrap.connect(host: host, port: endpoint.port).get()
        } catch {
            throw classifyDial(error)
        }

        let (events, continuation) = AsyncStream.makeStream(of: MacTerminalEvent.self, bufferingPolicy: .bufferingOldest(256))
        let deadline = connection.eventLoop.scheduleTask(in: handshakeTimeout) {
            outcome.record(.disconnected("The Mac accepted the connection but did not complete the SSH handshake."))
            connection.close(promise: nil)
        }
        defer { deadline.cancel() }
        do {
            let shell = try await connection.eventLoop.flatSubmit {
                let promise = connection.eventLoop.makePromise(of: Channel.self)
                let ready = connection.eventLoop.makePromise(of: Void.self)
                promise.futureResult.whenFailure { ready.fail($0) }
                do {
                    let ssh = try connection.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                    ssh.createChannel(promise, channelType: .session) { child, type in
                        guard case .session = type else {
                            return child.eventLoop.makeFailedFuture(MacTerminalError.shellRefused)
                        }
                        return child.eventLoop.makeCompletedFuture {
                            try child.pipeline.syncOperations.addHandler(ShellHandler(
                                request: request, ready: ready, outcome: outcome, continuation: continuation))
                        }
                    }
                } catch {
                    promise.fail(error)
                }
                return promise.futureResult.flatMap { child in ready.futureResult.map { child } }
            }.get()
            connection.closeFuture.whenComplete { _ in continuation.finish() }
            return MacTerminalSession(events: events, connection: connection, shell: shell)
        } catch {
            continuation.finish()
            connection.close(promise: nil)
            if let classified = outcome.failure { throw classified }
            if let classified = error as? MacTerminalError { throw classified }
            throw MacTerminalError.disconnected(String(describing: error))
        }
    }

    private static func classifyDial(_ error: Error) -> MacTerminalError {
        if let error = error as? NWError {
            switch error {
            case .posix(let code) where code == .ECONNREFUSED:
                return .serviceStopped
            default:
                return .macUnreachable
            }
        }
        if let error = error as? IOError, error.errnoCode == ECONNREFUSED { return .serviceStopped }
        return .macUnreachable
    }
}

private final class HandshakeOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: MacTerminalError?

    var failure: MacTerminalError? { lock.withLock { recorded } }

    func record(_ error: MacTerminalError) {
        lock.withLock { if recorded == nil { recorded = error } }
    }
}

private final class PinnedHostKey: NIOSSHClientServerAuthenticationDelegate {
    let pinned: Set<NIOSSHPublicKey>
    let outcome: HandshakeOutcome

    init(pinned: Set<NIOSSHPublicKey>, outcome: HandshakeOutcome) {
        self.pinned = pinned
        self.outcome = outcome
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        if pinned.contains(hostKey) {
            validationCompletePromise.succeed(())
        } else {
            let error = MacTerminalError.hostKeyMismatch(presented: macTerminalFingerprint(hostKey))
            outcome.record(error)
            validationCompletePromise.fail(error)
        }
    }
}

private final class PinnedKeyAuthentication: NIOSSHClientUserAuthenticationDelegate {
    let username: String
    let privateKey: NIOSSHPrivateKey
    let outcome: HandshakeOutcome
    private var offered = false

    init(username: String, privateKey: NIOSSHPrivateKey, outcome: HandshakeOutcome) {
        self.username = username
        self.privateKey = privateKey
        self.outcome = outcome
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !offered, availableMethods.contains(.publicKey) else {
            outcome.record(.authenticationRefused)
            nextChallengePromise.fail(MacTerminalError.authenticationRefused)
            return
        }
        offered = true
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
            username: username, serviceName: "",
            offer: .privateKey(.init(privateKey: privateKey))
        ))
    }
}

private final class ConnectionErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any
    let outcome: HandshakeOutcome

    init(outcome: HandshakeOutcome) { self.outcome = outcome }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if let error = error as? MacTerminalError { outcome.record(error) }
        context.close(promise: nil)
    }
}

enum ChannelRequest: Sendable {
    case shell(term: String, columns: Int, rows: Int, command: String)
}

private final class ShellHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private enum Stage { case pty, shell, running }

    let request: ChannelRequest
    let continuation: AsyncStream<MacTerminalEvent>.Continuation
    let outcome: HandshakeOutcome
    private var ready: EventLoopPromise<Void>?
    private var stage = Stage.pty
    private var exitStatus: Int?
    private var startup = [UInt8]()
    private var foundStartupMarker = false

    init(request: ChannelRequest, ready: EventLoopPromise<Void>, outcome: HandshakeOutcome,
         continuation: AsyncStream<MacTerminalEvent>.Continuation) {
        self.request = request
        self.outcome = outcome
        self.ready = ready
        self.continuation = continuation
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { _ in }
    }

    func channelActive(context: ChannelHandlerContext) {
        switch request {
        case .shell(let term, let columns, let rows, _):
            let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true, term: term,
                terminalCharacterWidth: max(columns, 1), terminalRowHeight: max(rows, 1),
                terminalPixelWidth: 0, terminalPixelHeight: 0,
                terminalModes: SSHTerminalModes([:])
            )
            context.triggerUserOutboundEvent(pty, promise: nil)
        }
        context.fireChannelActive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            switch stage {
            case .pty:
                stage = .shell
                if case .shell(_, _, _, let command) = request {
                    context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true), promise: nil)
                }
            case .shell:
                break
            case .running:
                break
            }
        case is ChannelFailureEvent:
            ready?.fail(MacTerminalError.shellRefused)
            ready = nil
            context.close(promise: nil)
        case let status as SSHChannelRequestEvent.ExitStatus:
            exitStatus = status.exitStatus
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = message.data else { return }
        var bytes = Array(buffer.readableBytesView)
        if !foundStartupMarker {
            startup += bytes
            guard let newline = startup.firstIndex(of: 10) else {
                if startup.count > 64 {
                    ready?.fail(MacTerminalError.shellRefused); ready = nil
                    context.close(promise: nil)
                }
                return
            }
            let header = String(decoding: startup[..<newline], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard header == "TRON_TMUX_READY" else {
                let error: MacTerminalError = header == "TRON_TMUX_MISSING" ? .tmuxMissing : .shellRefused
                outcome.record(error)
                ready?.fail(error)
                ready = nil
                context.close(promise: nil)
                return
            }
            bytes = Array(startup.dropFirst(newline + 1))
            startup.removeAll()
            foundStartupMarker = true
        }
        if stage != .running {
            guard !bytes.isEmpty else { return }
            stage = .running
            ready?.succeed(())
            ready = nil
        }
        if case .dropped = continuation.yield(message.type == .stdErr ? .diagnostic(bytes) : .output(bytes)) {
            context.close(promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        ready?.fail(MacTerminalError.shellRefused)
        ready = nil
        continuation.yield(.closed(status: exitStatus))
        continuation.finish()
        context.channel.parent?.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
