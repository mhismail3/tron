import Foundation

enum GatewayRequestTimeout {
    // Large exports stream canonical history and may exceed the transport default.
    static let sessionExport: Duration = .seconds(1_800)
    // Imports validate and persist the uploaded canonical transcript.
    static let sessionImport: Duration = .seconds(120)
    // These projections traverse bounded context/resource state on the Gateway.
    static let sessionContext: Duration = .seconds(60)
    static let sessionResources: Duration = .seconds(60)
    // Runtime creation can include a cold session initialization.
    static let sessionCreate: Duration = .seconds(60)
    // Arbitrary user shell work has a bounded five-minute execution request.
    static let sessionBash: Duration = .seconds(300)
    // Compaction may wait on the model and rewrite canonical history.
    static let sessionCompact: Duration = .seconds(300)
    // Fork creates a distinct runtime from a canonical transcript boundary.
    static let sessionFork: Duration = .seconds(120)
    // Navigation can include an optional long-running model summary.
    static let sessionNavigate: Duration = .seconds(300)
    // Delete can wait for runtime retirement and canonical resource cleanup.
    static let sessionDelete: Duration = .seconds(60)
    // Resource reload may inspect bounded project resources before responding.
    static let sessionReloadResources: Duration = .seconds(120)
    // Provider refresh calls external model catalogs before returning.
    static let modelCatalogRefresh: Duration = .seconds(75)
    // Update discovery may consult external package registries.
    static let packageCheckUpdates: Duration = .seconds(180)
    // Package install/update/remove can perform external fetch and filesystem work.
    static let packageMutation: Duration = .seconds(300)
}
