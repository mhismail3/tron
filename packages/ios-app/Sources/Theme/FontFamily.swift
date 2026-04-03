import Foundation

/// Category for grouping font families in the UI
enum FontCategory: String, CaseIterable, Sendable {
    case sans
    case serif
    case mono

    var displayName: String {
        switch self {
        case .sans: "Sans"
        case .serif: "Serif"
        case .mono: "Mono"
        }
    }
}

/// Available font families for the app's UI text.
///
/// # Adding New Fonts
///
/// Before adding a font, check its vertical metrics at the target size (e.g. 14pt):
///
///     let font = UIFont(descriptor: UIFontDescriptor(fontAttributes: [.family: "FontName"]), size: 14)
///     let excessAbove = font.ascender - font.capHeight  // invisible space above capitals
///     let excessBelow = -font.descender                 // space below baseline
///     let ratio = excessAbove / excessBelow              // should be ≈ 1.0
///
/// **Reject fonts where `excessAbove / excessBelow > 1.2`.** These fonts have disproportionate
/// ascender headroom (for diacritics/accents) baked into the font file. SwiftUI's `Font(UIFont)`
/// preserves these metrics, causing visible extra whitespace above all text — proportional to font
/// size and affecting every UI element. This cannot be fixed without modifying the font file.
///
/// Known rejected fonts:
/// - **Literata**: ratio 1.55 (ascender 16.48 at 14pt vs other serifs ~14)
/// - **Crimson Pro**: ratio 1.50
enum FontFamily: String, CaseIterable, Sendable, Identifiable {
    // Sans
    case recursive
    case alanSans
    case comme

    // Serif
    case donegalOne
    case ibmPlexSerif
    case libreBaskerville
    case sourceSerif4
    case lora

    // Mono
    case jetBrainsMono
    case ibmPlexMono
    case geistMono

    var id: String { rawValue }

    var category: FontCategory {
        switch self {
        case .recursive, .alanSans, .comme: .sans
        case .donegalOne, .ibmPlexSerif, .libreBaskerville,
             .sourceSerif4, .lora: .serif
        case .jetBrainsMono, .ibmPlexMono, .geistMono: .mono
        }
    }

    var displayName: String {
        switch self {
        case .recursive: "Recursive"
        case .alanSans: "Alan Sans"
        case .comme: "Comme"
        case .donegalOne: "Donegal One"
        case .ibmPlexSerif: "IBM Plex Serif"
        case .libreBaskerville: "Libre Baskerville"
        case .sourceSerif4: "Source Serif 4"
        case .lora: "Lora"
        case .jetBrainsMono: "JetBrains Mono"
        case .ibmPlexMono: "IBM Plex Mono"
        case .geistMono: "Geist Mono"
        }
    }

    var shortDescription: String {
        switch self {
        case .recursive: "Variable casual sans"
        case .alanSans: "Clean geometric sans"
        case .comme: "Minimal geometric sans"
        case .donegalOne: "Sturdy transitional serif"
        case .ibmPlexSerif: "Contemporary slab serif"
        case .libreBaskerville: "Classic transitional serif"
        case .sourceSerif4: "Contemporary text serif"
        case .lora: "Calligraphic transitional serif"
        case .jetBrainsMono: "Tall x-height code font"
        case .ibmPlexMono: "Contemporary code font"
        case .geistMono: "Modern geometric mono"
        }
    }

    /// Family name as registered with the OS (used for UIFontDescriptor lookups).
    /// Defaults to displayName; override only when the OS name differs.
    var systemFamilyName: String {
        switch self {
        case .sourceSerif4: "Source Serif 4 Variable"
        default: displayName
        }
    }

    /// PostScript name used for CGFont registration verification
    var fontName: String {
        switch self {
        case .recursive: "Recursive"
        case .alanSans: "AlanSans-Light"
        case .comme: "Comme-Regular"
        case .donegalOne: "DonegalOne-Regular"
        case .ibmPlexSerif: "IBMPlexSerif-Regular"
        case .libreBaskerville: "LibreBaskerville-Regular"
        case .sourceSerif4: "SourceSerif4Variable-Roman"
        case .lora: "Lora-Regular"
        case .jetBrainsMono: "JetBrainsMono-Regular"
        case .ibmPlexMono: "IBMPlexMono"
        case .geistMono: "GeistMono-Regular"
        }
    }

    /// Whether this family has a monospace axis (only Recursive)
    var supportsMono: Bool { self == .recursive }

    /// Whether this font is a variable font (vs static weight files)
    var isVariable: Bool {
        switch self {
        case .recursive, .alanSans, .comme, .libreBaskerville,
             .sourceSerif4, .lora, .jetBrainsMono, .geistMono:
            true
        case .donegalOne, .ibmPlexSerif, .ibmPlexMono:
            false
        }
    }

    /// Axes available for user customization
    var customAxes: [FontAxis] {
        switch self {
        case .recursive: [.weight, .casual]
        case .sourceSerif4: [.weight, .opticalSize]
        case .alanSans, .comme, .libreBaskerville, .lora,
             .jetBrainsMono, .geistMono:
            [.weight]
        case .donegalOne, .ibmPlexSerif, .ibmPlexMono:
            [] // static fonts have no axes
        }
    }

    /// Weight range for the font
    var weightRange: ClosedRange<CGFloat> {
        switch self {
        case .recursive: 300...1000
        case .alanSans: 300...900
        case .comme: 100...900
        case .donegalOne: 400...400
        case .ibmPlexSerif: 300...700
        case .libreBaskerville: 400...700
        case .sourceSerif4: 200...900
        case .lora: 400...700
        case .jetBrainsMono: 100...800
        case .ibmPlexMono: 300...700
        case .geistMono: 100...900
        }
    }

    /// Font families suitable for body/UI text (sans + serif)
    static var textFamilies: [FontFamily] {
        allCases.filter { $0.category != .mono }
    }

    /// Font families suitable for code display (mono + recursive for its MONO axis)
    static var monoFamilies: [FontFamily] {
        // Recursive is included because it has a native MONO axis
        [.recursive] + allCases.filter { $0.category == .mono }
    }
}

/// Variable font axes that users can customize
enum FontAxis: String, CaseIterable, Sendable, Identifiable {
    case weight
    case casual
    case opticalSize

    var id: String { rawValue }

    /// CoreText variation axis tag (4-character code as UInt32)
    var tag: UInt32 {
        switch self {
        case .weight: 0x77676874      // 'wght'
        case .casual: 0x4341534C      // 'CASL'
        case .opticalSize: 0x6F70737A // 'opsz'
        }
    }

    var displayName: String {
        switch self {
        case .weight: "Weight"
        case .casual: "Casual"
        case .opticalSize: "Optical Size"
        }
    }

    func range(for family: FontFamily) -> ClosedRange<Double> {
        switch self {
        case .weight:
            let r = family.weightRange
            return Double(r.lowerBound)...Double(r.upperBound)
        case .casual: return 0...1
        case .opticalSize:
            switch family {
            case .sourceSerif4: return 8...60
            default: return 8...60
            }
        }
    }

    func defaultValue(for family: FontFamily) -> Double {
        switch self {
        case .weight: return 400
        case .casual: return 0.5
        case .opticalSize: return 14
        }
    }

    /// Whether this axis should be auto-set based on font size rather than user-controlled
    var isAutomatic: Bool {
        switch self {
        case .weight, .casual: false
        case .opticalSize: true
        }
    }

    var minLabel: String {
        switch self {
        case .weight: "Light"
        case .casual: "Linear"
        case .opticalSize: "Small"
        }
    }

    var maxLabel: String {
        switch self {
        case .weight: "Heavy"
        case .casual: "Casual"
        case .opticalSize: "Large"
        }
    }
}
