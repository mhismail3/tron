import AppKit
import CoreText
import Foundation

/// Registers the bundled Google Fonts sans-serif face so the Mac
/// onboarding wizard does not depend on fonts installed on the host.
enum TronFontLoader {
    static let bundledSansFontResource = "Exo2-Variable"
    static let bundledSansFontExtension = "ttf"
    static let bundledSansFamilyName = "Exo 2"
    static let bundledSansPostScriptName = "Exo2-Regular"

    @discardableResult
    static func registerFonts(bundle: Bundle = .main) -> Bool {
        if fontIsAvailable { return true }

        guard let url = bundledSansFontURL(in: bundle) else {
            NSLog("[Tron] Missing bundled font resource: \(bundledSansFontResource).\(bundledSansFontExtension)")
            return false
        }

        var error: Unmanaged<CFError>?
        let didRegister = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        if didRegister || fontIsAvailable { return true }

        if let error = error?.takeRetainedValue() {
            NSLog("[Tron] Failed to register bundled font \(url.lastPathComponent): \(error)")
        }
        return false
    }

    static func bundledSansFontURL(in bundle: Bundle) -> URL? {
        bundle.url(
            forResource: bundledSansFontResource,
            withExtension: bundledSansFontExtension,
            subdirectory: "Fonts"
        )
        ?? bundle.url(
            forResource: bundledSansFontResource,
            withExtension: bundledSansFontExtension
        )
    }

    private static var fontIsAvailable: Bool {
        NSFont(name: bundledSansPostScriptName, size: 13) != nil
            || NSFontManager.shared.availableFontFamilies.contains(bundledSansFamilyName)
    }
}
