import Foundation

/// Resolves the APNs entitlement actually carried by the installed build.
enum APNsEnvironment {
    static func current() -> String {
        readFromEmbeddedProfile() ?? compileTimeDefault
    }

    static func parseEntitlement(fromProfileData data: Data) -> String? {
        guard let source = String(data: data, encoding: .isoLatin1),
              let plistStart = source.range(of: "<plist"),
              let plistEnd = source.range(
                  of: "</plist>",
                  range: plistStart.upperBound..<source.endIndex
              ),
              let plistData = String(source[plistStart.lowerBound..<plistEnd.upperBound])
                .data(using: .isoLatin1),
              let plist = try? PropertyListSerialization.propertyList(
                  from: plistData,
                  options: [],
                  format: nil
              ) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let environment = entitlements["aps-environment"] as? String,
              environment == "development" || environment == "production" else {
            return nil
        }
        return environment
    }

    private static var compileTimeDefault: String {
#if DEBUG
        "development"
#else
        "production"
#endif
    }

    private static func readFromEmbeddedProfile() -> String? {
        guard let url = Bundle.main.url(
            forResource: "embedded",
            withExtension: "mobileprovision"
        ), let data = try? Data(contentsOf: url) else {
            return nil
        }
        return parseEntitlement(fromProfileData: data)
    }
}
