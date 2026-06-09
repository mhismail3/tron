import SwiftUI

extension GeneratedRuntimeSurfaceView {
    func presentationIcon(for action: UiActionDTO?) -> String {
        guard let icon = action?.presentation?.icon?.trimmingCharacters(in: .whitespacesAndNewlines),
              !icon.isEmpty
        else {
            return "arrow.right"
        }
        return icon
    }

    func disclosureIcon(for component: UiComponentDTO) -> String {
        let title = (component.props?.string("title") ?? component.type).lowercased()
        if title.contains("create") { return "plus.circle" }
        if title.contains("history") { return "clock.arrow.circlepath" }
        if title.contains("snippet") { return "text.quote" }
        return "rectangle.expand.vertical"
    }

    func formattedValue(_ value: AnyCodable?) -> String {
        if let string = value?.stringValue { return string }
        if let int = value?.intValue { return "\(int)" }
        if let double = value?.doubleValue { return "\(double)" }
        if let bool = value?.boolValue { return bool ? "true" : "false" }
        return "\(value?.value ?? "")"
    }

    func arrayStrings(_ value: AnyCodable?) -> [String] {
        value?.arrayValue?.compactMap { $0 as? String } ?? []
    }

    func arrayDictionaries(_ value: AnyCodable?) -> [[String: Any]] {
        value?.arrayValue?.compactMap { $0 as? [String: Any] } ?? []
    }

    func rowPreview(_ row: [String: Any]) -> String {
        row.keys.sorted().map { "\($0): \(row[$0] ?? "")" }.joined(separator: "  ")
    }
}
