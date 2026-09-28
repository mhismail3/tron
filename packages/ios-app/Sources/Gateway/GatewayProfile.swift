import Foundation

/// One LAN endpoint a paired Gateway advertises on its authenticated channels
/// (E-3b): where this phone may open a second leg. With the profile's pin it is
/// everything the LAN race needs, and both parts are validated at the boundary
/// so a stored or advertised endpoint is always one this phone can dial.
struct GatewayLanEndpoint: Codable, Hashable, Sendable {
    let host: String
    let port: Int

    init?(host: String, port: Int) {
        guard let canonical = PairingInvitationParser.canonicalHost(host),
              (1...65_535).contains(port) else { return nil }
        self.host = canonical
        self.port = port
    }

    /// The endpoints an advertisement or a stored profile carries. An absent or
    /// malformed list is no endpoints at all, and an entry this phone cannot
    /// dial is dropped: the LAN leg is an optimization over the Tailscale one
    /// (E-3c), and a bad entry must not cost the phone the channel that carried
    /// it.
    static func sanitized(_ advertised: [GatewayLanEndpoint]?) -> [GatewayLanEndpoint] {
        (advertised ?? []).compactMap { GatewayLanEndpoint(host: $0.host, port: $0.port) }
    }
}

struct GatewayProfile: Codable, Hashable, Identifiable, Sendable {
    let id: String
    var label: String
    let host: String
    let port: Int
    let machineId: String
    var machineGroupID: String
    var deviceId: String? = nil
    var isEnabled: Bool = true
    /// The LAN endpoints this Gateway last advertised, and the pin its
    /// certificate must match (E-3b). They are learned at pairing and replaced
    /// by every hello, so the race always dials a lane the Mac currently
    /// serves; an empty list means the lane is off and the profile keeps only
    /// its Tailscale endpoint.
    var lanEndpoints: [GatewayLanEndpoint] = []
    var lanPin: String? = nil

    init(id: String, label: String, host: String, port: Int, machineId: String,
         machineGroupID: String? = nil, deviceId: String? = nil, isEnabled: Bool = true,
         lanEndpoints: [GatewayLanEndpoint] = [], lanPin: String? = nil) {
        self.id = id; self.label = label; self.host = host; self.port = port
        self.machineId = machineId; self.machineGroupID = machineGroupID ?? machineId
        self.deviceId = deviceId; self.isEnabled = isEnabled
        self.lanEndpoints = lanEndpoints; self.lanPin = lanPin
    }

    private enum CodingKeys: String, CodingKey { case id, label, host, port, machineId, machineGroupID, deviceId, isEnabled, lanEndpoints, lanPin }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let advertised: [GatewayLanEndpoint]? = (try? values.decodeIfPresent([GatewayLanEndpoint].self, forKey: .lanEndpoints)) ?? nil
        let pin: String? = (try? values.decodeIfPresent(String.self, forKey: .lanPin)) ?? nil
        self.init(
            id: try values.decode(String.self, forKey: .id),
            label: try values.decode(String.self, forKey: .label),
            host: try values.decode(String.self, forKey: .host),
            port: try values.decode(Int.self, forKey: .port),
            machineId: try values.decode(String.self, forKey: .machineId),
            machineGroupID: try values.decodeIfPresent(String.self, forKey: .machineGroupID),
            deviceId: try values.decodeIfPresent(String.self, forKey: .deviceId),
            isEnabled: try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true,
            lanEndpoints: GatewayLanEndpoint.sanitized(advertised),
            lanPin: pin.flatMap(GatewayLanPin.admit)
        )
    }

    /// Replace the advertisement this profile holds with what a pairing
    /// response or hello just carried (E-3b). Every hello replaces both values,
    /// including an empty list, because the Mac's latest answer is the only
    /// truth about the lane it serves now.
    mutating func adoptLanAdvertising(_ endpoints: [GatewayLanEndpoint], pin: String?) {
        lanEndpoints = GatewayLanEndpoint.sanitized(endpoints)
        lanPin = pin.flatMap(GatewayLanPin.admit)
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

    /// The endpoint selects which authenticated channel identity this saved
    /// profile will admit. The Gateway must still assert that identity in its
    /// pairing response, hello, and system.info projection.
    var gatewayChannel: String { port == 9848 ? "dev" : "stable" }

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

enum GatewayChannelPolicy {
    static func admit(_ value: String) throws -> String {
        guard value == "stable" || value == "dev" else {
            throw GatewayFailure(
                code: "invalid_response",
                message: "The Mac returned an invalid Gateway channel identity.",
                retryable: false,
                details: nil
            )
        }
        return value
    }
}

struct PairingResponse: Decodable, Sendable {
    let deviceId: String
    let token: String
    let machineId: String
    let machineGroupID: String?
    let machineName: String
    let gatewayChannel: String
    /// The LAN lane the Mac serves right now, if any (E-3b). Pairing is the
    /// first authenticated channel, so it is where a phone learns them for the
    /// first time; every later hello replaces them.
    let lanEndpoints: [GatewayLanEndpoint]
    let lanPin: String?

    private enum CodingKeys: String, CodingKey {
        case deviceId, token, machineId, machineGroupID, machineName, gatewayChannel, lanEndpoints, lanPin
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try values.decode(String.self, forKey: .deviceId)
        token = try values.decode(String.self, forKey: .token)
        machineId = try values.decode(String.self, forKey: .machineId)
        machineGroupID = try values.decodeIfPresent(String.self, forKey: .machineGroupID)
        machineName = try values.decode(String.self, forKey: .machineName)
        gatewayChannel = try GatewayChannelPolicy.admit(values.decode(String.self, forKey: .gatewayChannel))
        let advertised: [GatewayLanEndpoint]? = (try? values.decodeIfPresent([GatewayLanEndpoint].self, forKey: .lanEndpoints)) ?? nil
        lanEndpoints = GatewayLanEndpoint.sanitized(advertised)
        let pin: String? = (try? values.decodeIfPresent(String.self, forKey: .lanPin)) ?? nil
        lanPin = pin.flatMap(GatewayLanPin.admit)
    }
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
        let expectedChannel = invitation.port == 9848 ? "dev" : "stable"
        guard paired.gatewayChannel == expectedChannel else {
            throw GatewayFailure(
                code: "identity_mismatch",
                message: "The paired Gateway channel does not match this endpoint.",
                retryable: false,
                details: nil
            )
        }
        let profile = GatewayProfile(
            id: uuidSource(),
            label: invitation.label ?? paired.machineName,
            host: invitation.host,
            port: invitation.port,
            machineId: paired.machineId,
            machineGroupID: paired.machineGroupID,
            deviceId: paired.deviceId,
            lanEndpoints: paired.lanEndpoints,
            lanPin: paired.lanPin
        )
        return (profile, paired.token)
    }
}
