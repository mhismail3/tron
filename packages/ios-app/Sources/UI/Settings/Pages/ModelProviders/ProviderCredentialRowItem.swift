import Foundation

struct ProviderCredentialRowItem: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case oauth
        case apiKey
    }

    let kind: Kind
    let label: String

    var id: String {
        "\(kind.rawValue):\(label)"
    }

    static func oauth(_ account: ProviderAccountSnapshot) -> Self {
        Self(kind: .oauth, label: account.label)
    }

    static func apiKey(_ key: ProviderApiKeySnapshot) -> Self {
        Self(kind: .apiKey, label: key.label)
    }
}
