import Foundation

private struct ExtensionDynamicCodingKey: CodingKey {
    package let stringValue: String
    package let intValue: Int? = nil
    package init?(stringValue: String) { self.stringValue = stringValue }
    package init?(intValue: Int) { return nil }
}

private extension KeyedDecodingContainer {
    func decodeBoundedArray<T: Decodable>(_ type: T.Type, forKey key: Key, maximum: Int) throws -> [T] {
        var container = try superDecoder(forKey: key).unkeyedContainer()
        var result: [T] = []
        result.reserveCapacity(min(container.count ?? 0, maximum))
        while !container.isAtEnd {
            guard result.count < maximum else {
                throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Extension collection exceeds its bounded capacity")
            }
            result.append(try container.decode(T.self))
        }
        return result
    }

    func decodeBoundedArrayIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key, maximum: Int) throws -> [T]? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        return try decodeBoundedArray(type, forKey: key, maximum: maximum)
    }

    func decodeBoundedStringDictionary(forKey key: Key, maximum: Int) throws -> [String: String] {
        let container = try superDecoder(forKey: key).container(keyedBy: ExtensionDynamicCodingKey.self)
        guard container.allKeys.count <= maximum else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Extension dictionary exceeds its bounded capacity")
        }
        return try Dictionary(uniqueKeysWithValues: container.allKeys.map { ($0.stringValue, try container.decode(String.self, forKey: $0)) })
    }

    func decodeBoundedStringDictionaryIfPresent(forKey key: Key, maximum: Int) throws -> [String: String]? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        return try decodeBoundedStringDictionary(forKey: key, maximum: maximum)
    }

    func decodeBoundedString(forKey key: Key, maximumBytes: Int) throws -> String {
        let value = try decode(String.self, forKey: key)
        guard value.utf8.count <= maximumBytes else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Extension string exceeds its bounded capacity")
        }
        return value
    }

    func decodeBoundedStringIfPresent(forKey key: Key, maximumBytes: Int) throws -> String? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        return try decodeBoundedString(forKey: key, maximumBytes: maximumBytes)
    }
}

package struct ExtensionFormOption: Codable, Hashable, Sendable, Identifiable {
    package let id: String
    package let label: String
    package let description: String?

    private enum CodingKeys: String, CodingKey { case id, label, description }
    package init(id: String, label: String, description: String? = nil) {
        self.id = id; self.label = label; self.description = description
    }
    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeBoundedString(forKey: .id, maximumBytes: 256)
        label = try container.decodeBoundedString(forKey: .label, maximumBytes: 2 * 1_024)
        description = try container.decodeBoundedStringIfPresent(forKey: .description, maximumBytes: 2 * 1_024)
    }
}

package struct ExtensionFormQuestion: Codable, Hashable, Sendable, Identifiable {
    package let id: String
    package let header: String?
    package let question: String
    package let context: String?
    package let options: [ExtensionFormOption]
    package let multiSelect: Bool
    package let allowOther: Bool

    private enum CodingKeys: String, CodingKey { case id, header, question, context, options, multiSelect, allowOther }
    package init(id: String, header: String? = nil, question: String, context: String? = nil, options: [ExtensionFormOption], multiSelect: Bool, allowOther: Bool) {
        self.id = id; self.header = header; self.question = question; self.context = context
        self.options = options; self.multiSelect = multiSelect; self.allowOther = allowOther
    }
    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeBoundedString(forKey: .id, maximumBytes: 256)
        header = try container.decodeBoundedStringIfPresent(forKey: .header, maximumBytes: 256)
        question = try container.decodeBoundedString(forKey: .question, maximumBytes: 4 * 1_024)
        context = try container.decodeBoundedStringIfPresent(forKey: .context, maximumBytes: 32 * 1_024)
        options = try container.decodeBoundedArray(ExtensionFormOption.self, forKey: .options, maximum: 4)
        multiSelect = try container.decode(Bool.self, forKey: .multiSelect)
        allowOther = try container.decode(Bool.self, forKey: .allowOther)
    }
}

package struct ExtensionFormDescriptor: Codable, Hashable, Sendable {
    package let version: Int
    package let title: String
    package let questions: [ExtensionFormQuestion]
    package let allowCancel: Bool

    private enum CodingKeys: String, CodingKey { case version, title, questions, allowCancel }
    package init(version: Int, title: String, questions: [ExtensionFormQuestion], allowCancel: Bool) {
        self.version = version; self.title = title; self.questions = questions; self.allowCancel = allowCancel
    }
    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        title = try container.decodeBoundedString(forKey: .title, maximumBytes: 4 * 1_024)
        questions = try container.decodeBoundedArray(ExtensionFormQuestion.self, forKey: .questions, maximum: 4)
        allowCancel = try container.decode(Bool.self, forKey: .allowCancel)
    }
}

package struct ExtensionFormQuestionAnswer: Codable, Hashable, Sendable {
    package let questionId: String
    package let optionIds: [String]
    package let other: String?
    package init(
        questionId: String,
        optionIds: [String],
        other: String?
    ) {
        self.questionId = questionId
        self.optionIds = optionIds
        self.other = other
    }

}

package struct ExtensionFormAnswer: Codable, Hashable, Sendable {
    package let version: Int
    package let answers: [ExtensionFormQuestionAnswer]
    package init(
        version: Int,
        answers: [ExtensionFormQuestionAnswer]
    ) {
        self.version = version
        self.answers = answers
    }

}

package enum ExtensionInteractionResponsePolicy {
    package static let maximumResponseBytes = 192 * 1_024
    package static let maximumOtherBytes = 32 * 1_024

    package static func primitiveTextError(_ text: String) -> String? {
        text.utf8.count <= maximumResponseBytes ? nil : "Response is too large (maximum 192 KiB)."
    }

    package static func formError(_ answer: ExtensionFormAnswer, descriptor: ExtensionFormDescriptor) -> String? {
        guard answer.version == 1, answer.answers.count == descriptor.questions.count else {
            return "Every question needs an answer."
        }
        let byQuestion = Dictionary(grouping: answer.answers, by: \.questionId)
        guard byQuestion.count == descriptor.questions.count,
              descriptor.questions.allSatisfy({ byQuestion[$0.id]?.count == 1 }) else {
            return "The answer does not match this form."
        }
        for question in descriptor.questions {
            guard let value = byQuestion[question.id]?.first else { return "Every question needs an answer." }
            let allowed = Set(question.options.map(\.id))
            guard Set(value.optionIds).count == value.optionIds.count,
                  value.optionIds.allSatisfy(allowed.contains),
                  question.multiSelect || value.optionIds.count <= 1,
                  question.multiSelect || value.optionIds.isEmpty || value.other == nil else {
                return "Choose an answer for every question."
            }
            if let other = value.other {
                guard question.allowOther,
                      !other.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return "Choose an answer for every question."
                }
                if other.utf8.count > maximumOtherBytes {
                    return "An Other response is too large (maximum 32 KiB)."
                }
                if containsUnsafeControl(other, preservingNewlines: true) {
                    return "An Other response contains unsupported control characters."
                }
            }
            if value.optionIds.isEmpty && value.other == nil {
                return "Choose an answer for every question."
            }
        }
        guard let encoded = try? JSONEncoder.gateway.encode(answer), encoded.count <= maximumResponseBytes else {
            return "The answer is too large (maximum 192 KiB)."
        }
        return nil
    }

    private static func containsUnsafeControl(_ value: String, preservingNewlines: Bool) -> Bool {
        value.unicodeScalars.contains { scalar in
            let code = scalar.value
            if code == 0x0a || code == 0x0d { return !preservingNewlines }
            return code < 0x20 || (0x7f...0x9f).contains(code)
        }
    }
}

package struct ExtensionInteraction: Codable, Hashable, Identifiable, Sendable {
    package enum Method: String, Codable, Sendable { case select, confirm, input, editor, form }
    package let id: String
    package let hostEpoch: String
    package let presentationRevision: Int
    package let method: Method
    package let title: String
    package let message: String?
    package let options: [String]?
    package let placeholder: String?
    package let prefill: String?
    package let expiresAt: String?
    package let form: ExtensionFormDescriptor?
    package let owner: ExtensionOwner?
    package let invocationId: String?
    package let operationId: String?

    package init(id: String, hostEpoch: String, presentationRevision: Int, method: Method, title: String, message: String? = nil, options: [String]? = nil, placeholder: String? = nil, prefill: String? = nil, expiresAt: String? = nil, form: ExtensionFormDescriptor? = nil, owner: ExtensionOwner? = nil, invocationId: String? = nil, operationId: String? = nil) {
        self.id = id; self.hostEpoch = hostEpoch; self.presentationRevision = presentationRevision; self.method = method
        self.title = title; self.message = message; self.options = options; self.placeholder = placeholder; self.prefill = prefill; self.expiresAt = expiresAt; self.form = form
        self.owner = owner; self.invocationId = invocationId; self.operationId = operationId
    }
    private enum CodingKeys: String, CodingKey { case id, hostEpoch, presentationRevision, method, title, message, options, placeholder, prefill, expiresAt, form, owner, invocationId, operationId }
    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        hostEpoch = try container.decode(String.self, forKey: .hostEpoch)
        presentationRevision = try container.decode(Int.self, forKey: .presentationRevision)
        method = try container.decode(Method.self, forKey: .method)
        title = try container.decode(String.self, forKey: .title)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        options = try container.decodeBoundedArrayIfPresent(String.self, forKey: .options, maximum: 64)
        placeholder = try container.decodeIfPresent(String.self, forKey: .placeholder)
        prefill = try container.decodeIfPresent(String.self, forKey: .prefill)
        expiresAt = try container.decodeIfPresent(String.self, forKey: .expiresAt)
        form = try container.decodeIfPresent(ExtensionFormDescriptor.self, forKey: .form)
        owner = try container.decodeIfPresent(ExtensionOwner.self, forKey: .owner)
        invocationId = try container.decodeIfPresent(String.self, forKey: .invocationId)
        operationId = try container.decodeIfPresent(String.self, forKey: .operationId)
        guard invocationId.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true,
              operationId.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true else {
            throw DecodingError.dataCorruptedError(
                forKey: .invocationId,
                in: container,
                debugDescription: "Extension interaction causality is invalid"
            )
        }
    }
}

package struct ExtensionOwner: Codable, Hashable, Sendable {
    package let id: String
    package let title: String
    package let source: String
    package init(
        id: String,
        title: String,
        source: String
    ) {
        self.id = id
        self.title = title
        self.source = source
    }

}

package struct ExtensionWidget: Codable, Hashable, Identifiable, Sendable {
    package enum Placement: String, Codable, Sendable { case aboveEditor, belowEditor }
    package let key: String
    package var revision: Int? = nil
    package let lines: [String]
    package let placement: Placement
    package let owner: ExtensionOwner?
    package var id: String { key }

    package init(key: String, revision: Int? = nil, lines: [String], placement: Placement, owner: ExtensionOwner? = nil) {
        self.key = key; self.revision = revision; self.lines = lines; self.placement = placement; self.owner = owner
    }
    private enum CodingKeys: String, CodingKey { case key, revision, lines, placement, owner }
    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        revision = try container.decodeIfPresent(Int.self, forKey: .revision)
        lines = try container.decodeBoundedArray(String.self, forKey: .lines, maximum: 12)
        placement = try container.decode(Placement.self, forKey: .placement)
        owner = try container.decodeIfPresent(ExtensionOwner.self, forKey: .owner)
    }
}

package struct ExtensionPresentationDiagnostic: Codable, Hashable, Sendable {
    package var code: String
    package var message: String
}

package struct ExtensionSemanticState: Codable, Hashable, Sendable {
    package struct Working: Codable, Hashable, Sendable {
        package struct Indicator: Codable, Hashable, Sendable {
            package enum Kind: String, Codable, Sendable { case `default`, hidden, `static`, animated }
            package var kind: Kind
            package var frames: [String]
            var intervalMs: Int?

            package init(kind: Kind, frames: [String], intervalMs: Int? = nil) {
                self.kind = kind; self.frames = frames; self.intervalMs = intervalMs
            }
            private enum CodingKeys: String, CodingKey { case kind, frames, intervalMs }
            package init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                kind = try container.decode(Kind.self, forKey: .kind)
                frames = try container.decodeBoundedArray(String.self, forKey: .frames, maximum: 32)
                intervalMs = try container.decodeIfPresent(Int.self, forKey: .intervalMs)
            }
        }
        package var message: String?
        package var visible: Bool
        package var indicator: Indicator? = nil

        package init(message: String? = nil, visible: Bool, indicator: Indicator? = nil) {
            self.message = message
            self.visible = visible
            self.indicator = indicator
        }
    }
    package var statuses: [String: String]
    package var statusOwners: [String: ExtensionOwner]
    package var working: Working
    package var hiddenThinkingLabel: String?
    package var widgets: [ExtensionWidget]
    package var title: String?
    package var toolsExpanded: Bool
    package var editorRevision: Int
    package var editorText: String

    package init(statuses: [String: String], statusOwners: [String: ExtensionOwner] = [:], working: Working, hiddenThinkingLabel: String? = nil, widgets: [ExtensionWidget], title: String? = nil, toolsExpanded: Bool, editorRevision: Int, editorText: String) {
        self.statuses = statuses; self.statusOwners = statusOwners; self.working = working; self.hiddenThinkingLabel = hiddenThinkingLabel; self.widgets = widgets
        self.title = title; self.toolsExpanded = toolsExpanded; self.editorRevision = editorRevision; self.editorText = editorText
    }
    private enum CodingKeys: String, CodingKey { case statuses, statusOwners, working, hiddenThinkingLabel, widgets, title, toolsExpanded, editorRevision, editorText }
    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        statuses = try container.decodeBoundedStringDictionary(forKey: .statuses, maximum: 32)
        statusOwners = try container.decodeIfPresent([String: ExtensionOwner].self, forKey: .statusOwners) ?? [:]
        working = try container.decode(Working.self, forKey: .working)
        hiddenThinkingLabel = try container.decodeIfPresent(String.self, forKey: .hiddenThinkingLabel)
        widgets = try container.decodeBoundedArray(ExtensionWidget.self, forKey: .widgets, maximum: 24)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        toolsExpanded = try container.decode(Bool.self, forKey: .toolsExpanded)
        editorRevision = try container.decode(Int.self, forKey: .editorRevision)
        editorText = try container.decode(String.self, forKey: .editorText)
    }
}

package struct ExtensionFrameStyle: Codable, Hashable, Sendable {
    package var bold: Bool? = nil
    package var dim: Bool? = nil
    package var italic: Bool? = nil
    package var underline: Bool? = nil
    package var inverse: Bool? = nil
    package var strike: Bool? = nil
    package var foreground: String? = nil
    package var background: String? = nil
    package var link: String? = nil

    package init(
        bold: Bool? = nil,
        dim: Bool? = nil,
        italic: Bool? = nil,
        underline: Bool? = nil,
        inverse: Bool? = nil,
        strike: Bool? = nil,
        foreground: String? = nil,
        background: String? = nil,
        link: String? = nil
    ) {
        self.bold = bold
        self.dim = dim
        self.italic = italic
        self.underline = underline
        self.inverse = inverse
        self.strike = strike
        self.foreground = foreground
        self.background = background
        self.link = link
    }
}
package struct ExtensionFrameRun: Codable, Hashable, Sendable {
    package var text: String
    package var style: ExtensionFrameStyle

    package init(text: String, style: ExtensionFrameStyle) {
        self.text = text
        self.style = style
    }
}
package struct ExtensionFrameLine: Codable, Hashable, Sendable {
    package var plainText: String
    package var runs: [ExtensionFrameRun]
    package init(plainText: String, runs: [ExtensionFrameRun]) { self.plainText = plainText; self.runs = runs }
    private enum CodingKeys: String, CodingKey { case plainText, runs }
    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        plainText = try container.decode(String.self, forKey: .plainText)
        runs = try container.decodeBoundedArray(ExtensionFrameRun.self, forKey: .runs, maximum: 4_096)
    }
}
package struct ExtensionFrameCursor: Codable, Hashable, Sendable { var row: Int; var column: Int }
package struct ExtensionFrame: Codable, Hashable, Sendable {
    package var width: Int
    package var height: Int
    package var lines: [ExtensionFrameLine]
    package var plainText: String
    package var cursor: ExtensionFrameCursor?
    package init(width: Int, height: Int, lines: [ExtensionFrameLine], plainText: String, cursor: ExtensionFrameCursor? = nil) {
        self.width = width; self.height = height; self.lines = lines; self.plainText = plainText; self.cursor = cursor
    }
    private enum CodingKeys: String, CodingKey { case width, height, lines, plainText, cursor }
    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        width = try container.decode(Int.self, forKey: .width)
        height = try container.decode(Int.self, forKey: .height)
        lines = try container.decodeBoundedArray(ExtensionFrameLine.self, forKey: .lines, maximum: 120)
        plainText = try container.decode(String.self, forKey: .plainText)
        cursor = try container.decodeIfPresent(ExtensionFrameCursor.self, forKey: .cursor)
    }
}

package struct ExtensionSurface: Codable, Hashable, Identifiable, Sendable {
    package enum Kind: String, Codable, Sendable {
        case header, footer, widget, custom, overlay, editor, toolRenderer, messageRenderer, entryRenderer, markdown, unknown
        package init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .unknown
        }
    }
    package enum Placement: String, Codable, Sendable { case header, footer, aboveEditor, belowEditor, transcript, overlay, fullscreen }
    package enum Lifecycle: String, Codable, Sendable { case retained, blocking, transient, restored }
    package enum InputMode: String, Codable, Sendable { case none, keys, textAndKeys }
    package struct Provenance: Codable, Hashable, Sendable {
        package var source: String?
        package var path: String?

        package init(source: String? = nil, path: String? = nil) {
            self.source = source
            self.path = path
        }
    }
    package let id: String
    package var kind: Kind
    package var placement: Placement
    package var lifecycle: Lifecycle
    package var targetId: String?
    package var provenance: Provenance?
    package var revision: Int
    package var focused: Bool
    package var inputMode: InputMode
    package var frame: ExtensionFrame
    package init(
        id: String,
        kind: Kind,
        placement: Placement,
        lifecycle: Lifecycle,
        targetId: String? = nil,
        provenance: Provenance? = nil,
        revision: Int,
        focused: Bool,
        inputMode: InputMode,
        frame: ExtensionFrame
    ) {
        self.id = id
        self.kind = kind
        self.placement = placement
        self.lifecycle = lifecycle
        self.targetId = targetId
        self.provenance = provenance
        self.revision = revision
        self.focused = focused
        self.inputMode = inputMode
        self.frame = frame
    }

}

package struct ExtensionInputLease: Codable, Hashable, Sendable {
    package var id: String
    package var connectionId: String
    package var surfaceId: String
    package var surfaceRevision: Int
    package var acquiredAt: String

    package init(
        id: String,
        connectionId: String,
        surfaceId: String,
        surfaceRevision: Int,
        acquiredAt: String
    ) {
        self.id = id
        self.connectionId = connectionId
        self.surfaceId = surfaceId
        self.surfaceRevision = surfaceRevision
        self.acquiredAt = acquiredAt
    }
}

package struct ExtensionPresentationState: Codable, Hashable, Sendable {
    package struct Projection: Codable, Hashable, Sendable {
        package struct OmittedSurface: Codable, Hashable, Sendable {
            package var id: String
            package var revision: Int

            package init(id: String, revision: Int) {
                self.id = id
                self.revision = revision
            }
        }
        package var complete: Bool
        package var omitted: [String]
        package var omittedSurfaces: [OmittedSurface]?
        package init(complete: Bool, omitted: [String], omittedSurfaces: [OmittedSurface]? = nil) {
            self.complete = complete; self.omitted = omitted; self.omittedSurfaces = omittedSurfaces
        }
        private enum CodingKeys: String, CodingKey { case complete, omitted, omittedSurfaces }
        package init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            complete = try container.decode(Bool.self, forKey: .complete)
            omitted = try container.decodeBoundedArray(String.self, forKey: .omitted, maximum: 16)
            omittedSurfaces = try container.decodeBoundedArrayIfPresent(OmittedSurface.self, forKey: .omittedSurfaces, maximum: 64)
        }
    }
    package var version: Int
    package var hostEpoch: String
    package var revision: Int
    package var capabilities: [String]
    package var diagnostics: [ExtensionPresentationDiagnostic]
    package var semanticState: ExtensionSemanticState
    package var surfaces: [ExtensionSurface]
    package var pendingInteractions: [ExtensionInteraction]
    package var inputLease: ExtensionInputLease?
    package var projection: Projection?
    package init(version: Int, hostEpoch: String, revision: Int, capabilities: [String], diagnostics: [ExtensionPresentationDiagnostic], semanticState: ExtensionSemanticState, surfaces: [ExtensionSurface], pendingInteractions: [ExtensionInteraction], inputLease: ExtensionInputLease? = nil, projection: Projection? = nil) {
        self.version = version; self.hostEpoch = hostEpoch; self.revision = revision; self.capabilities = capabilities; self.diagnostics = diagnostics
        self.semanticState = semanticState; self.surfaces = surfaces; self.pendingInteractions = pendingInteractions; self.inputLease = inputLease; self.projection = projection
    }
    private enum CodingKeys: String, CodingKey { case version, hostEpoch, revision, capabilities, diagnostics, semanticState, surfaces, pendingInteractions, inputLease, projection }
    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        hostEpoch = try container.decode(String.self, forKey: .hostEpoch)
        revision = try container.decode(Int.self, forKey: .revision)
        capabilities = try container.decodeBoundedArray(String.self, forKey: .capabilities, maximum: 128)
        diagnostics = try container.decodeBoundedArray(ExtensionPresentationDiagnostic.self, forKey: .diagnostics, maximum: 64)
        semanticState = try container.decode(ExtensionSemanticState.self, forKey: .semanticState)
        surfaces = try container.decodeBoundedArray(ExtensionSurface.self, forKey: .surfaces, maximum: 64)
        pendingInteractions = try container.decodeBoundedArray(ExtensionInteraction.self, forKey: .pendingInteractions, maximum: 8)
        inputLease = try container.decodeIfPresent(ExtensionInputLease.self, forKey: .inputLease)
        projection = try container.decodeIfPresent(Projection.self, forKey: .projection)
    }
}

package struct ExtensionSemanticPatch: Codable, Hashable, Sendable {
    package var statuses: [String: String]?
    package var statusOwners: [String: ExtensionOwner]?
    package var working: ExtensionSemanticState.Working?
    package var hiddenThinkingLabel: JSONValue?
    package var widgets: [ExtensionWidget]?
    package var title: JSONValue?
    package var toolsExpanded: Bool?
    package var editorRevision: Int?
    package var editorText: String?
    package var editorAction: String?
    package var editorDelta: String?
    package var editorOperationId: String?

    private enum CodingKeys: String, CodingKey {
        case statuses, statusOwners, working, hiddenThinkingLabel, widgets, title, toolsExpanded
        case editorRevision, editorText, editorAction, editorDelta, editorOperationId
    }
    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        statuses = try container.decodeBoundedStringDictionaryIfPresent(forKey: .statuses, maximum: 32)
        statusOwners = try container.decodeIfPresent([String: ExtensionOwner].self, forKey: .statusOwners)
        working = try container.decodeIfPresent(ExtensionSemanticState.Working.self, forKey: .working)
        hiddenThinkingLabel = container.contains(.hiddenThinkingLabel)
            ? try container.decode(JSONValue.self, forKey: .hiddenThinkingLabel) : nil
        widgets = try container.decodeBoundedArrayIfPresent(ExtensionWidget.self, forKey: .widgets, maximum: 24)
        title = container.contains(.title) ? try container.decode(JSONValue.self, forKey: .title) : nil
        toolsExpanded = try container.decodeIfPresent(Bool.self, forKey: .toolsExpanded)
        editorRevision = try container.decodeIfPresent(Int.self, forKey: .editorRevision)
        editorText = try container.decodeIfPresent(String.self, forKey: .editorText)
        editorAction = try container.decodeIfPresent(String.self, forKey: .editorAction)
        editorDelta = try container.decodeIfPresent(String.self, forKey: .editorDelta)
        editorOperationId = try container.decodeIfPresent(String.self, forKey: .editorOperationId)
    }
    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(statuses, forKey: .statuses)
        try container.encodeIfPresent(statusOwners, forKey: .statusOwners)
        try container.encodeIfPresent(working, forKey: .working)
        if let hiddenThinkingLabel { try container.encode(hiddenThinkingLabel, forKey: .hiddenThinkingLabel) }
        try container.encodeIfPresent(widgets, forKey: .widgets)
        if let title { try container.encode(title, forKey: .title) }
        try container.encodeIfPresent(toolsExpanded, forKey: .toolsExpanded)
        try container.encodeIfPresent(editorRevision, forKey: .editorRevision)
        try container.encodeIfPresent(editorText, forKey: .editorText)
        try container.encodeIfPresent(editorAction, forKey: .editorAction)
        try container.encodeIfPresent(editorDelta, forKey: .editorDelta)
        try container.encodeIfPresent(editorOperationId, forKey: .editorOperationId)
    }
}

package struct ExtensionPresentationMutation: Codable, Hashable, Sendable {
    package var version: Int
    package var hostEpoch: String
    package var revision: Int
    package var semantic: ExtensionSemanticPatch?
    package var interactionList: [ExtensionInteraction]?
    package var surfaceUpserts: [ExtensionSurface]?
    package var surfaceRemovals: [String]?
    package var inputLease: JSONValue?
    package var inputLeasePresent: Bool
    package var capabilities: [String]?
    package var diagnostics: [ExtensionPresentationDiagnostic]?

    private enum CodingKeys: String, CodingKey {
        case version, hostEpoch, revision, semantic, interactionList, surfaceUpserts
        case surfaceRemovals, inputLease, capabilities, diagnostics
    }
    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        hostEpoch = try container.decode(String.self, forKey: .hostEpoch)
        revision = try container.decode(Int.self, forKey: .revision)
        semantic = try container.decodeIfPresent(ExtensionSemanticPatch.self, forKey: .semantic)
        interactionList = try container.decodeBoundedArrayIfPresent(ExtensionInteraction.self, forKey: .interactionList, maximum: 8)
        surfaceUpserts = try container.decodeBoundedArrayIfPresent(ExtensionSurface.self, forKey: .surfaceUpserts, maximum: 64)
        surfaceRemovals = try container.decodeBoundedArrayIfPresent(String.self, forKey: .surfaceRemovals, maximum: 64)
        inputLeasePresent = container.contains(.inputLease)
        inputLease = inputLeasePresent ? try container.decode(JSONValue.self, forKey: .inputLease) : nil
        capabilities = try container.decodeBoundedArrayIfPresent(String.self, forKey: .capabilities, maximum: 128)
        diagnostics = try container.decodeBoundedArrayIfPresent(ExtensionPresentationDiagnostic.self, forKey: .diagnostics, maximum: 64)
    }
    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(hostEpoch, forKey: .hostEpoch)
        try container.encode(revision, forKey: .revision)
        try container.encodeIfPresent(semantic, forKey: .semantic)
        try container.encodeIfPresent(interactionList, forKey: .interactionList)
        try container.encodeIfPresent(surfaceUpserts, forKey: .surfaceUpserts)
        try container.encodeIfPresent(surfaceRemovals, forKey: .surfaceRemovals)
        if inputLeasePresent { try container.encode(inputLease ?? .null, forKey: .inputLease) }
        try container.encodeIfPresent(capabilities, forKey: .capabilities)
        try container.encodeIfPresent(diagnostics, forKey: .diagnostics)
    }
}

package enum ExtensionPresentationPolicy {
    static let maximumSurfaces = 64
    private static let maximumLeaseIDBytes = 512
    // JSON numbers admitted by the Gateway must remain exactly representable.
    private static let maximumSafeRevision = 9_007_199_254_740_991
    static let maximumColumns = 160
    package static let maximumLines = 120
    static let maximumRuns = 4_096
    package static let maximumFrameBytes = 256 * 1_024
    static let maximumPresentationBytes = 700 * 1_024

    package static func admit(_ state: ExtensionPresentationState) -> Bool {
        guard state.version == 3,
              !state.hostEpoch.isEmpty,
              state.revision >= 0, state.revision <= maximumSafeRevision,
              state.surfaces.count <= maximumSurfaces,
              Set(state.surfaces.map(\.id)).count == state.surfaces.count,
              state.pendingInteractions.count <= 8,
              Set(state.pendingInteractions.map(\.id)).count == state.pendingInteractions.count,
              state.pendingInteractions.allSatisfy({ admit($0, hostEpoch: state.hostEpoch, maximumRevision: state.revision) }),
              state.capabilities.count <= 128, state.diagnostics.count <= 64,
              state.capabilities.allSatisfy({ boundedSafe($0, 512) }),
              state.diagnostics.allSatisfy({ boundedSafe($0.code, 512) && boundedSafe($0.message, 32 * 1_024, newlines: true) }),
              admit(state.semanticState),
              state.projection?.omittedSurfaces.map({ omitted in
                  omitted.count <= maximumSurfaces && Set(omitted.map(\.id)).count == omitted.count
                    && omitted.allSatisfy({ boundedSafe($0.id, 512) && $0.revision > 0 })
              }) ?? true,
              state.surfaces.allSatisfy(admit),
              state.inputLease.map({ lease in
                  admit(lease)
                    && (state.surfaces.contains(where: { $0.id == lease.surfaceId && $0.revision == lease.surfaceRevision })
                      || state.projection?.omittedSurfaces?.contains(where: { $0.id == lease.surfaceId && $0.revision == lease.surfaceRevision }) == true)
              }) ?? true,
              let data = try? JSONEncoder.gateway.encode(state),
              data.count <= maximumPresentationBytes else { return false }
        return true
    }

    package static func admit(_ mutation: ExtensionPresentationMutation) -> Bool {
        guard mutation.version == 3, !mutation.hostEpoch.isEmpty,
              mutation.revision > 0, mutation.revision <= maximumSafeRevision,
              (mutation.surfaceUpserts ?? []).count <= maximumSurfaces,
              (mutation.surfaceUpserts ?? []).allSatisfy(admit),
              (mutation.surfaceRemovals ?? []).allSatisfy({ !$0.isEmpty }),
              Set((mutation.surfaceUpserts ?? []).map(\.id)).count == (mutation.surfaceUpserts ?? []).count,
              Set(mutation.surfaceRemovals ?? []).count == (mutation.surfaceRemovals ?? []).count,
              mutation.inputLease.map({ value in
                  value == .null || ((try? value.decode(ExtensionInputLease.self)).map(admit) ?? false)
              }) ?? true else { return false }
        if let semantic = mutation.semantic,
           semantic.statusOwners?.count ?? 0 > 32
            || semantic.statusOwners?.allSatisfy({ !$0.key.isEmpty && admit($0.value) }) == false { return false }
        if let interactionList = mutation.interactionList,
           (interactionList.count > 8 || !interactionList.allSatisfy({ admit($0, hostEpoch: mutation.hostEpoch, maximumRevision: mutation.revision) })) { return false }
        return true
    }

    private static func admit(_ lease: ExtensionInputLease) -> Bool {
        !lease.id.isEmpty && boundedSafe(lease.id, maximumLeaseIDBytes)
            && !lease.connectionId.isEmpty && boundedSafe(lease.connectionId, maximumLeaseIDBytes)
            && !lease.surfaceId.isEmpty && boundedSafe(lease.surfaceId, maximumLeaseIDBytes)
            && lease.surfaceRevision > 0 && lease.surfaceRevision <= maximumSafeRevision
            && !lease.acquiredAt.isEmpty && boundedSafe(lease.acquiredAt, maximumLeaseIDBytes)
            && GatewayTimestamp.parse(lease.acquiredAt) != nil
    }

    private static func admit(_ owner: ExtensionOwner) -> Bool {
        boundedSafe(owner.id, 512) && boundedSafe(owner.title, 256) && boundedSafe(owner.source, 512)
    }

    private static func admit(_ state: ExtensionSemanticState) -> Bool {
        guard state.statuses.count <= 32, state.statusOwners.count <= 32, state.widgets.count <= 24,
              state.statusOwners.allSatisfy({ key, owner in state.statuses[key] != nil && admit(owner) }),
              state.statuses.allSatisfy({ !$0.key.isEmpty && boundedSafe($0.key, 256) && boundedSafe($0.value, 4 * 1_024, newlines: true) }),
              state.working.message.map({ boundedSafe($0, 8 * 1_024, newlines: true) }) ?? true,
              state.working.indicator.map({ indicator in
                  indicator.frames.count <= 32 && indicator.frames.allSatisfy({ boundedSafe($0, 256) })
                    && indicator.intervalMs.map({ $0 > 0 }) ?? true
              }) ?? true,
              state.hiddenThinkingLabel.map({ boundedSafe($0, 4 * 1_024, newlines: true) }) ?? true,
              state.title.map({ boundedSafe($0, 4 * 1_024, newlines: true) }) ?? true,
              state.editorRevision >= 0, boundedSafe(state.editorText, 192 * 1_024, newlines: true),
              Set(state.widgets.map(\.key)).count == state.widgets.count,
              state.widgets.allSatisfy({ widget in
                  !widget.key.isEmpty && boundedSafe(widget.key, 256) && (widget.revision ?? 0) > 0
                    && widget.owner.map(admit) ?? true
                    && widget.lines.count <= 12 && widget.lines.allSatisfy({ boundedSafe($0, 512) })
              }) else { return false }
        return true
    }

    private static func admit(_ interaction: ExtensionInteraction, hostEpoch: String, maximumRevision: Int) -> Bool {
        guard interaction.hostEpoch == hostEpoch, interaction.presentationRevision > 0,
              interaction.presentationRevision <= maximumRevision,
              boundedSafe(interaction.id, 512), boundedSafe(interaction.title, 4 * 1_024, newlines: true),
              interaction.message.map({ boundedSafe($0, 32 * 1_024, newlines: true) }) ?? true,
              interaction.placeholder.map({ boundedSafe($0, 4 * 1_024) }) ?? true,
              interaction.prefill.map({ boundedSafe($0, 192 * 1_024, newlines: true) }) ?? true,
              interaction.expiresAt.map({ GatewayTimestamp.parse($0) != nil }) ?? true,
              (interaction.method != .select || (interaction.options?.isEmpty == false && interaction.placeholder == nil && interaction.prefill == nil && interaction.form == nil)),
              (interaction.method != .confirm || (interaction.options == nil && interaction.placeholder == nil && interaction.prefill == nil && interaction.form == nil)),
              (interaction.method != .input || (interaction.options == nil && interaction.form == nil)),
              (interaction.method != .editor || (interaction.options == nil && interaction.form == nil)),
              (interaction.method != .form || (interaction.options == nil && interaction.placeholder == nil && interaction.prefill == nil && interaction.message == nil && interaction.form.map({ admitForm($0) && $0.title == interaction.title }) == true)),
              (interaction.method == .form || interaction.form == nil),
              interaction.options.map({ options in
                  interaction.method == .select && options.count <= 64 && Set(options).count == options.count
                    && options.allSatisfy({ boundedSafe($0, 2 * 1_024) })
              }) ?? true else { return false }
        return (try? JSONEncoder.gateway.encode(interaction).count).map { $0 <= 192 * 1_024 } ?? false
    }

    private static func admitForm(_ descriptor: ExtensionFormDescriptor) -> Bool {
        guard descriptor.version == 1,
              !descriptor.title.isEmpty, boundedSafe(descriptor.title, 4 * 1_024, newlines: true),
              (1...4).contains(descriptor.questions.count),
              Set(descriptor.questions.map(\.id)).count == descriptor.questions.count,
              Set(descriptor.questions.map(\.question)).count == descriptor.questions.count else { return false }
        let multiQuestion = descriptor.questions.count > 1
        let headers = descriptor.questions.compactMap { $0.header?.trimmingCharacters(in: .whitespacesAndNewlines) }
        if multiQuestion && (headers.count != descriptor.questions.count || Set(headers).count != headers.count) { return false }
        return descriptor.questions.allSatisfy { question in
            guard !question.id.isEmpty, boundedSafe(question.id, 256),
                  !question.question.isEmpty, question.question.utf16.count <= 1_000,
                  boundedSafe(question.question, 4 * 1_024),
                  question.context.map({ boundedSafe($0, 32 * 1_024, newlines: true) }) ?? true,
                  question.header.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf16.count <= 12 && boundedSafe($0, 256) }) ?? !multiQuestion,
                  (2...4).contains(question.options.count),
                  Set(question.options.map(\.id)).count == question.options.count,
                  Set(question.options.map(\.label)).count == question.options.count else { return false }
            return question.options.allSatisfy { option in
                !option.id.isEmpty && boundedSafe(option.id, 256)
                    && !option.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && boundedSafe(option.label, 2 * 1_024)
                    && (option.description.map({ boundedSafe($0, 2 * 1_024, newlines: true) }) ?? true)
            }
        }
    }

    package static func admit(_ surface: ExtensionSurface) -> Bool {
        let runs = surface.frame.lines.reduce(0) { $0 + $1.runs.count }
        guard !surface.id.isEmpty, boundedSafe(surface.id, 512), surface.revision > 0,
              surface.revision <= maximumSafeRevision,
              surface.provenance.map({ ($0.source.map { boundedSafe($0, 512) } ?? true) && ($0.path.map { boundedSafe($0, 512) } ?? true) }) ?? true,
              (1...maximumColumns).contains(surface.frame.width),
              (0...maximumLines).contains(surface.frame.height),
              surface.frame.lines.count == surface.frame.height,
              surface.frame.lines.allSatisfy({ visibleCellWidth($0.plainText) <= surface.frame.width }),
              surface.frame.plainText == surface.frame.lines.map(\.plainText).joined(separator: "\n"),
              runs <= maximumRuns,
              surface.kind != .unknown || !surface.frame.plainText.isEmpty,
              surface.frame.lines.allSatisfy(admit),
              let frameData = try? JSONEncoder.gateway.encode(surface.frame),
              frameData.count <= maximumFrameBytes else { return false }
        if let cursor = surface.frame.cursor {
            guard cursor.row >= 0, cursor.row < surface.frame.height,
                  cursor.column >= 0, cursor.column <= surface.frame.width else { return false }
        }
        return true
    }

    private static func admit(_ line: ExtensionFrameLine) -> Bool {
        guard !containsUnsafeControl(line.plainText),
              line.plainText == line.runs.map(\.text).joined() else { return false }
        return line.runs.allSatisfy { run in
            let style = run.style
            let flags = [style.bold, style.dim, style.italic, style.underline, style.inverse, style.strike]
            return !containsUnsafeControl(run.text)
                && flags.compactMap { $0 }.allSatisfy { $0 }
                && [style.foreground, style.background].compactMap { $0 }.allSatisfy(validColor)
                && (style.link.map(validLink) ?? true)
        }
    }

    private static func visibleCellWidth(_ value: String) -> Int {
        value.reduce(into: 0) { width, character in
            let unicodeScalars = Array(character.unicodeScalars)
            let scalars = unicodeScalars.map(\.value)
            let emojiWide = unicodeScalars.contains(where: { $0.properties.isEmojiPresentation })
                || (scalars.contains(0xfe0f) && unicodeScalars.contains(where: { $0.properties.isEmoji }))
            let wide = emojiWide || scalars.contains { scalar in
                scalar == 0x20e3
                    || (0x1100...0x115f).contains(scalar)
                    || (0x2329...0x232a).contains(scalar)
                    || (0x2e80...0xa4cf).contains(scalar)
                    || (0xac00...0xd7a3).contains(scalar)
                    || (0xf900...0xfaff).contains(scalar)
                    || (0xfe10...0xfe19).contains(scalar)
                    || (0xfe30...0xfe6f).contains(scalar)
                    || (0xff00...0xff60).contains(scalar)
                    || (0xffe0...0xffe6).contains(scalar)
                    || (0x1f000...0x1faff).contains(scalar)
                    || (0x20000...0x3fffd).contains(scalar)
            }
            width += wide ? 2 : 1
        }
    }

    private static func boundedSafe(_ value: String, _ maximumBytes: Int, newlines: Bool = false) -> Bool {
        value.utf8.count <= maximumBytes && !value.unicodeScalars.contains { scalar in
            let code = scalar.value
            if code == 0x0a || code == 0x0d { return !newlines }
            return code < 0x20 || (0x7f...0x9f).contains(code)
        }
    }

    private static func containsUnsafeControl(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || (0x7f...0x9f).contains(scalar.value)
        }
    }

    private static func validColor(_ value: String) -> Bool {
        value.count == 7 && value.first == "#" && value.dropFirst().allSatisfy { $0.isHexDigit }
    }

    private static func validLink(_ value: String) -> Bool {
        guard value.utf8.count <= 2_048, !containsUnsafeControl(value),
              let scheme = URLComponents(string: value)?.scheme?.lowercased() else { return false }
        return ["http", "https", "mailto"].contains(scheme)
    }
}
