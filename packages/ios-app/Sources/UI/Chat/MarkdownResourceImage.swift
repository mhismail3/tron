import SwiftUI
import TronMobileCore

struct MarkdownImageContext {
    var sessionID: String?
    var images: [DisplayMarkdownImage] = []
}

private struct MarkdownImageContextKey: EnvironmentKey {
    static let defaultValue = MarkdownImageContext()
}

extension EnvironmentValues {
    var markdownImageContext: MarkdownImageContext {
        get { self[MarkdownImageContextKey.self] }
        set { self[MarkdownImageContextKey.self] = newValue }
    }
}

/// The document never resolves a path or starts a remote URL fetch. Only its
/// admitted immutable image artifacts may use the shared bounded media loader.
struct MarkdownResourceImage: View {
    let alt: String
    let destination: String
    @Environment(AppModel.self) private var model
    @Environment(\.markdownImageContext) private var context
    @Environment(\.tronPresentationActivity) private var activity
    @State private var loadedIdentity: ChatMediaIdentity?
    @State private var image: UIImage?
    @State private var failed = false

    private var label: String { alt.isEmpty ? "Image" : alt }
    private var identity: ChatMediaIdentity? {
        guard let sessionID = context.sessionID,
              let resource = context.images.first(where: { $0.destination == destination }) else { return nil }
        return model.chatMediaIdentity(blobID: resource.artifact.id, sessionID: sessionID)
    }

    var body: some View {
        Group {
            if let image, loadedIdentity == identity {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 520)
                    .accessibilityLabel(label)
            } else if failed || identity == nil {
                Text("\(label): image unavailable.")
                    .foregroundStyle(Color.tronTextSecondary)
            } else {
                TronLoadingState(label: "Loading image…", accent: .tronPrimary)
                    .frame(height: 160)
            }
        }
        .task(id: PresentationActivityTaskID(source: identity, presentationActive: activity.allowsPresentationPublication)) {
            await load()
        }
    }

    private func load() async {
        guard activity.allowsPresentationPublication, let identity else { return }
        if loadedIdentity == identity, image != nil { return }
        failed = false
        do {
            let value: PreparedAttachmentFilePreview = try await model.chatMedia.inlineArtifact(for: identity) { payload in
                try await AttachmentFilePreviewPolicy.prepare(data: payload.data, name: "image.png", mimeType: payload.mimeType)
            }
            guard !Task.isCancelled, activity.allowsPresentationPublication, self.identity == identity else { return }
            guard case .image(let preview) = value.content else { throw ChatMediaLoadError.invalidImage }
            image = preview.image
            loadedIdentity = identity
        } catch is CancellationError {
            // The covered/retired surface publishes nothing; reactivation retries.
        } catch {
            guard !Task.isCancelled, activity.allowsPresentationPublication, self.identity == identity else { return }
            image = nil
            loadedIdentity = nil
            failed = true
        }
    }
}
