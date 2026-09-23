import Foundation

enum GatewayRequestTimeout {
    // Large exports stream canonical history and may exceed the transport default.
    static let sessionExport: Duration = .seconds(1_800)
    // Imports validate and persist the uploaded canonical transcript.
    static let sessionImport: Duration = .seconds(120)
    // These projections can traverse bounded context/resource state on the Gateway.
    static let sessionContext: Duration = .seconds(60)
    static let sessionResources: Duration = .seconds(60)
}
