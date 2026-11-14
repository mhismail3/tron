import Foundation

package enum GatewayRequestTimeout {
    package static let sessionExport: Duration = .seconds(1_800)
    package static let sessionContext: Duration = .seconds(60)
    package static let sessionResources: Duration = .seconds(60)
    package static let sessionCreate: Duration = .seconds(60)
    package static let sessionBash: Duration = .seconds(300)
    package static let sessionCompact: Duration = .seconds(300)
    package static let sessionFork: Duration = .seconds(120)
    package static let sessionNavigate: Duration = .seconds(300)
    package static let sessionDelete: Duration = .seconds(60)
    package static let sessionArchive: Duration = .seconds(60)
    package static let sessionReloadResources: Duration = .seconds(120)
    package static let modelCatalogRefresh: Duration = .seconds(75)
    package static let packageCheckUpdates: Duration = .seconds(180)
    package static let packageMutation: Duration = .seconds(300)
}
