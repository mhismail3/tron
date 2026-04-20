import Foundation

/// APNs environment detection at runtime.
///
/// The `.entitlements` file (e.g., `TronMobileProd.entitlements`) declares
/// which APNs environment we *want* — but when Xcode auto-signs a build
/// with a Development provisioning profile, the profile's own
/// `aps-environment` entitlement **overrides** that declaration. Compile-
/// time heuristics like `#if DEBUG` can't see this, which is why Prod-scheme
/// rebuilds from Xcode were reporting `"production"` while the actual APNs
/// token they received was a sandbox token → `BadDeviceToken` on send.
///
/// This module parses `embedded.mobileprovision` at runtime to read the
/// *actual* entitlement in force, falling back to a compile-time heuristic
/// when the profile isn't shipped with the app (e.g., App Store builds).
enum APNsEnvironment {
    /// Returns `"sandbox"` or `"production"` — the values the server and
    /// relay expect.
    ///
    /// Priority:
    /// 1. Parse `embedded.mobileprovision` and read `Entitlements.aps-environment`.
    ///    This is authoritative for Xcode-built, TestFlight, and ad-hoc builds.
    /// 2. Fall back to `#if DEBUG`. Covers App Store builds (where the
    ///    embedded profile may be absent) and the simulator.
    static func current() -> String {
        if let fromProfile = readFromEmbeddedProfile() {
            return fromProfile
        }
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    /// Read `aps-environment` from the app's embedded provisioning profile.
    /// Returns `nil` if the profile is missing, unreadable, or lacks a
    /// recognized value — callers fall back to a compile-time heuristic.
    static func readFromEmbeddedProfile() -> String? {
        guard
            let url = Bundle.main.url(
                forResource: "embedded",
                withExtension: "mobileprovision"
            ),
            let data = try? Data(contentsOf: url)
        else {
            return nil
        }
        return parseEntitlementFromProfileData(data)
    }

    /// Given the raw bytes of a PKCS7-wrapped `.mobileprovision`, extract
    /// the inner XML plist and return the mapped `aps-environment` value.
    ///
    /// The plist is stored as plaintext inside the signed envelope — we
    /// can locate it by substring search in a Latin-1 view of the bytes
    /// (Latin-1 is 1:1 with bytes, so binary-signature bytes don't break
    /// the scan).
    ///
    /// `internal` visibility for unit testing.
    static func parseEntitlementFromProfileData(_ data: Data) -> String? {
        guard let string = String(data: data, encoding: .isoLatin1) else {
            return nil
        }
        return parseEntitlementFromProfileString(string)
    }

    /// Parse a `.mobileprovision` string representation (used directly by tests).
    static func parseEntitlementFromProfileString(_ string: String) -> String? {
        guard
            let plistStart = string.range(of: "<plist"),
            let plistEnd = string.range(
                of: "</plist>",
                range: plistStart.upperBound..<string.endIndex
            )
        else {
            return nil
        }
        let plistSlice = String(string[plistStart.lowerBound..<plistEnd.upperBound])
        guard let plistData = plistSlice.data(using: .isoLatin1) else {
            return nil
        }
        guard
            let plist = try? PropertyListSerialization.propertyList(
                from: plistData,
                options: [],
                format: nil
            ) as? [String: Any],
            let entitlements = plist["Entitlements"] as? [String: Any],
            let env = entitlements["aps-environment"] as? String
        else {
            return nil
        }
        switch env {
        case "production":
            return "production"
        case "development":
            return "sandbox"
        default:
            // Unknown value (e.g., a hypothetical future Apple env). Caller
            // falls back to the compile-time heuristic.
            return nil
        }
    }
}
