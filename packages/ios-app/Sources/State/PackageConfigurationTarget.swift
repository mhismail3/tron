enum PackageConfigurationTarget: Hashable, Sendable {
    case global
    case workspace(cwd: String)

    init(cwd: String?) {
        if let cwd, !cwd.isEmpty {
            self = .workspace(cwd: cwd)
        } else {
            self = .global
        }
    }

    var cwd: String? {
        switch self {
        case .global: nil
        case let .workspace(cwd): cwd
        }
    }
}

struct PackageLoadID: Hashable {
    let target: PackageConfigurationTarget
    let profileRevision: Int
    let invalidationGeneration: Int
    let refreshGeneration: Int
}
