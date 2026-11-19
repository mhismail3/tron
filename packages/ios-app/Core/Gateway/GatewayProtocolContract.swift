import Foundation

package enum TronGatewayProtocolContract {
    package static let protocolVersion = 9
    package static let minimumProtocolVersion = 9
}

package enum GatewayProtocolMismatchClose {
    package static let closeCode = 4006

    private struct Reason: Decodable {
        let code: String
        let gatewayProtocol: Int
        let minProtocol: Int
    }

    package static func failure(closeCode: Int?, closeReason: String?) -> GatewayFailure? {
        let reason = closeReason
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(Reason.self, from: $0) }
        guard reason?.code == "protocol_mismatch" || closeCode == Self.closeCode else { return nil }
        return failure(gatewayProtocol: reason?.gatewayProtocol, minProtocol: reason?.minProtocol)
    }

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
        return "The Mac gateway protocol does not match this app (the Mac accepts \(minProtocol)–\(gatewayProtocol); this app speaks protocol \(app)). Update Tron on this iPhone and on the Mac."
    }
}
