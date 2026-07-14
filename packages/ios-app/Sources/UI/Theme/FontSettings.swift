import SwiftUI

/// Observable font settings that trigger real-time font updates across the app
@MainActor
@Observable
final class FontSettings {
    static let shared = FontSettings(defaults: AppRuntimeStorage.current.defaults)

    private let defaults: UserDefaults

    /// Selected font family for proportional UI text
    var selectedFamily: FontFamily {
        didSet {
            defaults.set(selectedFamily.rawValue, forKey: "fontFamily")
        }
    }

    /// Selected font family for monospace/code text
    var selectedMonoFamily: FontFamily {
        didSet {
            defaults.set(selectedMonoFamily.rawValue, forKey: "monoFontFamily")
        }
    }

    /// Per-font axis values: [familyRawValue: [axisRawValue: Double]]
    private var axisValues: [String: [String: Double]] {
        didSet { persistAxisValues() }
    }

    // MARK: - Axis Access

    func axisValue(for family: FontFamily, axis: FontAxis) -> Double {
        axisValues[family.rawValue]?[axis.rawValue] ?? axis.defaultValue(for: family)
    }

    func setAxisValue(for family: FontFamily, axis: FontAxis, value: Double) {
        var familyValues = axisValues[family.rawValue] ?? [:]
        familyValues[axis.rawValue] = value
        axisValues[family.rawValue] = familyValues
    }

    func currentAxisValue(for axis: FontAxis) -> Double {
        axisValue(for: selectedFamily, axis: axis)
    }

    // MARK: - Init

    /// Creates an instance backed by the supplied persistence domain.
    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let raw = defaults.string(forKey: "fontFamily"),
           let family = FontFamily(rawValue: raw) {
            self.selectedFamily = family
        } else {
            self.selectedFamily = .sourceSerif4
        }

        if let raw = defaults.string(forKey: "monoFontFamily"),
           let family = FontFamily(rawValue: raw),
           FontFamily.monoFamilies.contains(family) {
            self.selectedMonoFamily = family
        } else {
            self.selectedMonoFamily = .recursive
        }

        if let data = defaults.data(forKey: "fontAxisValues"),
           let decoded = try? JSONDecoder().decode([String: [String: Double]].self, from: data) {
            self.axisValues = decoded
        } else {
            self.axisValues = [:]
        }
    }

    private func persistAxisValues() {
        if let data = try? JSONEncoder().encode(axisValues) {
            defaults.set(data, forKey: "fontAxisValues")
        }
    }
}
