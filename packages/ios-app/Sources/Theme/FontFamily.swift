import Foundation

/// Available font families for the app's UI text
enum FontFamily: String, CaseIterable, Sendable, Identifiable {
    case recursive
    case alanSans
    case comme
    case ibmPlexSerif
    case vollkorn

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .recursive: "Recursive"
        case .alanSans: "Alan Sans"
        case .comme: "Comme"
        case .ibmPlexSerif: "IBM Plex Serif"
        case .vollkorn: "Vollkorn"
        }
    }

    var shortDescription: String {
        switch self {
        case .recursive: "Variable casual sans"
        case .alanSans: "Clean geometric sans"
        case .comme: "Minimal geometric sans"
        case .ibmPlexSerif: "Contemporary slab serif"
        case .vollkorn: "Warm book serif"
        }
    }

    /// PostScript name used for CGFont registration verification
    var fontName: String {
        switch self {
        case .recursive: "Recursive"
        case .alanSans: "AlanSans-Light"
        case .comme: "Comme-Regular"
        case .ibmPlexSerif: "IBMPlexSerif-Regular"
        case .vollkorn: "Vollkorn-Regular"
        }
    }

    /// Whether this family has a monospace axis (only Recursive)
    var supportsMono: Bool { self == .recursive }

    /// Whether this font is a variable font (vs static weight files)
    var isVariable: Bool {
        switch self {
        case .recursive, .alanSans, .comme, .vollkorn: true
        case .ibmPlexSerif: false
        }
    }

    /// Custom axes available for this family (excludes weight — handled separately)
    var customAxes: [FontAxis] {
        switch self {
        case .recursive: [.casual]
        case .alanSans, .comme, .ibmPlexSerif, .vollkorn: []
        }
    }

    /// Weight range for the font
    var weightRange: ClosedRange<CGFloat> {
        switch self {
        case .recursive: 300...1000
        case .alanSans: 300...900
        case .comme: 100...900
        case .ibmPlexSerif: 300...700
        case .vollkorn: 400...900
        }
    }
}

/// Variable font axes beyond weight that users can customize
enum FontAxis: String, CaseIterable, Sendable, Identifiable {
    case casual

    var id: String { rawValue }

    /// CoreText variation axis tag (4-character code as UInt32)
    var tag: UInt32 {
        switch self {
        case .casual: 0x4341534C // 'CASL'
        }
    }

    var displayName: String {
        switch self {
        case .casual: "Casual"
        }
    }

    func range(for family: FontFamily) -> ClosedRange<Double> {
        switch self {
        case .casual: return 0...1
        }
    }

    func defaultValue(for family: FontFamily) -> Double {
        switch self {
        case .casual: return 0.5
        }
    }

    var minLabel: String {
        switch self {
        case .casual: "Linear"
        }
    }

    var maxLabel: String {
        switch self {
        case .casual: "Casual"
        }
    }
}
