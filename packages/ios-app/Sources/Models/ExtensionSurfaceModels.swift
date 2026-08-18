import Foundation

private struct ExtensionDynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
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
}

struct ExtensionInteraction: Codable, Hashable, Identifiable, Sendable {
    enum Method: String, Codable, Sendable { case select, confirm, input, editor }
    let id: String
    let hostEpoch: String
    let presentationRevision: Int
    let method: Method
    let title: String
    let message: String?
    let options: [String]?
    let placeholder: String?
    let prefill: String?
    let expiresAt: String?

    init(id: String, hostEpoch: String, presentationRevision: Int, method: Method, title: String, message: String? = nil, options: [String]? = nil, placeholder: String? = nil, prefill: String? = nil, expiresAt: String? = nil) {
        self.id = id; self.hostEpoch = hostEpoch; self.presentationRevision = presentationRevision; self.method = method
        self.title = title; self.message = message; self.options = options; self.placeholder = placeholder; self.prefill = prefill; self.expiresAt = expiresAt
    }
    private enum CodingKeys: String, CodingKey { case id, hostEpoch, presentationRevision, method, title, message, options, placeholder, prefill, expiresAt }
    init(from decoder: Decoder) throws {
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
    }
}

struct ExtensionOwner: Codable, Hashable, Sendable {
    let id: String
    let title: String
    let source: String
}

struct ExtensionWidget: Codable, Hashable, Identifiable, Sendable {
    enum Placement: String, Codable, Sendable { case aboveEditor, belowEditor }
    let key: String
    var revision: Int? = nil
    let lines: [String]
    let placement: Placement
    let owner: ExtensionOwner?
    var id: String { key }

    init(key: String, revision: Int? = nil, lines: [String], placement: Placement, owner: ExtensionOwner? = nil) {
        self.key = key; self.revision = revision; self.lines = lines; self.placement = placement; self.owner = owner
    }
    private enum CodingKeys: String, CodingKey { case key, revision, lines, placement, owner }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        revision = try container.decodeIfPresent(Int.self, forKey: .revision)
        lines = try container.decodeBoundedArray(String.self, forKey: .lines, maximum: 12)
        placement = try container.decode(Placement.self, forKey: .placement)
        owner = try container.decodeIfPresent(ExtensionOwner.self, forKey: .owner)
    }
}

struct ExtensionPresentationDiagnostic: Codable, Hashable, Sendable {
    var code: String
    var message: String
}

struct ExtensionSemanticState: Codable, Hashable, Sendable {
    struct Working: Codable, Hashable, Sendable {
        struct Indicator: Codable, Hashable, Sendable {
            enum Kind: String, Codable, Sendable { case `default`, hidden, `static`, animated }
            var kind: Kind
            var frames: [String]
            var intervalMs: Int?

            init(kind: Kind, frames: [String], intervalMs: Int? = nil) {
                self.kind = kind; self.frames = frames; self.intervalMs = intervalMs
            }
            private enum CodingKeys: String, CodingKey { case kind, frames, intervalMs }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                kind = try container.decode(Kind.self, forKey: .kind)
                frames = try container.decodeBoundedArray(String.self, forKey: .frames, maximum: 32)
                intervalMs = try container.decodeIfPresent(Int.self, forKey: .intervalMs)
            }
        }
        var message: String?
        var visible: Bool
        var indicator: Indicator? = nil
    }
    var statuses: [String: String]
    var statusOwners: [String: ExtensionOwner]
    var working: Working
    var hiddenThinkingLabel: String?
    var widgets: [ExtensionWidget]
    var title: String?
    var toolsExpanded: Bool
    var editorRevision: Int
    var editorText: String

    init(statuses: [String: String], statusOwners: [String: ExtensionOwner] = [:], working: Working, hiddenThinkingLabel: String? = nil, widgets: [ExtensionWidget], title: String? = nil, toolsExpanded: Bool, editorRevision: Int, editorText: String) {
        self.statuses = statuses; self.statusOwners = statusOwners; self.working = working; self.hiddenThinkingLabel = hiddenThinkingLabel; self.widgets = widgets
        self.title = title; self.toolsExpanded = toolsExpanded; self.editorRevision = editorRevision; self.editorText = editorText
    }
    private enum CodingKeys: String, CodingKey { case statuses, statusOwners, working, hiddenThinkingLabel, widgets, title, toolsExpanded, editorRevision, editorText }
    init(from decoder: Decoder) throws {
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

struct ExtensionFrameStyle: Codable, Hashable, Sendable {
    var bold: Bool? = nil
    var dim: Bool? = nil
    var italic: Bool? = nil
    var underline: Bool? = nil
    var inverse: Bool? = nil
    var strike: Bool? = nil
    var foreground: String? = nil
    var background: String? = nil
    var link: String? = nil
}
struct ExtensionFrameRun: Codable, Hashable, Sendable { var text: String; var style: ExtensionFrameStyle }
struct ExtensionFrameLine: Codable, Hashable, Sendable {
    var plainText: String
    var runs: [ExtensionFrameRun]
    init(plainText: String, runs: [ExtensionFrameRun]) { self.plainText = plainText; self.runs = runs }
    private enum CodingKeys: String, CodingKey { case plainText, runs }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        plainText = try container.decode(String.self, forKey: .plainText)
        runs = try container.decodeBoundedArray(ExtensionFrameRun.self, forKey: .runs, maximum: 4_096)
    }
}
struct ExtensionFrameCursor: Codable, Hashable, Sendable { var row: Int; var column: Int }
struct ExtensionFrame: Codable, Hashable, Sendable {
    var width: Int
    var height: Int
    var lines: [ExtensionFrameLine]
    var plainText: String
    var cursor: ExtensionFrameCursor?
    init(width: Int, height: Int, lines: [ExtensionFrameLine], plainText: String, cursor: ExtensionFrameCursor? = nil) {
        self.width = width; self.height = height; self.lines = lines; self.plainText = plainText; self.cursor = cursor
    }
    private enum CodingKeys: String, CodingKey { case width, height, lines, plainText, cursor }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        width = try container.decode(Int.self, forKey: .width)
        height = try container.decode(Int.self, forKey: .height)
        lines = try container.decodeBoundedArray(ExtensionFrameLine.self, forKey: .lines, maximum: 120)
        plainText = try container.decode(String.self, forKey: .plainText)
        cursor = try container.decodeIfPresent(ExtensionFrameCursor.self, forKey: .cursor)
    }
}

struct ExtensionSurface: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case header, footer, widget, custom, overlay, editor, toolRenderer, messageRenderer, entryRenderer, markdown, unknown
        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .unknown
        }
    }
    enum Placement: String, Codable, Sendable { case header, footer, aboveEditor, belowEditor, transcript, overlay, fullscreen }
    enum Lifecycle: String, Codable, Sendable { case retained, blocking, transient, restored }
    enum InputMode: String, Codable, Sendable { case none, keys, textAndKeys }
    struct Provenance: Codable, Hashable, Sendable { var source: String?; var path: String? }
    let id: String
    var kind: Kind
    var placement: Placement
    var lifecycle: Lifecycle
    var targetId: String?
    var provenance: Provenance?
    var revision: Int
    var focused: Bool
    var inputMode: InputMode
    var frame: ExtensionFrame
}

struct ExtensionInputLease: Codable, Hashable, Sendable {
    var id: String
    var connectionId: String
    var surfaceId: String
    var surfaceRevision: Int
    var acquiredAt: String
}

struct ExtensionPresentationState: Codable, Hashable, Sendable {
    struct Projection: Codable, Hashable, Sendable {
        struct OmittedSurface: Codable, Hashable, Sendable { var id: String; var revision: Int }
        var complete: Bool
        var omitted: [String]
        var omittedSurfaces: [OmittedSurface]?
        init(complete: Bool, omitted: [String], omittedSurfaces: [OmittedSurface]? = nil) {
            self.complete = complete; self.omitted = omitted; self.omittedSurfaces = omittedSurfaces
        }
        private enum CodingKeys: String, CodingKey { case complete, omitted, omittedSurfaces }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            complete = try container.decode(Bool.self, forKey: .complete)
            omitted = try container.decodeBoundedArray(String.self, forKey: .omitted, maximum: 16)
            omittedSurfaces = try container.decodeBoundedArrayIfPresent(OmittedSurface.self, forKey: .omittedSurfaces, maximum: 64)
        }
    }
    var version: Int
    var hostEpoch: String
    var revision: Int
    var capabilities: [String]
    var diagnostics: [ExtensionPresentationDiagnostic]
    var semanticState: ExtensionSemanticState
    var surfaces: [ExtensionSurface]
    var pendingInteractions: [ExtensionInteraction]
    var inputLease: ExtensionInputLease?
    var projection: Projection?
    init(version: Int, hostEpoch: String, revision: Int, capabilities: [String], diagnostics: [ExtensionPresentationDiagnostic], semanticState: ExtensionSemanticState, surfaces: [ExtensionSurface], pendingInteractions: [ExtensionInteraction], inputLease: ExtensionInputLease? = nil, projection: Projection? = nil) {
        self.version = version; self.hostEpoch = hostEpoch; self.revision = revision; self.capabilities = capabilities; self.diagnostics = diagnostics
        self.semanticState = semanticState; self.surfaces = surfaces; self.pendingInteractions = pendingInteractions; self.inputLease = inputLease; self.projection = projection
    }
    private enum CodingKeys: String, CodingKey { case version, hostEpoch, revision, capabilities, diagnostics, semanticState, surfaces, pendingInteractions, inputLease, projection }
    init(from decoder: Decoder) throws {
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

struct ExtensionSemanticPatch: Codable, Hashable, Sendable {
    var statuses: [String: String]?
    var statusOwners: [String: ExtensionOwner]?
    var working: ExtensionSemanticState.Working?
    var hiddenThinkingLabel: JSONValue?
    var widgets: [ExtensionWidget]?
    var title: JSONValue?
    var toolsExpanded: Bool?
    var editorRevision: Int?
    var editorText: String?
    var editorAction: String?
    var editorDelta: String?
    var editorOperationId: String?

    private enum CodingKeys: String, CodingKey {
        case statuses, statusOwners, working, hiddenThinkingLabel, widgets, title, toolsExpanded
        case editorRevision, editorText, editorAction, editorDelta, editorOperationId
    }
    init(from decoder: Decoder) throws {
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
    func encode(to encoder: Encoder) throws {
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

struct ExtensionPresentationNotification: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case info, warning, error }
    var message: String
    var type: Kind
}

struct ExtensionPresentationMutation: Codable, Hashable, Sendable {
    var version: Int
    var hostEpoch: String
    var revision: Int
    var semantic: ExtensionSemanticPatch?
    var interactionList: [ExtensionInteraction]?
    var surfaceUpserts: [ExtensionSurface]?
    var surfaceRemovals: [String]?
    var inputLease: JSONValue?
    var inputLeasePresent: Bool
    var capabilities: [String]?
    var diagnostics: [ExtensionPresentationDiagnostic]?
    var notification: ExtensionPresentationNotification?

    private enum CodingKeys: String, CodingKey {
        case version, hostEpoch, revision, semantic, interactionList, surfaceUpserts
        case surfaceRemovals, inputLease, capabilities, diagnostics, notification
    }
    init(from decoder: Decoder) throws {
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
        notification = try container.decodeIfPresent(ExtensionPresentationNotification.self, forKey: .notification)
    }
    func encode(to encoder: Encoder) throws {
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
        try container.encodeIfPresent(notification, forKey: .notification)
    }
}

enum ExtensionPresentationPolicy {
    static let maximumSurfaces = 64
    static let maximumColumns = 160
    static let maximumLines = 120
    static let maximumRuns = 4_096
    static let maximumFrameBytes = 256 * 1_024
    static let maximumPresentationBytes = 700 * 1_024

    static func admit(_ state: ExtensionPresentationState) -> Bool {
        guard state.version == 2,
              !state.hostEpoch.isEmpty,
              state.revision >= 0,
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
                  state.surfaces.contains(where: { $0.id == lease.surfaceId && $0.revision == lease.surfaceRevision })
                    || state.projection?.omittedSurfaces?.contains(where: { $0.id == lease.surfaceId && $0.revision == lease.surfaceRevision }) == true
              }) ?? true,
              let data = try? JSONEncoder.gateway.encode(state),
              data.count <= maximumPresentationBytes else { return false }
        return true
    }

    static func admit(_ mutation: ExtensionPresentationMutation) -> Bool {
        guard mutation.version == 2, !mutation.hostEpoch.isEmpty, mutation.revision > 0,
              (mutation.surfaceUpserts ?? []).count <= maximumSurfaces,
              (mutation.surfaceUpserts ?? []).allSatisfy(admit),
              (mutation.surfaceRemovals ?? []).allSatisfy({ !$0.isEmpty }),
              Set((mutation.surfaceUpserts ?? []).map(\.id)).count == (mutation.surfaceUpserts ?? []).count,
              Set(mutation.surfaceRemovals ?? []).count == (mutation.surfaceRemovals ?? []).count else { return false }
        if let semantic = mutation.semantic,
           semantic.statusOwners?.count ?? 0 > 32
            || semantic.statusOwners?.allSatisfy({ !$0.key.isEmpty && admit($0.value) }) == false { return false }
        if let interactionList = mutation.interactionList,
           (interactionList.count > 8 || !interactionList.allSatisfy({ admit($0, hostEpoch: mutation.hostEpoch, maximumRevision: mutation.revision) })) { return false }
        return true
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
              boundedSafe(interaction.id, 512), boundedSafe(interaction.title, 4 * 1_024),
              interaction.message.map({ boundedSafe($0, 32 * 1_024, newlines: true) }) ?? true,
              interaction.placeholder.map({ boundedSafe($0, 4 * 1_024) }) ?? true,
              interaction.prefill.map({ boundedSafe($0, 192 * 1_024, newlines: true) }) ?? true,
              (interaction.method != .select || interaction.options != nil),
              interaction.options.map({ options in
                  interaction.method == .select && options.count <= 64 && options.allSatisfy({ boundedSafe($0, 2 * 1_024) })
              }) ?? true else { return false }
        return (try? JSONEncoder.gateway.encode(interaction).count).map { $0 <= 192 * 1_024 } ?? false
    }

    static func admit(_ surface: ExtensionSurface) -> Bool {
        let runs = surface.frame.lines.reduce(0) { $0 + $1.runs.count }
        guard !surface.id.isEmpty, boundedSafe(surface.id, 512), surface.revision > 0,
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
