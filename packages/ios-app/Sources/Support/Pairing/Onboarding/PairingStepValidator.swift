import Foundation

/// Pure-value classifier for the onboarding PairingStep's Connect button.
///
/// Three responsibilities:
///   1. Validate + trim the four form inputs (host / port / token / label).
///   2. Produce a `PairingURLParser.PairingPayload` on success that the View
///      hands back to `DependencyContainer` to install as a paired server + token.
///   3. Classify thrown errors from the post-validation `system::ping`
///      reachability probe into user-facing categories.
///
/// **Why a dedicated type**: onboarding validation should stay about field
/// shape and reachability; local server dedupe happens in `PairingPersistor`.
enum PairingStepValidator {

    enum Failure: Error, Equatable {
        /// Any of label / host / port / token is empty or whitespace-only.
        case missingFields
        /// Host must be a bare DNS name, IPv4 address, or unbracketed IPv6
        /// address. Full URLs and path/query/userinfo fragments are rejected.
        case invalidHost(String)
        /// Port doesn't parse as an integer or is outside `1...65535`.
        case invalidPort(String)
        /// Network error reaching the server (connection refused, timeout, DNS).
        case unreachable(String)
        /// Server reachable but returned 401 / WebSocket close 4001 — bad
        /// or missing bearer token.
        case unauthorized
        /// Server replied to `system::ping` with `CLIENT_VERSION_UNSUPPORTED`.
        case incompatibleServer(String)
        /// Token validated and server reachable, but the Keychain write
        /// failed. Distinct from `.unauthorized` so the user message
        /// blames device storage rather than the (correct) token.
        case keychainFailed(String)
        /// A locally paired server exists, but its Keychain token is gone.
        /// The user can recover by scanning the Mac QR code again or entering
        /// the pairing token manually.
        case storedTokenMissing
        /// The server accepted the pairing token, but onboarding could not
        /// read the active server settings after storing the local pairing.
        case settingsFailed(String)

        var userFacingMessage: String {
            switch self {
            case .missingFields:
                return "Fill in all four fields before connecting."
            case .invalidHost:
                return "Host must be a Tailscale IP or hostname, not a full URL."
            case .invalidPort:
                return "Port must be a number between 1 and 65535."
            case .unreachable(let host):
                return "Can't reach \(host). Check that Tailscale is connected on this iPhone and the Mac is online."
            case .unauthorized:
                return "Wrong pairing token. Open the Tron menu bar on your Mac and copy the token again."
            case .incompatibleServer(let serverVersion):
                return "Server version \(serverVersion) is older than this app supports. Update Tron on your Mac."
            case .keychainFailed(let detail):
                return "Could not save the pairing token to Keychain: \(detail)"
            case .storedTokenMissing:
                return "This paired server is missing its saved token. Scan the Mac QR code or enter the pairing token to continue."
            case .settingsFailed(let detail):
                return "Connected, but could not save server settings: \(detail)"
            }
        }
    }

    /// Validate + trim inputs. Returns the parsed payload on success.
    static func validate(
        host: String,
        port: String,
        token: String,
        label: String
    ) -> Result<PairingURLParser.PairingPayload, Failure> {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedHost.isEmpty,
              !trimmedPort.isEmpty,
              !trimmedToken.isEmpty,
              !trimmedLabel.isEmpty else {
            return .failure(.missingFields)
        }

        guard let canonicalHost = PairingHostValidator.canonicalHost(trimmedHost) else {
            return .failure(.invalidHost(trimmedHost))
        }

        guard let parsedPort = Int(trimmedPort), (1...65_535).contains(parsedPort) else {
            return .failure(.invalidPort(trimmedPort))
        }

        return .success(.init(
            host: canonicalHost,
            port: parsedPort,
            token: trimmedToken,
            label: trimmedLabel
        ))
    }

    /// Map a thrown reachability-check error into a `Failure` classification.
    /// Defensive: unknown error types fall through to `.unreachable` so the
    /// inline label is never blank.
    static func classify(error: Error, hostHint: String) -> Failure {
        if let connect = error as? PairingStepConnectError {
            switch connect {
            case .unauthorized: return .unauthorized
            case .incompatible(let serverVersion): return .incompatibleServer(serverVersion)
            case .network(let inner): return classify(error: inner, hostHint: hostHint)
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            // Common URL-loading errors all map to "unreachable" — the user
            // doesn't care about the difference between DNS, TCP refusal, and
            // timeout; they care that the IP isn't responding.
            return .unreachable(hostHint)
        }
        return .unreachable(hostHint)
    }

}

/// Classified errors thrown by the pairing reachability probe. The View
/// translates the WS reject reason into one of these before handing the
/// error back to `PairingStepValidator.classify`.
enum PairingStepConnectError: Error, Equatable {
    /// Server returned 401 / closed WS with code 4001.
    case unauthorized
    /// Server returned `CLIENT_VERSION_UNSUPPORTED` from `system::ping`.
    case incompatible(serverVersion: String)
    /// Anything else — wraps the underlying network error for classification.
    case network(NSError)

    static func == (lhs: PairingStepConnectError, rhs: PairingStepConnectError) -> Bool {
        switch (lhs, rhs) {
        case (.unauthorized, .unauthorized): return true
        case (.incompatible(let a), .incompatible(let b)): return a == b
        case (.network(let a), .network(let b)): return a == b
        default: return false
        }
    }
}
