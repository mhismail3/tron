import Foundation

enum ServerSettingsFixture {
    static func data(_ json: String = "{}") throws -> Data {
        let raw = Data(json.utf8)
        guard var object = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw FixtureError.invalidObject
        }
        if object["git"] == nil {
            object["git"] = gitPolicy()
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func gitPolicy() -> [String: Any] {
        [
            "protectedBranches": ["main", "master", "develop"],
            "sessionBranchPolicy": "keep",
            "mergeStrategy": "merge",
            "autoSetUpstream": true,
            "crashRecoveryAbortTimeoutMs": 1_800_000,
            "opTimeoutNetworkMs": 60_000,
            "opTimeoutLocalMs": 30_000
        ]
    }

    enum FixtureError: Error {
        case invalidObject
    }
}
