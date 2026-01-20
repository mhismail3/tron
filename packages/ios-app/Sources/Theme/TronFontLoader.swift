import SwiftUI
import UIKit

/// Utility to register and verify Recursive fonts at app startup
enum TronFontLoader {
    // MARK: - Font Names (PostScript names used by iOS)

    /// Recursive Mono font names
    enum Mono {
        static let regular = "RecursiveMonoLnrSt-Regular"
        static let medium = "RecursiveMonoLnrSt-Med"
        static let semiBold = "RecursiveMonoLnrSt-SemiBold"
        static let bold = "RecursiveMonoLnrSt-Bold"
    }

    /// Recursive Sans font names
    enum Sans {
        static let regular = "RecursiveSansLnrSt-Regular"
        static let medium = "RecursiveSansLnrSt-Med"
        static let semiBold = "RecursiveSansLnrSt-SemiBold"
        static let bold = "RecursiveSansLnrSt-Bold"
    }

    // MARK: - Font Registration

    /// Register custom fonts at app startup.
    /// Fonts are registered via Info.plist UIAppFonts, but this verifies they loaded correctly.
    static func registerFonts() {
        let expectedFonts = [
            Mono.regular,
            Mono.medium,
            Mono.semiBold,
            Mono.bold,
            Sans.regular,
            Sans.medium,
            Sans.semiBold,
            Sans.bold,
        ]

        var missingFonts: [String] = []

        for fontName in expectedFonts {
            if UIFont(name: fontName, size: 12) == nil {
                missingFonts.append(fontName)
            }
        }

        if missingFonts.isEmpty {
            logger.info("All Recursive fonts loaded successfully", category: .ui)
        } else {
            logger.error("Missing fonts: \(missingFonts.joined(separator: ", "))", category: .ui)
            #if DEBUG
            printAvailableFonts()
            #endif
        }
    }

    /// Print all available font families and font names (for debugging)
    static func printAvailableFonts() {
        logger.debug("=== Available Font Families ===", category: .ui)
        for family in UIFont.familyNames.sorted() {
            logger.debug("Family: \(family)", category: .ui)
            for name in UIFont.fontNames(forFamilyName: family) {
                logger.debug("  - \(name)", category: .ui)
            }
        }
    }

    /// Check if a specific font is available
    static func isFontAvailable(_ fontName: String) -> Bool {
        UIFont(name: fontName, size: 12) != nil
    }

    /// Get a SwiftUI Font with fallback to system font
    static func font(name: String, size: CGFloat) -> Font {
        if isFontAvailable(name) {
            return Font.custom(name, size: size)
        } else {
            // Fallback to system monospaced for mono fonts, system for sans
            if name.contains("Mono") {
                return Font.system(size: size, design: .monospaced)
            } else {
                return Font.system(size: size)
            }
        }
    }

    /// Get a UIFont with fallback to system font
    static func uiFont(name: String, size: CGFloat) -> UIFont {
        if let font = UIFont(name: name, size: size) {
            return font
        } else {
            // Fallback to system monospaced for mono fonts, system for sans
            if name.contains("Mono") {
                return UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
            } else {
                return UIFont.systemFont(ofSize: size)
            }
        }
    }
}
