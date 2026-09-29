import Foundation

/// One lockstep wire contract shared by every first-party Gateway client.
/// `config/GatewayProtocol.json` is the repository authority; build policy
/// verifies these compile-time values and the final signed artifact metadata.
package enum TronGatewayProtocolContract {
    package static let protocolVersion = 6
    package static let minimumProtocolVersion = 6
}

/// The Gateway's typed close for a hello its protocol cannot speak (mirrors
/// `PROTOCOL_MISMATCH_CLOSE_CODE` in the Gateway transport). A version mismatch
/// is permanent for a build pair, so it must stop recovery with a message that
/// names the side to update instead of retrying as a generic transport failure
/// (F-3). Only the version range can name that side, so the Gateway carries it
/// in the close reason; the close code alone is the fallback signal.
///
/// A Gateway built before this close refuses the same hello with
/// `1008 "protocol version mismatch"`, and that refusal is deliberately not
/// classified here: it carries no version range, and a Gateway old enough to
/// send it is the build that must update. Those Macs keep being retried until
/// they run a Gateway that sends this close (F-3, Option B — no compatibility
/// bridge for an already-deployed build).
package enum GatewayProtocolMismatchClose {
    package static let closeCode = 4006

    private struct Reason: Decodable {
        let code: String
        let gatewayProtocol: Int
        let minProtocol: Int
    }

    /// The typed failure for a protocol-mismatch ending, or nil when this close
    /// says nothing about the protocol, so the caller keeps the ending it
    /// already classified.
    package static func failure(closeCode: Int?, closeReason: String?) -> GatewayFailure? {
        let reason = closeReason
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(Reason.self, from: $0) }
        guard reason?.code == "protocol_mismatch" || closeCode == Self.closeCode else { return nil }
        return failure(gatewayProtocol: reason?.gatewayProtocol, minProtocol: reason?.minProtocol)
    }

    /// The typed failure for a hello whose advertised range excludes this app's
    /// protocol.
    package static func failure(gatewayProtocol: Int, minProtocol: Int) -> GatewayFailure {
        failure(gatewayProtocol: Optional(gatewayProtocol), minProtocol: Optional(minProtocol))
    }

    private static func failure(gatewayProtocol: Int?, minProtocol: Int?) -> GatewayFailure {
        GatewayFailure(
            code: "protocol_mismatch",
            message: message(gatewayProtocol: gatewayProtocol, minProtocol: minProtocol),
            retryable: false,
            details: nil
        )
    }

    private static func message(gatewayProtocol: Int?, minProtocol: Int?) -> String {
        let app = TronGatewayProtocolContract.protocolVersion
        guard let gatewayProtocol, let minProtocol else {
            return "The Mac gateway speaks a different protocol than this app. Update Tron on this iPhone and on the Mac."
        }
        if app < minProtocol {
            return "This app is older than the Mac gateway (this app speaks protocol \(app); the Mac accepts \(minProtocol)–\(gatewayProtocol)). Update Tron on this iPhone."
        }
        if app > gatewayProtocol {
            return "The Mac gateway is older than this app (the Mac speaks protocol \(minProtocol)–\(gatewayProtocol); this app speaks protocol \(app)). Update Tron on the Mac."
        }
        // The hello advertised a range this app's protocol sits inside, so the
        // mismatch is not a plain version ordering; name both sides.
        return "The Mac gateway protocol does not match this app (the Mac accepts \(minProtocol)–\(gatewayProtocol); this app speaks protocol \(app)). Update Tron on this iPhone and on the Mac."
    }
}
