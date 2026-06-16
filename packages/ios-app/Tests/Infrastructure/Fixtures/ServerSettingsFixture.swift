import Foundation

enum ServerSettingsFixture {
    static func data(_ json: String = "{}") throws -> Data {
        let raw = Data(json.utf8)
        guard let overlay = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw FixtureError.invalidObject
        }
        var object = try defaultObject()
        deepMerge(&object, overlay)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    enum FixtureError: Error {
        case invalidObject
    }

    private static func defaultObject() throws -> [String: Any] {
        let json = """
        {
            "server": {
                "defaultModel": "claude-sonnet-4-6",
                "transcription": {
                    "enabled": false
                }
            },
            "context": {
                "compactor": {
                    "preserveRecentCount": 5,
                    "triggerTokenThreshold": 0.70
                }
            },
            "observability": {
                "logLevel": "info",
                "verboseRetentionDays": 7
            },
            "storage": {
                "retentionEnabled": true,
                "maxDatabaseMb": 512
            }
        }
        """
        guard let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw FixtureError.invalidObject
        }
        return object
    }

    private static func deepMerge(_ base: inout [String: Any], _ overlay: [String: Any]) {
        for (key, value) in overlay {
            if var baseChild = base[key] as? [String: Any],
               let overlayChild = value as? [String: Any] {
                deepMerge(&baseChild, overlayChild)
                base[key] = baseChild
            } else {
                base[key] = value
            }
        }
    }
}
