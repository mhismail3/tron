import Foundation

/// Stamped into the signed app at build time; never inferred from the connected Gateway.
enum IOSBuildIdentity {
    static func sourceRevision(bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "TronBuildIdentity", withExtension: "json"),
              let data = try? Data(contentsOf: url), data.count <= 256,
              let identity = try? JSONDecoder().decode(Identity.self, from: data),
              identity.revision.count == 40,
              identity.revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return identity.revision + (identity.dirty ? "-dirty" : "")
    }

    private struct Identity: Decodable { let revision: String; let dirty: Bool }
}
