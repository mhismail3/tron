import Darwin
import Foundation
import Testing

@testable import TronMobile

@Suite("ConnectionErrorClassifier")
struct ConnectionErrorClassifierTests {

    @Test("POSIX ECONNABORTED is transient and requires connection recovery")
    func posixConnectionAbort() {
        let error = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(ECONNABORTED),
            userInfo: [NSLocalizedDescriptionKey: "Software caused connection abort"]
        )

        #expect(ConnectionErrorClassifier.isTransientTransport(error))
        #expect(ConnectionErrorClassifier.requiresConnectionRecovery(error))
    }

    @Test("URLSession networkConnectionLost is transient and requires connection recovery")
    func urlSessionNetworkConnectionLost() {
        let error = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorNetworkConnectionLost,
            userInfo: nil
        )

        #expect(ConnectionErrorClassifier.isTransientTransport(error))
        #expect(ConnectionErrorClassifier.requiresConnectionRecovery(error))
    }

    @Test("nested POSIX errors under URLSession errors are classified")
    func nestedUnderlyingError() {
        let underlying = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(ECONNRESET),
            userInfo: nil
        )
        let error = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorUnknown,
            userInfo: [NSUnderlyingErrorKey: underlying]
        )

        #expect(ConnectionErrorClassifier.isTransientTransport(error))
        #expect(ConnectionErrorClassifier.requiresConnectionRecovery(error))
    }

    @Test("request timeout is transient but does not prove the socket needs recovery")
    func timeoutIsTransientOnly() {
        #expect(ConnectionErrorClassifier.isTransientTransport(WebSocketError.timeout))
        #expect(ConnectionErrorClassifier.requiresConnectionRecovery(WebSocketError.timeout) == false)
    }

    @Test("protocol and application errors are not transient transport errors")
    func nonTransportErrors() {
        let generic = NSError(domain: "test", code: 1, userInfo: nil)

        #expect(ConnectionErrorClassifier.isTransientTransport(WebSocketError.invalidResponse) == false)
        #expect(ConnectionErrorClassifier.isTransientTransport(WebSocketError.decodingError("bad")) == false)
        #expect(ConnectionErrorClassifier.isTransientTransport(RPCClientError.invalidURL) == false)
        #expect(ConnectionErrorClassifier.isTransientTransport(generic) == false)
    }
}
