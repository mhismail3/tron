import SwiftUI

// MARK: - Display Tool Detail Sheet

/// Detail sheet for the Display tool — renders rich content based on type.
/// Supports: image, images, markdown, link, audio, stream.
@available(iOS 26.0, *)
struct DisplayToolDetailSheet: View {
    let data: CommandToolChipData
    @Environment(\.colorScheme) private var colorScheme

    private var tint: TintedColors {
        TintedColors(accent: .tronIndigo, colorScheme: colorScheme)
    }

    // MARK: - Argument Extraction

    private var displayType: String {
        ToolArgumentParser.string("type", from: data.arguments) ?? "unknown"
    }

    private var title: String? {
        if let t = data.details?["title"]?.value as? String { return t }
        return ToolArgumentParser.string("title", from: data.arguments)
    }

    private var path: String? {
        if let p = data.details?["path"]?.value as? String { return p }
        return ToolArgumentParser.string("path", from: data.arguments)
    }

    private var paths: [String] {
        if let arr = data.details?["paths"]?.value as? [Any] {
            return arr.compactMap { $0 as? String }
        }
        if let json = try? JSONSerialization.jsonObject(with: Data(data.arguments.utf8)) as? [String: Any],
           let arr = json["paths"] as? [String] {
            return arr
        }
        return []
    }

    private var markdownContent: String? {
        if let c = data.details?["content"]?.value as? String { return c }
        return ToolArgumentParser.string("content", from: data.arguments)
    }

    private var url: String? {
        if let u = data.details?["url"]?.value as? String { return u }
        return ToolArgumentParser.string("url", from: data.arguments)
    }

    private var linkLabel: String? {
        if let l = data.details?["label"]?.value as? String { return l }
        return ToolArgumentParser.string("label", from: data.arguments)
    }

    private var streamId: String? {
        if let s = data.details?["streamId"]?.value as? String { return s }
        return ToolArgumentParser.string("streamId", from: data.arguments)
    }

    private var iconForType: String {
        switch displayType {
        case "image", "images": return "photo"
        case "markdown": return "doc.richtext"
        case "link": return "link"
        case "audio": return "waveform"
        case "stream": return "play.rectangle"
        default: return "rectangle.on.rectangle"
        }
    }

    // MARK: - Body

    var body: some View {
        ToolDetailSheetContainer(
            toolName: title ?? "Display",
            iconName: iconForType,
            accent: .tronIndigo,
            copyContent: nil
        ) {
            VStack(alignment: .leading, spacing: 16) {
                ToolStatusRow(status: data.status, durationMs: data.durationMs) {
                    ToolInfoPill(
                        icon: iconForType,
                        label: displayType,
                        color: .tronIndigo
                    )
                }

                contentForType
            }
        }
    }

    // MARK: - Type Dispatch

    @ViewBuilder
    private var contentForType: some View {
        switch displayType {
        case "image":
            imageSection
        case "images":
            imagesSection
        case "markdown":
            markdownSection
        case "link":
            linkSection
        case "audio":
            audioSection
        case "stream":
            streamSection
        default:
            ToolEmptyState(
                title: "Display",
                icon: "questionmark.circle",
                message: "Unknown display type: \(displayType)",
                accent: .tronIndigo,
                tint: tint
            )
        }
    }

    // MARK: - Content Sections

    @ViewBuilder
    private var imageSection: some View {
        if let path {
            ToolDetailSection(title: "Image", tint: tint) {
                if let uiImage = UIImage(contentsOfFile: path) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 400)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Text("Unable to load: \(path)")
                        .font(TronTypography.mono(size: TronTypography.sizeCaption))
                        .foregroundStyle(tint.subtle)
                }
            }
        } else {
            ToolEmptyState(title: "Image", icon: "photo", message: "No image path provided", accent: .tronIndigo, tint: tint)
        }
    }

    @ViewBuilder
    private var imagesSection: some View {
        if paths.isEmpty {
            ToolEmptyState(title: "Images", icon: "photo.on.rectangle", message: "No images provided", accent: .tronIndigo, tint: tint)
        } else {
            ToolDetailSection(title: "Images (\(paths.count))", tint: tint) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(paths, id: \.self) { imagePath in
                            if let uiImage = UIImage(contentsOfFile: imagePath) {
                                Image(uiImage: uiImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxHeight: 200)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var markdownSection: some View {
        if let content = markdownContent, !content.isEmpty {
            ToolDetailSection(title: "Content", tint: tint) {
                Text(LocalizedStringKey(content))
                    .font(.body)
                    .textSelection(.enabled)
            }
        } else {
            ToolEmptyState(title: "Content", icon: "doc.richtext", message: "No content provided", accent: .tronIndigo, tint: tint)
        }
    }

    @ViewBuilder
    private var linkSection: some View {
        if let url {
            ToolDetailSection(title: "Link", tint: tint) {
                VStack(alignment: .leading, spacing: 8) {
                    if let label = linkLabel, !label.isEmpty {
                        Text(label)
                            .font(.headline)
                    }
                    if let linkURL = URL(string: url) {
                        Link(destination: linkURL) {
                            HStack {
                                Image(systemName: "arrow.up.right.square")
                                Text(url)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                            }
                            .foregroundStyle(.tronInfo)
                        }
                    } else {
                        Text(url)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
        } else {
            ToolEmptyState(title: "Link", icon: "link", message: "No URL provided", accent: .tronIndigo, tint: tint)
        }
    }

    @ViewBuilder
    private var audioSection: some View {
        if let path {
            ToolDetailSection(title: "Audio", tint: tint) {
                HStack {
                    Image(systemName: "waveform")
                        .foregroundStyle(.tronIndigo)
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .font(.body.monospaced())
                        .lineLimit(1)
                }
            }
        } else {
            ToolEmptyState(title: "Audio", icon: "waveform", message: "No audio path provided", accent: .tronIndigo, tint: tint)
        }
    }

    @ViewBuilder
    private var streamSection: some View {
        if let streamId {
            ToolDetailSection(title: "Stream", tint: tint) {
                HStack {
                    Image(systemName: "play.rectangle")
                        .foregroundStyle(.tronIndigo)
                    Text("Stream: \(streamId)")
                        .font(.body.monospaced())
                }
            }
        } else {
            ToolEmptyState(title: "Stream", icon: "play.rectangle", message: "No stream ID provided", accent: .tronIndigo, tint: tint)
        }
    }
}
