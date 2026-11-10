import Foundation

package enum GatewayConnectionPolicy {
    package static let clientPingInterval: Duration = .seconds(10)
    package static let clientPongDeadline: Duration = .seconds(8)
    package static let transportOpenDeadline: Duration = .seconds(5)
    package static let helloDeadline: Duration = .seconds(15)
    package static let requestInactivityTimeout: TimeInterval = 60
    package static let gracefulCloseLimit: Duration = .seconds(1)
}
