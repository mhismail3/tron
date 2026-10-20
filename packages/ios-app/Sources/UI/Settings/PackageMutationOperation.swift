enum PackageInstallDraftPolicy {
    static func afterSuccess(current: String, captured: String) -> String {
        current == captured ? "" : current
    }
}

enum PackageMutationOperation: Hashable {
    case install(String)
    case update(String)
    case remove(String)

    var identity: String {
        switch self {
        case .install(let source): return "install:\(source)"
        case .update(let source): return "update:\(source)"
        case .remove(let source): return "remove:\(source)"
        }
    }
}
