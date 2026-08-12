import SwiftUI

enum FontCategory: String, CaseIterable, Sendable {
    case sans, serif, mono
    var displayName: String { rawValue.capitalized }
}

/// The same font catalog and persisted keys used by the pre-gateway iOS app.
enum FontFamily: String, CaseIterable, Identifiable, Sendable {
    case recursive, alanSans, comme
    case donegalOne, ibmPlexSerif, libreBaskerville, sourceSerif4, lora
    case jetBrainsMono, ibmPlexMono, geistMono

    var id: String { rawValue }
    var category: FontCategory {
        switch self {
        case .recursive, .alanSans, .comme: .sans
        case .donegalOne, .ibmPlexSerif, .libreBaskerville, .sourceSerif4, .lora: .serif
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
    var systemFamilyName: String { self == .sourceSerif4 ? "Source Serif 4 Variable" : displayName }
    var fontName: String {
        switch self {
        case .recursive: "RecursiveSansLnr-Regular"
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
    var supportsMono: Bool { self == .recursive }
    var isMonospaced: Bool { category == .mono }
    var isVariable: Bool {
        switch self {
        case .recursive, .alanSans, .comme, .libreBaskerville, .sourceSerif4, .lora, .jetBrainsMono, .geistMono: true
        case .donegalOne, .ibmPlexSerif, .ibmPlexMono: false
        }
    }
    var customAxes: [FontAxis] {
        switch self {
        case .recursive: [.weight, .casual]
        case .sourceSerif4: [.weight, .opticalSize]
        case .alanSans, .comme, .libreBaskerville, .lora, .jetBrainsMono, .geistMono: [.weight]
        case .donegalOne, .ibmPlexSerif, .ibmPlexMono: []
        }
    }
    var weightRange: ClosedRange<Double> {
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
    static let textFamilies = allCases.filter { $0.category != .mono }
    static let monoFamilies: [FontFamily] = [.recursive] + allCases.filter { $0.category == .mono }
}

enum FontAxis: String, CaseIterable, Codable, Identifiable, Sendable {
    case weight, casual, opticalSize
    var id: String { rawValue }
    var tag: UInt32 {
        switch self {
        case .weight: 0x77676874
        case .casual: 0x4341534C
        case .opticalSize: 0x6F70737A
        }
    }
    var displayName: String {
        switch self { case .weight: "Weight"; case .casual: "Casual"; case .opticalSize: "Optical Size" }
    }
    func range(for family: FontFamily) -> ClosedRange<Double> {
        switch self { case .weight: family.weightRange; case .casual: 0...1; case .opticalSize: 8...60 }
    }
    func defaultValue(for family: FontFamily) -> Double {
        switch self { case .weight: 400; case .casual: 0.5; case .opticalSize: 14 }
    }
    var isAutomatic: Bool { self == .opticalSize }
    var minLabel: String { switch self { case .weight: "Light"; case .casual: "Linear"; case .opticalSize: "Small" } }
    var maxLabel: String { switch self { case .weight: "Heavy"; case .casual: "Casual"; case .opticalSize: "Large" } }
}

@MainActor
@Observable
final class FontSettings {
    static let shared = FontSettings(defaults: .standard)
    private let defaults: UserDefaults

    var selectedFamily: FontFamily { didSet { defaults.set(selectedFamily.rawValue, forKey: "fontFamily") } }
    var selectedMonoFamily: FontFamily { didSet { defaults.set(selectedMonoFamily.rawValue, forKey: "monoFontFamily") } }
    private var axisValues: [String: [String: Double]] {
        didSet {
            if let data = try? JSONEncoder().encode(axisValues) { defaults.set(data, forKey: "fontAxisValues") }
        }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        selectedFamily = defaults.string(forKey: "fontFamily").flatMap(FontFamily.init(rawValue:)) ?? .sourceSerif4
        let mono = defaults.string(forKey: "monoFontFamily").flatMap(FontFamily.init(rawValue:))
        selectedMonoFamily = mono.map { FontFamily.monoFamilies.contains($0) ? $0 : .recursive } ?? .recursive
        axisValues = defaults.data(forKey: "fontAxisValues")
            .flatMap { try? JSONDecoder().decode([String: [String: Double]].self, from: $0) } ?? [:]
    }

    func axisValue(for family: FontFamily, axis: FontAxis) -> Double {
        axisValues[family.rawValue]?[axis.rawValue] ?? axis.defaultValue(for: family)
    }
    func setAxisValue(for family: FontFamily, axis: FontAxis, value: Double) {
        var values = axisValues[family.rawValue] ?? [:]
        values[axis.rawValue] = value
        axisValues[family.rawValue] = values
    }
    func currentAxisValue(for axis: FontAxis) -> Double { axisValue(for: selectedFamily, axis: axis) }
}

enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case light, dark, auto
    var id: String { rawValue }
    var colorScheme: ColorScheme? { switch self { case .light: .light; case .dark: .dark; case .auto: nil } }
    var label: String { switch self { case .light: "Light"; case .dark: "Dark"; case .auto: "Auto" } }
    var icon: String { switch self { case .light: "sun.max.fill"; case .dark: "moon.fill"; case .auto: "circle.lefthalf.filled" } }
}

@MainActor
@Observable
final class AppearanceSettings {
    static let shared = AppearanceSettings()
    var mode: AppearanceMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "appearanceMode")
            UserDefaults.standard.removeObject(forKey: "appearance.v1")
        }
    }
    private init() {
        if let saved = UserDefaults.standard.string(forKey: "appearanceMode").flatMap(AppearanceMode.init(rawValue:)) { mode = saved }
        else if let legacy = UserDefaults.standard.string(forKey: "appearance.v1") { mode = legacy == "system" ? .auto : AppearanceMode(rawValue: legacy) ?? .dark }
        else { mode = .dark }
    }
}
