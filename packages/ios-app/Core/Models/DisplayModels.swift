import Foundation

package enum DisplaySurface: String, Codable, Hashable, Sendable {
    case sheet
    case inline
    case floating
}

package enum DisplayInlineTapAction: String, Codable, Hashable, Sendable {
    case sheet
    case none
}

package enum DisplayKind: String, Codable, Hashable, Sendable {
    case image
    case markdown
    case text
    case code
    case pdf
    case html
    case video
    case audio
    case document
    case webpage
    case hls
    case browserLive = "browser_live"
    case nativeLive = "native_live"

    package var isLive: Bool { liveViewSchema != nil }

    var liveViewSchema: String? {
        switch self {
        case .browserLive: "tron.browser-live-view.v1"
        case .nativeLive: "tron.native-live-view.v1"
        default: nil
        }
    }

    var liveViewCapability: String? {
        switch self {
        case .browserLive: "browser-live-view.v1"
        case .nativeLive: "native-live-view.v1"
        default: nil
        }
    }
}

package struct DisplayPresentationPreference: Codable, Hashable, Sendable {
    let requestedSurface: DisplaySurface
    package let inlineTapAction: DisplayInlineTapAction

    package init(requestedSurface: DisplaySurface, inlineTapAction: DisplayInlineTapAction) {
        self.requestedSurface = requestedSurface
        self.inlineTapAction = inlineTapAction
    }
}

package struct LiveViewDescriptor: Codable, Hashable, Sendable {
    let schema: String
    package let viewId: String
    package let generation: String
    package let title: String
    package let fallbackText: String

    package init(schema: String, viewId: String, generation: String, title: String, fallbackText: String) {
        self.schema = schema
        self.viewId = viewId
        self.generation = generation
        self.title = title
        self.fallbackText = fallbackText
    }

    package var isValid: Bool {
        func bounded(_ value: String, _ maximum: Int) -> Bool {
            !value.isEmpty && value.utf8.count <= maximum
                && !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
        }
        return (schema == DisplayKind.browserLive.liveViewSchema || schema == DisplayKind.nativeLive.liveViewSchema)
            && bounded(viewId, 200)
            && bounded(generation, 200) && bounded(title, 256) && bounded(fallbackText, 4_096)
    }
}

package struct DisplayArtifactDescriptor: Codable, Hashable, Sendable {
    package let id: String
    package let name: String
    package let mimeType: String
    package let size: Int
    package let kind: DisplayKind

    package init(id: String, name: String, mimeType: String, size: Int, kind: DisplayKind) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.size = size
        self.kind = kind
    }
}

package struct DisplayProjection: Codable, Hashable, Sendable, Identifiable {
    let schema: String
    let displayId: String
    package let revision: Int
    package let title: String
    package let caption: String?
    package let altText: String
    package let kind: DisplayKind
    package let presentation: DisplayPresentationPreference
    let eligibleSurfaces: [DisplaySurface]
    package let fallbackText: String
    package let artifact: DisplayArtifactDescriptor?
    package let remoteURL: String?
    package let liveView: LiveViewDescriptor?

    package var id: String { displayId }

    /// Tool calls are chat identities; exact producer/view generations own live
    /// presentation. Later actions cannot reopen a manually dismissed window.
    package var presentationIdentity: String {
        if let liveView {
            let producer = kind == .nativeLive ? "native" : "browser"
            return "\(producer):\(liveView.viewId):\(liveView.generation)"
        }
        return "\(displayId):\(revision)"
    }

    /// The identity an inline card's disclosure phase is keyed by. The content
    /// revision is deliberately absent: a later revision presents newer content
    /// under the same display, and a card the reader collapsed must stay
    /// collapsed. A live view keeps its own producer generation, so two live
    /// views that share a view generation never share one phase.
    package var disclosureIdentity: String {
        guard let liveView else { return displayId }
        let producer = kind == .nativeLive ? "native" : "browser"
        return "\(displayId):\(producer):\(liveView.viewId):\(liveView.generation)"
    }

    private enum CodingKeys: String, CodingKey {
        case schema, displayId, revision, title, caption, altText, kind, presentation,
             eligibleSurfaces, fallbackText, artifact, remoteURL, liveView
    }

    #if HOSTED_TEST
    package init(
        schema: String = "tron.display.v1",
        displayId: String,
        revision: Int = 1,
        title: String,
        caption: String? = nil,
        altText: String,
        kind: DisplayKind,
        presentation: DisplayPresentationPreference,
        eligibleSurfaces: [DisplaySurface],
        fallbackText: String,
        artifact: DisplayArtifactDescriptor? = nil,
        remoteURL: String? = nil,
        liveView: LiveViewDescriptor? = nil
    ) {
        self.schema = schema
        self.displayId = displayId
        self.revision = revision
        self.title = title
        self.caption = caption
        self.altText = altText
        self.kind = kind
        self.presentation = presentation
        self.eligibleSurfaces = eligibleSurfaces
        self.fallbackText = fallbackText
        self.artifact = artifact
        self.remoteURL = remoteURL
        self.liveView = liveView
    }
    #endif

    package init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schema = try values.decode(String.self, forKey: .schema)
        displayId = try values.decode(String.self, forKey: .displayId)
        revision = try values.decode(Int.self, forKey: .revision)
        title = try values.decode(String.self, forKey: .title)
        caption = try values.decodeIfPresent(String.self, forKey: .caption)
        altText = try values.decode(String.self, forKey: .altText)
        kind = try values.decode(DisplayKind.self, forKey: .kind)
        presentation = try values.decode(DisplayPresentationPreference.self, forKey: .presentation)
        eligibleSurfaces = try values.decode([DisplaySurface].self, forKey: .eligibleSurfaces)
        fallbackText = try values.decode(String.self, forKey: .fallbackText)
        artifact = try values.decodeIfPresent(DisplayArtifactDescriptor.self, forKey: .artifact)
        remoteURL = try values.decodeIfPresent(String.self, forKey: .remoteURL)
        liveView = try values.decodeIfPresent(LiveViewDescriptor.self, forKey: .liveView)

        let expected = DisplayPresentationPolicy.eligibleSurfaces(
            for: kind,
            artifactSize: artifact?.size
        )
        let hasOneSource = [artifact != nil, remoteURL != nil, liveView != nil].filter { $0 }.count == 1
        guard schema == "tron.display.v1", revision == 1,
              Self.admits(displayId, minimum: 1, maximum: 200),
              Self.admits(title, minimum: 1, maximum: 256),
              caption.map({ Self.admits($0, minimum: 1, maximum: 4_096) }) ?? true,
              Self.admits(altText, minimum: 1, maximum: 2_048),
              Self.admits(fallbackText, minimum: 1, maximum: 4_096),
              eligibleSurfaces == expected,
              hasOneSource,
              (liveView != nil) == kind.isLive,
              liveView.map({ $0.isValid && $0.schema == kind.liveViewSchema }) ?? true else {
            throw DecodingError.dataCorruptedError(
                forKey: .schema,
                in: values,
                debugDescription: "Display metadata is malformed or exceeds its bounded contract"
            )
        }
        if let artifact {
            guard Self.admits(artifact.id, minimum: 1, maximum: 200),
                  UUID(uuidString: artifact.id) != nil,
                  Self.admits(artifact.name, minimum: 1, maximum: 160),
                  !artifact.name.contains("/"), !artifact.name.contains("\\"),
                  Self.admits(artifact.mimeType, minimum: 1, maximum: 200),
                  artifact.size > 0, artifact.size <= DisplayPresentationPolicy.maximumArtifactBytes,
                  artifact.kind == kind,
                  kind != .webpage, kind != .hls else {
                throw DecodingError.dataCorruptedError(
                    forKey: .artifact,
                    in: values,
                    debugDescription: "Display artifact metadata is invalid"
                )
            }
        }
        if let remoteURL {
            guard (kind == .webpage || kind == .hls),
                  Self.admits(remoteURL, minimum: 1, maximum: 8_192),
                  DisplayRemoteURLPolicy.admits(remoteURL) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .remoteURL,
                    in: values,
                    debugDescription: "Display remote URL is invalid"
                )
            }
        }
    }

    private static func admits(_ value: String, minimum: Int, maximum: Int) -> Bool {
        let bytes = value.utf8.count
        return bytes >= minimum && bytes <= maximum
            && !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }
}

package struct DisplayFloatingCompletionTracker: Equatable, Sendable {
    package private(set) var baseline: [DisplayProjection]?

    package init(baseline: [DisplayProjection]? = nil) {
        self.baseline = baseline
    }

    package mutating func transition(
        to current: [DisplayProjection]?
    ) -> (previous: [DisplayProjection], current: [DisplayProjection])? {
        guard let current else {
            baseline = nil
            return nil
        }
        guard let previous = baseline else {
            baseline = current
            return nil
        }
        baseline = current
        return (previous, current)
    }
}

package enum DisplayFloatingAdmission: Equatable, Sendable {
    case none
    case deferred(DisplayProjection)
    case present(DisplayProjection)
}

package enum DisplayFloatingAdmissionPolicy {
    package static func admission(
        previous: [DisplayProjection],
        current: [DisplayProjection],
        sceneActive: Bool,
        presentationReady: Bool,
        allowsPresentation: Bool,
        hasFloatingDisplay: Bool,
        consumedRevisionIDs: Set<String>
    ) -> DisplayFloatingAdmission {
        guard sceneActive, presentationReady, !hasFloatingDisplay else { return .none }
        let previousIDs = Set(previous.map(\.presentationIdentity))
        guard let display = current.reversed().first(where: {
            let revisionID = $0.presentationIdentity
            return !previousIDs.contains(revisionID)
                && !consumedRevisionIDs.contains(revisionID)
                && DisplayPresentationPolicy.effectiveSurface(for: $0) == .floating
        }) else { return .none }
        return allowsPresentation ? .present(display) : .deferred(display)
    }
}

package enum DisplayPresentationPolicy {
    static let maximumArtifactBytes = 2 * 1_024 * 1_024 * 1_024
    static let maximumEmbeddedMediaBytes = 50 * 1_024 * 1_024

    static func eligibleSurfaces(
        for kind: DisplayKind,
        artifactSize: Int? = nil
    ) -> [DisplaySurface] {
        switch kind {
        case .image:
            [.sheet, .inline, .floating]
        case .video, .audio:
            if let artifactSize, artifactSize > maximumEmbeddedMediaBytes {
                [.sheet]
            } else {
                [.sheet, .inline, .floating]
            }
        case .markdown, .text, .code, .pdf:
            [.sheet, .inline]
        case .html:
            [.sheet, .floating]
        case .document, .webpage, .hls:
            [.sheet]
        case .browserLive, .nativeLive:
            [.sheet, .floating]
        }
    }

    package static func effectiveSurface(for display: DisplayProjection) -> DisplaySurface {
        display.eligibleSurfaces.contains(display.presentation.requestedSurface)
            ? display.presentation.requestedSurface
            : .sheet
    }

    /// Large local media remains ineligible for automatic inline/floating
    /// presentation, but an explicit tap on a requested floating result is
    /// sufficient user intent to begin bounded file staging in the panel.
    package static func activationSurface(for display: DisplayProjection) -> DisplaySurface {
        // Live tool taps reopen the small window; its expand control owns the
        // sheet route, including for retained descriptors created as sheets.
        if display.kind.isLive { return .floating }
        if display.presentation.requestedSurface == .floating,
           display.eligibleSurfaces == [.sheet],
           (display.kind == .video || display.kind == .audio) {
            return .floating
        }
        return effectiveSurface(for: display)
    }

    package static func invocationSurface(toolName: String?, request: JSONValue?) -> DisplaySurface? {
        guard toolName == "display", let object = request?.objectValue else { return nil }
        guard let presentation = object["presentation"]?.objectValue,
              let raw = presentation["surface"]?.stringValue else {
            let rawKind = object["source"]?.objectValue?["kind"]?.stringValue
            let kind = rawKind.flatMap { DisplayKind(rawValue: $0) }
            return kind?.isLive == true ? .floating : .sheet
        }
        return DisplaySurface(rawValue: raw) ?? .sheet
    }
}

package enum DisplayRemoteURLPolicy {
    package static func admits(_ value: String) -> Bool {
        guard value.utf8.count >= 1, value.utf8.count <= 8_192,
              let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              let rawHost = url.host?.lowercased() else {
            return false
        }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !host.isEmpty,
              host != "localhost", !host.hasSuffix(".localhost"),
              ![".local", ".internal", ".home", ".lan"].contains(where: host.hasSuffix) else {
            return false
        }
        if host.contains(":") {
            let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            guard normalized != "::", normalized != "::1",
                  !normalized.hasPrefix("2001:db8:"),
                  let firstText = normalized.split(separator: ":", omittingEmptySubsequences: true).first,
                  let first = UInt16(firstText, radix: 16), first >= 0x2000, first <= 0x3fff else {
                return false
            }
            return true
        }
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { return true }
        let octets = components.compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        let a = Int(octets[0]), b = Int(octets[1]), c = Int(octets[2])
        return !(a == 0 || a == 10 || a == 127 || a >= 224
            || (a == 100 && b >= 64 && b <= 127)
            || (a == 169 && b == 254)
            || (a == 172 && b >= 16 && b <= 31)
            || (a == 192 && (b == 0 || b == 168))
            || (a == 198 && (b == 18 || b == 19))
            || (a == 198 && b == 51 && c == 100)
            || (a == 203 && b == 0 && c == 113))
    }
}
