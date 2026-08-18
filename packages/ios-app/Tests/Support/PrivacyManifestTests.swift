import Foundation
import Testing

@Suite("Privacy manifest packaging")
struct PrivacyManifestTests {
    @Test("source manifests declare the UserDefaults reason without tracking")
    func sourceManifests() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        try validate(root.appending(path: "Sources/PrivacyInfo.xcprivacy"))
        try validate(root.appending(path: "ShareExtension/PrivacyInfo.xcprivacy"))
    }

    @Test("built app and embedded extension both contain valid manifests")
    func packagedManifests() throws {
        let app = Bundle.main.bundleURL
        try validate(app.appending(path: "PrivacyInfo.xcprivacy"))
        let plugIns = app.appending(path: "PlugIns", directoryHint: .isDirectory)
        let extensions = try FileManager.default.contentsOfDirectory(
            at: plugIns,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "appex" }
        #expect(extensions.count == 1)
        let extensionURL = try #require(extensions.first)
        try validate(extensionURL.appending(path: "PrivacyInfo.xcprivacy"))
    }

    private func validate(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        )
        #expect(plist["NSPrivacyTracking"] as? Bool == false)
        #expect((plist["NSPrivacyTrackingDomains"] as? [Any])?.isEmpty == true)
        #expect((plist["NSPrivacyCollectedDataTypes"] as? [Any])?.isEmpty == true)
        let accessed = try #require(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        #expect(accessed.count == 1)
        #expect(accessed.first?["NSPrivacyAccessedAPIType"] as? String
            == "NSPrivacyAccessedAPICategoryUserDefaults")
        #expect(accessed.first?["NSPrivacyAccessedAPITypeReasons"] as? [String] == ["CA92.1"])
    }
}
