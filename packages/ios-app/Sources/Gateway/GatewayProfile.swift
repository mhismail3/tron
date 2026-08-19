import Foundation

struct GatewayProfile: Codable, Hashable, Identifiable, Sendable {
    let id: String
    var label: String
    let host: String
    let port: Int
    let machineId: String
    var machineGroupID: String
    var deviceId: String? = nil
    var isEnabled: Bool = true

    init(id: String, label: String, host: String, port: Int, machineId: String,
         machineGroupID: String? = nil, deviceId: String? = nil, isEnabled: Bool = true) {
        self.id = id; self.label = label; self.host = host; self.port = port
        self.machineId = machineId; self.machineGroupID = machineGroupID ?? machineId
        self.deviceId = deviceId; self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey { case id, label, host, port, machineId, machineGroupID, deviceId, isEnabled }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(String.self, forKey: .id),
            label: try values.decode(String.self, forKey: .label),
            host: try values.decode(String.self, forKey: .host),
            port: try values.decode(Int.self, forKey: .port),
            machineId: try values.decode(String.self, forKey: .machineId),
            machineGroupID: try values.decodeIfPresent(String.self, forKey: .machineGroupID),
            deviceId: try values.decodeIfPresent(String.self, forKey: .deviceId),
            isEnabled: try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        )
    }

    var hasValidEndpoint: Bool {
        PairingInvitationParser.canonicalHost(host) != nil
            && (1...65_535).contains(port)
            && httpURL() != nil
            && socketURL != nil
    }

    func httpURL(path: String = "", queryItems: [URLQueryItem] = []) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = path
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.url
    }

    var socketURL: URL? {
        var components = URLComponents()
        components.scheme = "ws"
        components.host = host
        components.port = port
        components.path = "/v1/socket"
        return components.url
    }
}

struct PairingInvitation: Equatable, Sendable {
    let host: String
    let port: Int
    let code: String
    let machineId: String?
    let label: String?
}

enum PairingInvitationParser {
    static func parse(_ url: URL) -> PairingInvitation? {
        guard url.scheme == "tron", url.host == "pair",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var values: [String: String] = [:]
        var names = Set<String>()
        for item in components.queryItems ?? [] {
            guard names.insert(item.name).inserted, let value = item.value else { return nil }
            values[item.name] = value
        }
        guard let host = canonicalHost(values["host"]),
              let portText = values["port"], let port = Int(portText), (1...65_535).contains(port),
              let code = values["code"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              (8...32).contains(code.count) else { return nil }
        return PairingInvitation(
            host: host,
            port: port,
            code: code,
            machineId: values["machineId"],
            label: values["label"]
        )
    }

    static func canonicalHost(_ raw: String?) -> String? {
        guard var host = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty,
              !host.contains("://"), !host.contains("/"), !host.contains("?"), !host.contains("#"),
              !host.contains("@"), !host.contains("[") else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, host.count <= 253 else { return nil }
        if host.contains(":") {
            let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF:")
            guard host.unicodeScalars.allSatisfy(allowed.contains), !host.contains(":::") else { return nil }
            return host.lowercased()
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-" &&
                label.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" }
        }) else { return nil }
        return host.lowercased()
    }
}

struct PairingResponse: Decodable, Sendable {
    let deviceId: String
    let token: String
    let machineId: String
    let machineGroupID: String?
    let machineName: String
}

enum GatewayPairingPolicy {
    static let maximumResponseBytes = 64 * 1_024
}

struct GatewayPairer: Sendable {
    private let uuidSource: @Sendable () -> String
    private struct PairingRequest: Encodable {
        let code: String
        let deviceName: String
    }

    private struct PairingFailureEnvelope: Decodable { let error: GatewayFailure }

    private let transport: HTTPDataTransport

    init(transport: HTTPDataTransport = .urlSession, uuidSource: @escaping @Sendable () -> String = { UUID().uuidString }) {
        self.transport = transport
        self.uuidSource = uuidSource
    }

    func pair(_ invitation: PairingInvitation, deviceName: String) async throws -> (GatewayProfile, String) {
        var components = URLComponents()
        components.scheme = "http"
        components.host = invitation.host
        components.port = invitation.port
        components.path = "/v1/pair"
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        request.httpBody = try encoder.encode(PairingRequest(code: invitation.code, deviceName: deviceName))
        let (data, response) = try await transport.data(for: request)
        guard data.count <= GatewayPairingPolicy.maximumResponseBytes else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        guard response.statusCode == 200 else {
            let failure = try? JSONDecoder.gateway.decode(PairingFailureEnvelope.self, from: data)
            throw failure?.error ?? GatewayFailure(
                code: "pairing_failed",
                message: "The Mac rejected this pairing code.",
                retryable: false,
                details: nil
            )
        }
        let paired = try JSONDecoder.gateway.decode(PairingResponse.self, from: data)
        let profile = GatewayProfile(
            id: uuidSource(),
            label: invitation.label ?? paired.machineName,
            host: invitation.host,
            port: invitation.port,
            machineId: paired.machineId,
            machineGroupID: paired.machineGroupID,
            deviceId: paired.deviceId
        )
        return (profile, paired.token)
    }
}
