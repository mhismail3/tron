enum PackageMutationOperation: Hashable {
    case update(String)
    case remove(String)

    var identity: String {
        switch self {
        case .update(let source): return "update:\(source)"
        case .remove(let source): return "remove:\(source)"
        }
    }
}
