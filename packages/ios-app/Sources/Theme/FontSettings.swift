import SwiftUI

/// Observable font settings that trigger real-time font updates across the app
@MainActor
@Observable
final class FontSettings {
    static let shared = FontSettings()

    /// Selected font family for proportional/sans UI text
    var selectedFamily: FontFamily {
        didSet {
            UserDefaults.standard.set(selectedFamily.rawValue, forKey: "fontFamily")
        }
    }

    /// CASL axis value (0 = Linear, 1 = Casual) — backward-compatible convenience for Recursive
    var casualAxis: Double {
        get { axisValue(for: .recursive, axis: .casual) }
        set { setAxisValue(for: .recursive, axis: .casual, value: newValue) }
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

    private init() {
        // Load selected family
        if let raw = UserDefaults.standard.string(forKey: "fontFamily"),
           let family = FontFamily(rawValue: raw) {
            self.selectedFamily = family
        } else {
            self.selectedFamily = .recursive
        }

        // Load axis values
        if let data = UserDefaults.standard.data(forKey: "fontAxisValues"),
           let decoded = try? JSONDecoder().decode([String: [String: Double]].self, from: data) {
            self.axisValues = decoded
        } else {
            self.axisValues = [:]
            // Migrate old casualAxis value if present
            if UserDefaults.standard.bool(forKey: "fontCasualAxisSet") {
                let oldValue = UserDefaults.standard.double(forKey: "fontCasualAxis")
                let migrated = oldValue == 0 && !UserDefaults.standard.bool(forKey: "fontCasualAxisSet")
                    ? 0.5
                    : oldValue
                axisValues[FontFamily.recursive.rawValue] = [FontAxis.casual.rawValue: migrated]
                persistAxisValues()
            }
        }
    }

    // MARK: - Init for testing

    /// Creates an isolated instance backed by the given UserDefaults suite (for testing)
    init(defaults: UserDefaults) {
        if let raw = defaults.string(forKey: "fontFamily"),
           let family = FontFamily(rawValue: raw) {
            self.selectedFamily = family
        } else {
            self.selectedFamily = .recursive
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
            UserDefaults.standard.set(data, forKey: "fontAxisValues")
        }
    }
}
