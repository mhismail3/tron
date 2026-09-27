import Foundation

package enum GatewayRequestTimeout {
    // Large exports stream canonical history and may exceed the transport default.
    package static let sessionExport: Duration = .seconds(1_800)
    // Imports validate and persist the uploaded canonical transcript.
    package static let sessionImport: Duration = .seconds(120)
    // These projections traverse bounded context/resource state on the Gateway.
    package static let sessionContext: Duration = .seconds(60)
    package static let sessionResources: Duration = .seconds(60)
    // Runtime creation can include a cold session initialization.
    package static let sessionCreate: Duration = .seconds(60)
    // Arbitrary user shell work has a bounded five-minute execution request.
    package static let sessionBash: Duration = .seconds(300)
    // Compaction may wait on the model and rewrite canonical history.
    package static let sessionCompact: Duration = .seconds(300)
    // Fork creates a distinct runtime from a canonical transcript boundary.
    package static let sessionFork: Duration = .seconds(120)
    // Navigation can include an optional long-running model summary.
    package static let sessionNavigate: Duration = .seconds(300)
    // Delete can wait for runtime retirement and canonical resource cleanup.
    package static let sessionDelete: Duration = .seconds(60)
    // Archive state is a bounded display mutation on an idle session.
    package static let sessionArchive: Duration = .seconds(60)
    // Resource reload may inspect bounded project resources before responding.
    package static let sessionReloadResources: Duration = .seconds(120)
    // Provider refresh calls external model catalogs before returning.
    package static let modelCatalogRefresh: Duration = .seconds(75)
    // Update discovery may consult external package registries.
    package static let packageCheckUpdates: Duration = .seconds(180)
    // Package install/update/remove can perform external fetch and filesystem work.
    package static let packageMutation: Duration = .seconds(300)
}
