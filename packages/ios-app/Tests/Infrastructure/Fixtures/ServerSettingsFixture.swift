import Foundation

enum ServerSettingsFixture {
    static func data(_ json: String = "{}") throws -> Data {
        let raw = Data(json.utf8)
        guard var object = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw FixtureError.invalidObject
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    enum FixtureError: Error {
        case invalidObject
    }
}
