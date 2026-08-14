enum ProviderCatalogTarget: Hashable, Sendable {
    case global
    case session(id: String)

    var sessionID: String? {
        switch self {
        case .global: nil
        case let .session(id): id
        }
    }
}

struct ProviderCatalog {
    let providers: [ProviderSummary]
    let models: [ModelSummary]
}

struct ProviderCatalogLoadID: Hashable {
    let target: ProviderCatalogTarget
    let invalidationGeneration: Int
}
