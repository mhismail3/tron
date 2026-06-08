import SwiftUI

@available(iOS 26.0, *)
struct CapabilityResultRenderer: View {
    let content: String
    let details: [String: AnyCodable]?
    let identity: CapabilityIdentity

    @Environment(\.colorScheme) private var colorScheme

    private var tint: TintedColors {
        TintedColors(accent: CapabilityPresentation.primitiveColor(for: identity), colorScheme: colorScheme)
    }

    var body: some View {
        if let details, let pretty = Self.prettyJSON(details), !pretty.isEmpty {
            CapabilityInvocationCodeBlock(text: pretty)
        } else if looksLikeJSON(content), let pretty = Self.prettyJSONString(content) {
            CapabilityInvocationCodeBlock(text: pretty)
        } else {
            CapabilityInvocationCodeBlock(text: content)
        }
    }

    private func looksLikeJSON(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("{") || trimmed.hasPrefix("[")
    }

    private static func prettyJSON(_ value: [String: AnyCodable]) -> String? {
        let raw = value.mapValues(\.value)
        guard JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func prettyJSONString(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        else { return nil }
        return String(data: pretty, encoding: .utf8)
    }
}

@available(iOS 26.0, *)
struct CapabilityInvocationCodeBlock: View {
    let text: String

    var body: some View {
        Text(text)
            .font(TronTypography.code(size: TronTypography.sizeCaption, weight: .regular))
            .foregroundStyle(.tronTextSecondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.tronSurface.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
