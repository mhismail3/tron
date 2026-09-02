import Foundation

enum DisplaySurface: String, Codable, Hashable, Sendable {
    case sheet
    case inline
    case floating
}

enum DisplayInlineTapAction: String, Codable, Hashable, Sendable {
    case sheet
    case none
}

enum DisplayKind: String, Codable, Hashable, Sendable {
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
}

struct DisplayPresentationPreference: Codable, Hashable, Sendable {
    let requestedSurface: DisplaySurface
    let inlineTapAction: DisplayInlineTapAction
}

struct DisplayArtifactDescriptor: Codable, Hashable, Sendable {
    let id: String
    let name: String
    let mimeType: String
    let size: Int
    let kind: DisplayKind
}

struct DisplayProjection: Codable, Hashable, Sendable, Identifiable {
    let schema: String
    let displayId: String
    let revision: Int
    let title: String
    let caption: String?
    let altText: String
    let kind: DisplayKind
    let presentation: DisplayPresentationPreference
    let eligibleSurfaces: [DisplaySurface]
    let fallbackText: String
    let artifact: DisplayArtifactDescriptor?
    let remoteURL: String?

    var id: String { displayId }

    private enum CodingKeys: String, CodingKey {
        case schema, displayId, revision, title, caption, altText, kind, presentation,
             eligibleSurfaces, fallbackText, artifact, remoteURL
    }

    #if HOSTED_TEST
    init(
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
        remoteURL: String? = nil
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
    }
    #endif

    init(from decoder: Decoder) throws {
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

        let expected = DisplayPresentationPolicy.eligibleSurfaces(
            for: kind,
            artifactSize: artifact?.size
        )
        let hasOneSource = (artifact != nil) != (remoteURL != nil)
        guard schema == "tron.display.v1", revision == 1,
              Self.admits(displayId, minimum: 1, maximum: 200),
              Self.admits(title, minimum: 1, maximum: 256),
              caption.map({ Self.admits($0, minimum: 1, maximum: 4_096) }) ?? true,
              Self.admits(altText, minimum: 1, maximum: 2_048),
              Self.admits(fallbackText, minimum: 1, maximum: 4_096),
              eligibleSurfaces == expected,
              hasOneSource else {
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

struct DisplayFloatingCompletionTracker: Equatable, Sendable {
    private(set) var baseline: [DisplayProjection]?

    mutating func transition(
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

enum DisplayFloatingAdmission: Equatable, Sendable {
    case none
    case deferred(DisplayProjection)
    case present(DisplayProjection)
}

enum DisplayFloatingAdmissionPolicy {
    static func admission(
        previous: [DisplayProjection],
        current: [DisplayProjection],
        sceneActive: Bool,
        presentationReady: Bool,
        allowsPresentation: Bool,
        hasFloatingDisplay: Bool,
        consumedRevisionIDs: Set<String>
    ) -> DisplayFloatingAdmission {
        guard sceneActive, presentationReady, !hasFloatingDisplay else { return .none }
        let previousIDs = Set(previous.map { "\($0.displayId):\($0.revision)" })
        guard let display = current.reversed().first(where: {
            let revisionID = "\($0.displayId):\($0.revision)"
            return !previousIDs.contains(revisionID)
                && !consumedRevisionIDs.contains(revisionID)
                && DisplayPresentationPolicy.effectiveSurface(for: $0) == .floating
        }) else { return .none }
        return allowsPresentation ? .present(display) : .deferred(display)
    }
}

enum DisplayPresentationPolicy {
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
        }
    }

    static func effectiveSurface(for display: DisplayProjection) -> DisplaySurface {
        display.eligibleSurfaces.contains(display.presentation.requestedSurface)
            ? display.presentation.requestedSurface
            : .sheet
    }

    static func invocationSurface(toolName: String?, request: JSONValue?) -> DisplaySurface? {
        guard toolName == "display", let object = request?.objectValue else { return nil }
        guard let presentation = object["presentation"]?.objectValue,
              let raw = presentation["surface"]?.stringValue else { return .sheet }
        return DisplaySurface(rawValue: raw) ?? .sheet
    }
}

enum DisplayRemoteURLPolicy {
    static func admits(_ value: String) -> Bool {
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
