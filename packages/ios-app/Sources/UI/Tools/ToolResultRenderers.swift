import SwiftUI

struct ToolResultRenderer: View {
    let content: String
    let details: [String: AnyCodable]?
    let identity: ToolIdentity

    @Environment(\.colorScheme) private var colorScheme

    private var tint: TintedColors {
        TintedColors(accent: ToolPresentation.primitiveColor(for: identity), colorScheme: colorScheme)
    }

    var body: some View {
        if let document = ToolStructuredDocument.result(content: content, details: details) {
            ToolStructuredDocumentView(document: document, tint: tint)
        } else {
            ToolReadableResultText(text: content, tint: tint)
        }
    }
}

struct ToolStructuredDocumentView: View {
    let document: ToolStructuredDocument
    let tint: TintedColors

    var body: some View {
        ToolStructuredValueView(value: document.root, tint: tint, depth: 0)
    }
}

private struct ToolStructuredValueView: View {
    let value: ToolStructuredValue
    let tint: TintedColors
    let depth: Int

    private let visibleLimit = 8
    private let depthLimit = 3

    var body: some View {
        switch value {
        case .object(let fields):
            objectView(fields)
        case .array(let values):
            arrayView(values)
        case .string(let string):
            scalarText(string)
        case .number(let number):
            scalarText(number)
        case .boolean(let bool):
            scalarText(bool ? "Yes" : "No")
        case .null:
            scalarText("Not set", secondary: true)
        }
    }

    private func objectView(_ fields: [ToolStructuredField]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(fields.prefix(visibleLimit)).indices, id: \.self) { index in
                if index > 0 {
                    Divider()
                        .overlay(tint.accent.opacity(0.12))
                }
                ToolStructuredFieldView(
                    field: fields[index],
                    tint: tint,
                    depth: depth,
                    depthLimit: depthLimit
                )
            }
            if fields.count > visibleLimit {
                moreRow(count: fields.count - visibleLimit)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func arrayView(_ values: [ToolStructuredValue]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if values.isEmpty {
                scalarText("None", secondary: true)
            } else {
                ForEach(Array(values.prefix(visibleLimit)).indices, id: \.self) { index in
                    ToolStructuredArrayItemView(
                        index: index,
                        value: values[index],
                        tint: tint,
                        depth: depth,
                        depthLimit: depthLimit
                    )
                }
                if values.count > visibleLimit {
                    moreRow(count: values.count - visibleLimit)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func scalarText(_ text: String, secondary: Bool = false) -> some View {
        Text(text)
            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
            .foregroundStyle(secondary ? tint.subtle : .tronTextPrimary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func moreRow(count: Int) -> some View {
        Text("\(count) more \(count == 1 ? "item" : "items") in raw details")
            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
            .foregroundStyle(tint.subtle)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ToolStructuredFieldView: View {
    let field: ToolStructuredField
    let tint: TintedColors
    let depth: Int
    let depthLimit: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            StructuredDataFieldHeader(
                title: ToolPresentation.humanizeToolId(field.key),
                type: field.value.displayType,
                typeColor: tint.subtle
            )

            if depth >= depthLimit, field.value.containsNestedValues {
                Text("Additional structured detail is available in the raw result.")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                    .foregroundStyle(tint.body)
            } else {
                ToolStructuredValueView(value: field.value, tint: tint, depth: depth + 1)
            }
        }
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ToolStructuredArrayItemView: View {
    let index: Int
    let value: ToolStructuredValue
    let tint: TintedColors
    let depth: Int
    let depthLimit: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            StructuredDataFieldHeader(
                title: itemTitle ?? "Item \(index + 1)",
                type: value.displayType,
                typeColor: tint.subtle
            )

            if depth >= depthLimit, value.containsNestedValues {
                Text("Additional structured detail is available in the raw result.")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                    .foregroundStyle(tint.body)
            } else {
                ToolStructuredValueView(value: value, tint: tint, depth: depth + 1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.accent.opacity(0.07))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(tint.accent.opacity(0.14), lineWidth: 1)
                }
        }
    }

    private var itemTitle: String? {
        guard case .object(let fields) = value else { return nil }
        let preferredKeys = ["title", "name", "label", "summary", "id"]
        for key in preferredKeys {
            guard let value = fields.first(where: { $0.key == key })?.value else { continue }
            switch value {
            case .string(let text), .number(let text):
                return text.truncated(to: 100)
            case .boolean, .null, .object, .array:
                continue
            }
        }
        return nil
    }
}

struct ToolReadableResultText: View {
    let text: String
    let tint: TintedColors

    var body: some View {
        Text(text)
            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
            .foregroundStyle(tint.body)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ToolInvocationCodeBlock: View {
    let text: String

    var body: some View {
        Text(text)
            .font(TronTypography.code(size: TronTypography.sizeCaption, weight: .regular))
            .foregroundStyle(.tronTextSecondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
