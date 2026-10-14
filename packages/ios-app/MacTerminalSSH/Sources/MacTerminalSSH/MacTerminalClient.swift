import CryptoKit
import Foundation
import Network
import NIOCore
import NIOSSH
import NIOTransportServices

/// Mac Terminal's SSH client: one interactive login shell on the paired Mac's
/// built-in sshd (macOS Remote Login), reached over Tailscale without the
/// Gateway. The iPhone app and the `mac-terminal-probe` journey binary share
/// this code, so the real-sshd test exercises the exact handshake, host-key
/// pin, key authentication and PTY channel the app uses.
///
/// The Mac's address, user and host keys are learned once from the Gateway at
/// enrollment (`MacTerminalEndpoint`); nothing here talks to the Gateway.

/// Where and as whom to connect, and which host keys the Mac may present.
public struct MacTerminalEndpoint: Codable, Equatable, Sendable {
    /// Dialed in order: the MagicDNS name, then the Tailscale addresses.
    public var hosts: [String]
    public var port: Int
    public var username: String
    /// The Mac's sshd host public keys in OpenSSH form, pinned at enrollment.
    public var hostKeys: [String]

    public init(hosts: [String], port: Int = 22, username: String, hostKeys: [String]) {
        self.hosts = hosts
        self.port = port
        self.username = username
        self.hostKeys = hostKeys
    }
}

/// Every way a connection fails, each with the text the sheet shows. A failure
/// is classified once, at the boundary that observed it, so the sheet never
/// guesses from a generic transport error.
public enum MacTerminalError: Error, Equatable, Sendable, LocalizedError {
    case notOnTailnet
    case macUnreachable
    case remoteLoginOff
    case hostKeyMismatch(presented: String)
    case authenticationRefused
    case noPinnedHostKey
    case shellRefused
    case disconnected(String)

    public var errorDescription: String? {
        switch self {
        case .notOnTailnet:
            "This iPhone is not on your tailnet. Open Tailscale, connect, then try again."
        case .macUnreachable:
            "The Mac did not answer over Tailscale. Check that it is awake and connected to Tailscale."
        case .remoteLoginOff:
            "Remote Login is off on the Mac. Turn it on in System Settings › General › Sharing › Remote Login, then try again."
        case .hostKeyMismatch(let presented):
            "The Mac presented a different SSH host key (\(presented)) than the one pinned when this iPhone was enrolled. Tron did not connect. If you reinstalled macOS or replaced the Mac, remove and re-enable Mac Terminal while the Gateway is running."
        case .authenticationRefused:
            "The Mac refused this iPhone's key. It may have been revoked or removed from ~/.ssh/authorized_keys. Enable Mac Terminal again while the Gateway is running."
        case .noPinnedHostKey:
            "No Mac host key is pinned. Enable Mac Terminal again while the Gateway is running."
        case .shellRefused:
            "The Mac accepted the connection but refused to start a shell."
        case .disconnected(let reason):
            "The connection to the Mac closed: \(reason)"
        }
    }
}

/// What the shell produces.
public enum MacTerminalEvent: Sendable, Equatable {
    case output([UInt8])
    /// The shell ended; `status` is its exit status when the Mac sent one.
    case closed(status: Int?)
}

/// OpenSSH's `SHA256:` fingerprint of a public key, as `ssh-keygen -l` prints it.
public func macTerminalFingerprint(_ key: NIOSSHPublicKey) -> String {
    let line = String(openSSHPublicKey: key)
    let parts = line.split(separator: " ")
    guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return line }
    let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
    return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
}

/// Whether this device holds a Tailscale address (100.64.0.0/10 or
/// fd7a:115c:a1e0::/48). It is the early, precise "not on tailnet" signal:
/// without it every dial would only time out.
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
        case AF_INET6:
            let bytes = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                withUnsafeBytes(of: pointer.pointee.sin6_addr) { Array($0) }
            }
            if bytes.starts(with: [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0]) { return true }
        default:
            continue
        }
    }
    return false
}

/// One live shell. `events` ends after `.closed`.
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

    /// Closing ends the SSH connection; the login shell gets SIGHUP from sshd.
    public func close() {
        connection.close(promise: nil)
    }
}

public enum MacTerminalClient {
    /// Opens a login shell. Each host is dialed in turn; the first that
    /// completes the handshake wins. A pinned-key mismatch or a refused key
    /// stops at once: another address of the same Mac would answer the same.
    public static func connect(
        endpoint: MacTerminalEndpoint,
        privateKey: NIOSSHPrivateKey,
        columns: Int,
        rows: Int,
        term: String = "xterm-256color",
        connectTimeout: TimeAmount = .seconds(8)
    ) async throws -> MacTerminalSession {
        let pinned = Set(endpoint.hostKeys.compactMap { try? NIOSSHPublicKey(openSSHPublicKey: $0) })
        guard !pinned.isEmpty else { throw MacTerminalError.noPinnedHostKey }
        var refused = false
        var lastError: MacTerminalError = .macUnreachable
        for host in endpoint.hosts {
            do {
                return try await open(
                    host: host, endpoint: endpoint, pinned: pinned, privateKey: privateKey,
                    columns: columns, rows: rows, term: term, connectTimeout: connectTimeout
                )
            } catch let error as MacTerminalError {
                switch error {
                case .remoteLoginOff: refused = true
                case .macUnreachable: break
                default: throw error
                }
                lastError = error
            }
        }
        throw refused ? MacTerminalError.remoteLoginOff : lastError
    }

    private static func open(
        host: String,
        endpoint: MacTerminalEndpoint,
        pinned: Set<NIOSSHPublicKey>,
        privateKey: NIOSSHPrivateKey,
        columns: Int,
        rows: Int,
        term: String,
        connectTimeout: TimeAmount
    ) async throws -> MacTerminalSession {
        let outcome = HandshakeOutcome()
        let group = NIOTSEventLoopGroup.singleton
        let bootstrap = NIOTSConnectionBootstrap(group: group)
            .connectTimeout(connectTimeout)
            // Fail on the first unsatisfied path instead of waiting for one, so
            // a refused port or a missing route surfaces as its own error.
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

        let (events, continuation) = AsyncStream.makeStream(of: MacTerminalEvent.self, bufferingPolicy: .unbounded)
        do {
            let shell = try await connection.eventLoop.flatSubmit {
                let promise = connection.eventLoop.makePromise(of: Channel.self)
                let ready = connection.eventLoop.makePromise(of: Void.self)
                // A channel that never opens (the handshake failed) must still
                // settle `ready`; NIO treats an abandoned promise as a bug.
                promise.futureResult.whenFailure { ready.fail($0) }
                do {
                    let ssh = try connection.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                    ssh.createChannel(promise, channelType: .session) { child, type in
                        guard case .session = type else {
                            return child.eventLoop.makeFailedFuture(MacTerminalError.shellRefused)
                        }
                        return child.eventLoop.makeCompletedFuture {
                            try child.pipeline.syncOperations.addHandler(ShellHandler(
                                term: term, columns: columns, rows: rows,
                                ready: ready, continuation: continuation))
                        }
                    }
                } catch {
                    promise.fail(error)
                }
                return promise.futureResult.flatMap { child in ready.futureResult.map { child } }
            }.get()
            // The shell's end, or a broken connection, ends the session.
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
                return .remoteLoginOff
            default:
                return .macUnreachable
            }
        }
        if let error = error as? IOError, error.errnoCode == ECONNREFUSED { return .remoteLoginOff }
        return .macUnreachable
    }
}

/// The handshake's own verdict, recorded by the delegate that reached it so
/// the generic channel error that follows is not what the user sees.
private final class HandshakeOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: MacTerminalError?

    var failure: MacTerminalError? { lock.withLock { recorded } }

    func record(_ error: MacTerminalError) {
        lock.withLock { if recorded == nil { recorded = error } }
    }
}

/// Accepts only a host key pinned at enrollment.
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

/// Offers the enrolled key once. A second request means the Mac refused it.
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

/// The session channel: requests a PTY and a login shell, then streams bytes.
private final class ShellHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private enum Stage { case pty, shell, running }

    let term: String
    let columns: Int
    let rows: Int
    let continuation: AsyncStream<MacTerminalEvent>.Continuation
    private var ready: EventLoopPromise<Void>?
    private var stage = Stage.pty
    private var exitStatus: Int?

    init(term: String, columns: Int, rows: Int, ready: EventLoopPromise<Void>,
         continuation: AsyncStream<MacTerminalEvent>.Continuation) {
        self.term = term
        self.columns = columns
        self.rows = rows
        self.ready = ready
        self.continuation = continuation
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { _ in }
    }

    func channelActive(context: ChannelHandlerContext) {
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true, term: term,
            terminalCharacterWidth: max(columns, 1), terminalRowHeight: max(rows, 1),
            terminalPixelWidth: 0, terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        context.triggerUserOutboundEvent(pty, promise: nil)
        context.fireChannelActive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            switch stage {
            case .pty:
                stage = .shell
                context.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: true), promise: nil)
            case .shell:
                stage = .running
                ready?.succeed(())
                ready = nil
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
        continuation.yield(.output(Array(buffer.readableBytesView)))
    }

    func channelInactive(context: ChannelHandlerContext) {
        ready?.fail(MacTerminalError.shellRefused)
        ready = nil
        continuation.yield(.closed(status: exitStatus))
        continuation.finish()
        // The shell owns the connection: when it ends, so does the session.
        context.channel.parent?.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
