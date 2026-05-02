import Darwin
import Foundation

/// Native transport-error classification shared by connection UI, refresh coordination,
/// and transient-error deduping.
///
/// URLSession WebSocket failures often arrive as `NSError` values instead of
/// `WebSocketError` (for example POSIX `ECONNABORTED` after foregrounding). Keep the
/// policy centralized so foreground refreshes, send failures, and toast deduping agree
/// on which failures are connection churn versus real application errors.
enum ConnectionErrorClassifier {
    static let transientDedupKey = "connection.transient"

    private enum Classification: Int {
        case none = 0
        case transient = 1
        case requiresConnectionRecovery = 2

        var isTransient: Bool { self != .none }
        var requiresRecovery: Bool { self == .requiresConnectionRecovery }
    }

    static func isTransientTransport(_ error: Error) -> Bool {
        classify(error).isTransient
    }

    static func requiresConnectionRecovery(_ error: Error) -> Bool {
        classify(error).requiresRecovery
    }

    private static func classify(_ error: Error, depth: Int = 0) -> Classification {
        guard depth < 6 else { return .none }

        if let ws = error as? WebSocketError {
            switch ws {
            case .notConnected, .connectionFailed:
                return .requiresConnectionRecovery
            case .timeout:
                return .transient
            case .unauthorized, .invalidResponse, .encodingError, .decodingError:
                return .none
            }
        }

        if let rpc = error as? RPCClientError {
            switch rpc {
            case .connectionNotEstablished:
                return .requiresConnectionRecovery
            case .noActiveSession:
                return .transient
            case .invalidURL:
                return .none
            }
        }

        let nsError = error as NSError
        let direct = classifyNSError(nsError)
        if direct != .none {
            return direct
        }

        return classifyUnderlyingErrors(in: nsError, depth: depth)
    }

    private static func classifyNSError(_ error: NSError) -> Classification {
        switch error.domain {
        case NSURLErrorDomain:
            return classifyURLError(code: error.code)
        case NSPOSIXErrorDomain:
            return classifyPOSIXError(code: error.code)
        default:
            return .none
        }
    }

    private static func classifyURLError(code: Int) -> Classification {
        let recoveryCodes: Set<Int> = [
            NSURLErrorNetworkConnectionLost,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorCannotConnectToHost,
            NSURLErrorCannotFindHost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorCannotLoadFromNetwork,
            NSURLErrorDataNotAllowed,
            NSURLErrorInternationalRoamingOff,
            NSURLErrorCallIsActive,
            NSURLErrorBackgroundSessionWasDisconnected
        ]
        if recoveryCodes.contains(code) {
            return .requiresConnectionRecovery
        }

        let transientCodes: Set<Int> = [
            NSURLErrorCancelled,
            NSURLErrorTimedOut
        ]
        if transientCodes.contains(code) {
            return .transient
        }

        return .none
    }

    private static func classifyPOSIXError(code: Int) -> Classification {
        let recoveryCodes: Set<Int> = [
            Int(ECONNABORTED),
            Int(ECONNRESET),
            Int(ECONNREFUSED),
            Int(ENOTCONN),
            Int(EPIPE),
            Int(ETIMEDOUT),
            Int(ENETDOWN),
            Int(ENETUNREACH),
            Int(EHOSTDOWN),
            Int(EHOSTUNREACH)
        ]
        if recoveryCodes.contains(code) {
            return .requiresConnectionRecovery
        }

        if code == Int(ECANCELED) || code == Int(EINTR) {
            return .transient
        }

        return .none
    }

    private static func classifyUnderlyingErrors(in error: NSError, depth: Int) -> Classification {
        var best: Classification = .none

        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error {
            best = stronger(best, classify(underlying, depth: depth + 1))
        }

        if let underlyingErrors = error.userInfo["NSMultipleUnderlyingErrors"] as? [Error] {
            for underlying in underlyingErrors {
                best = stronger(best, classify(underlying, depth: depth + 1))
            }
        }

        return best
    }

    private static func stronger(_ lhs: Classification, _ rhs: Classification) -> Classification {
        lhs.rawValue >= rhs.rawValue ? lhs : rhs
    }
}
