import Foundation

enum GatewayErrorPresentationPolicy {
    enum Disposition: Equatable {
        case silent
        case present
    }

    static func disposition(for error: Error) -> Disposition {
        if error is CancellationError || error is GatewayDefinitelyNotSentError || error is GatewayPossiblySentError {
            return .silent
        }
        if let failure = error as? GatewayFailure {
            switch failure.code {
            case "disconnected", "closed", "replaced", "timeout", "event_overflow",
                 "definitely_not_sent", "possibly_sent":
                return .silent
            default:
                return .present
            }
        }
        if let urlError = error as? URLError {
            return [
                .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                .dnsLookupFailed, .notConnectedToInternet, .secureConnectionFailed,
                .cannotLoadFromNetwork, .backgroundSessionWasDisconnected,
            ].contains(urlError.code) ? .silent : .present
        }
        let cocoaError = error as NSError
        if cocoaError.domain == NSPOSIXErrorDomain && [53, 54, 57, 60, 61, 64, 65].contains(cocoaError.code) {
            return .silent
        }
        return .present
    }
}
