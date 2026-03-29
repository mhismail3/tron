import SwiftUI

// MARK: - Display Tool Detail Sheet

/// Detail sheet for the Display tool — renders visual content (images, streams).
/// Images are fetched from blob storage via the `blob.get` RPC.
@available(iOS 26.0, *)
struct DisplayToolDetailSheet: View {
    let data: CommandToolChipData
    @Environment(\.colorScheme) private var colorScheme

    private var tint: TintedColors {
        TintedColors(accent: .tronIndigo, colorScheme: colorScheme)
    }

    // MARK: - Data Extraction

    private var displayType: String {
        if let t = data.details?["displayType"]?.value as? String { return t }
        return ToolArgumentParser.string("type", from: data.arguments) ?? "unknown"
    }

    private var title: String? {
        if let t = data.details?["title"]?.value as? String { return t }
        return ToolArgumentParser.string("title", from: data.arguments)
    }

    private var imageBlobId: String? {
        data.details?["blobId"]?.value as? String
    }

    private var galleryBlobIds: [(id: String, mime: String)] {
        guard let arr = data.details?["images"]?.value as? [[String: Any]] else { return [] }
        return arr.compactMap { item in
            guard let id = item["blobId"] as? String else { return nil }
            let mime = item["mimeType"] as? String ?? "image/png"
            return (id: id, mime: mime)
        }
    }

    private var streamId: String? {
        if let s = data.details?["streamId"]?.value as? String { return s }
        return ToolArgumentParser.string("streamId", from: data.arguments)
    }

    private var iconForType: String {
        switch displayType {
        case "image", "images": return "photo"
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
            .padding(.horizontal, 16)
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

    // MARK: - Sections

    @ViewBuilder
    private var imageSection: some View {
        if let blobId = imageBlobId {
            ToolDetailSection(title: "Image", tint: tint) {
                BlobImageView(blobId: blobId)
            }
        } else {
            ToolEmptyState(title: "Image", icon: "photo", message: "No image data available", accent: .tronIndigo, tint: tint)
        }
    }

    @ViewBuilder
    private var imagesSection: some View {
        let blobs = galleryBlobIds
        if blobs.isEmpty {
            ToolEmptyState(title: "Images", icon: "photo.on.rectangle", message: "No images to display", accent: .tronIndigo, tint: tint)
        } else {
            ToolDetailSection(title: "Images (\(blobs.count))", tint: tint) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(blobs.enumerated()), id: \.offset) { _, blob in
                            BlobImageView(blobId: blob.id)
                                .frame(maxHeight: 200)
                        }
                    }
                }
            }
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

// MARK: - Blob Image View

/// Fetches and displays an image from blob storage via the `blob.get` RPC.
@available(iOS 26.0, *)
private struct BlobImageView: View {
    let blobId: String
    @Environment(\.dependencies) private var dependencies
    @State private var image: UIImage?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else if let errorMessage {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.tronAmber)
                    Text(errorMessage)
                        .font(TronTypography.mono(size: TronTypography.sizeCaption))
                        .foregroundStyle(.tronTextMuted)
                }
                .frame(maxWidth: .infinity, minHeight: 100)
            }
        }
        .task {
            await fetchBlob()
        }
    }

    @MainActor
    private func fetchBlob() async {
        do {
            if let data = try await dependencies.rpcClient.blob.getImageData(blobId: blobId) {
                self.image = UIImage(data: data)
                if self.image == nil {
                    self.errorMessage = "Failed to decode image data"
                }
            } else {
                self.errorMessage = "Invalid image data"
            }
        } catch {
            self.errorMessage = "Failed to load: \(error.localizedDescription)"
        }
        self.isLoading = false
    }
}
