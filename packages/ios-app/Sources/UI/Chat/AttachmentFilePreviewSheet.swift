import Foundation
import PDFKit
import SwiftUI

struct AttachmentImageFilePreview: @unchecked Sendable {
    let image: UIImage
}

struct AttachmentPDFPreview: @unchecked Sendable {
    let document: PDFDocument
    let pageCount: Int
}

enum AttachmentFilePreviewKind: Equatable, Sendable {
    case image
    case markdown
    case plainText
    case code(language: String?)
    case pdf
    case unsupported
}

enum AttachmentFilePreviewContent: Sendable {
    case image(AttachmentImageFilePreview)
    case markdown(MarkdownPresentation.Document)
    case plainText(String)
    case code(String)
    case pdf(AttachmentPDFPreview)
}

struct PreparedAttachmentFilePreview: Sendable {
    let content: AttachmentFilePreviewContent
    let isTruncated: Bool
}

enum AttachmentFilePreviewError: Error, Equatable, Sendable {
    case unsupported
    case invalidText
    case invalidPDF
    case tooManyPDFPages
}

enum AttachmentFilePreviewPolicy {
    static let maximumTextBytes = ChatTextPreparationPolicy.maximumSourceBytes
    static let maximumPDFPages = 512

    private static let markdownExtensions: Set<String> = ["markdown", "md", "mdown", "mkd"]
    private static let plainTextExtensions: Set<String> = [
        "csv", "ips", "log", "text", "txt",
    ]
    private static let codeExtensions: Set<String> = [
        "c", "cc", "cpp", "css", "go", "h", "hpp", "html", "java", "js", "json",
        "jsonl", "kt", "m", "mm", "php", "pl", "py", "rb", "rs", "sh", "sql", "swift",
        "toml", "ts", "tsx", "xml", "yaml", "yml", "zsh",
    ]
    private static let codeMIMETypes: Set<String> = [
        "application/javascript", "application/json", "application/ld+json",
        "application/sql", "application/toml", "application/xml",
        "text/css", "text/html", "text/javascript", "text/typescript", "text/xml", "text/yaml",
    ]

    static func kind(name: String, mimeType: String) -> AttachmentFilePreviewKind {
        let mime = normalizedMIMEType(mimeType)
        let pathExtension = URL(fileURLWithPath: name).pathExtension.lowercased()
        if mime.hasPrefix("image/") || ["gif", "jpeg", "jpg", "png", "webp"].contains(pathExtension) { return .image }
        if mime == "application/pdf" || pathExtension == "pdf" { return .pdf }
        if mime == "text/markdown" || markdownExtensions.contains(pathExtension) { return .markdown }
        if codeMIMETypes.contains(mime)
            || mime.hasPrefix("text/x-")
            || codeExtensions.contains(pathExtension) {
            return .code(language: pathExtension.isEmpty ? nil : pathExtension)
        }
        if mime.hasPrefix("text/") || plainTextExtensions.contains(pathExtension) { return .plainText }
        return .unsupported
    }

    static func prepare(
        data: Data,
        name: String,
        mimeType: String
    ) async throws -> PreparedAttachmentFilePreview {
        guard ChatMediaPolicy.admitsEncodedByteCount(data.count) else {
            throw ChatMediaLoadError.encodedPayloadTooLarge
        }
        return try await Task.detached(priority: .userInitiated) {
            try prepareSynchronously(data: data, name: name, mimeType: mimeType)
        }.value
    }

    nonisolated static func prepareSynchronously(
        data: Data,
        name: String,
        mimeType: String
    ) throws -> PreparedAttachmentFilePreview {
        switch kind(name: name, mimeType: mimeType) {
        case .image:
            return PreparedAttachmentFilePreview(
                content: .image(AttachmentImageFilePreview(image: try ChatMediaLoader.decodeFullPreview(data))),
                isTruncated: false
            )
        case .markdown:
            let decoded = try decodedTextPrefix(data)
            return PreparedAttachmentFilePreview(
                content: .markdown(MarkdownPresentation.Document(source: decoded.text)),
                isTruncated: decoded.isTruncated
            )
        case .plainText:
            let decoded = try decodedTextPrefix(data)
            return PreparedAttachmentFilePreview(
                content: .plainText(decoded.text),
                isTruncated: decoded.isTruncated
            )
        case .code:
            let decoded = try decodedTextPrefix(data)
            return PreparedAttachmentFilePreview(
                content: .code(decoded.text),
                isTruncated: decoded.isTruncated
            )
        case .pdf:
            guard data.starts(with: Data("%PDF-".utf8)),
                  let document = PDFDocument(data: data),
                  document.pageCount > 0 else {
                throw AttachmentFilePreviewError.invalidPDF
            }
            guard document.pageCount <= maximumPDFPages else {
                throw AttachmentFilePreviewError.tooManyPDFPages
            }
            return PreparedAttachmentFilePreview(
                content: .pdf(AttachmentPDFPreview(
                    document: document,
                    pageCount: document.pageCount
                )),
                isTruncated: false
            )
        case .unsupported:
            throw AttachmentFilePreviewError.unsupported
        }
    }

    private nonisolated static func normalizedMIMEType(_ value: String) -> String {
        value.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    private nonisolated static func decodedTextPrefix(
        _ data: Data
    ) throws -> (text: String, isTruncated: Bool) {
        guard !data.isEmpty else { return ("", false) }
        let hadUTF8BOM = data.starts(with: Data([0xEF, 0xBB, 0xBF]))
        let start = hadUTF8BOM ? 3 : 0
        let sourceByteCount = data.count - start
        if sourceByteCount <= maximumTextBytes {
            guard let decoded = String(data: data[start..<data.count], encoding: .utf8),
                  !decoded.unicodeScalars.contains(where: { $0.value == 0 }) else {
                throw AttachmentFilePreviewError.invalidText
            }
            return (decoded, false)
        }

        let maximumEnd = start + maximumTextBytes
        var end = maximumEnd
        var decoded: String?
        while end >= start, maximumEnd - end <= 3 {
            decoded = String(data: data[start..<end], encoding: .utf8)
            if decoded != nil { break }
            guard end > start else { break }
            end -= 1
        }
        guard let decoded, !decoded.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw AttachmentFilePreviewError.invalidText
        }
        return (decoded, true)
    }
}

enum AttachmentFilePreviewSource: Sendable {
    case local(id: String, data: Data)
    case remote(identity: ChatMediaIdentity, leaseID: UUID)
    case unavailable

    var loadID: String {
        switch self {
        case .local(let id, _): "local:\(id)"
        case .remote(let identity, let leaseID):
            "remote:\(identity.profileID):\(identity.lifecycleGeneration):\(identity.blobID):\(leaseID.uuidString)"
        case .unavailable: "unavailable"
        }
    }
}

struct AttachmentFilePreviewSheet: View {
    let name: String
    let mimeType: String
    let source: AttachmentFilePreviewSource

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .loading

    private enum Phase {
        case loading
        case prepared(PreparedAttachmentFilePreview)
        case unavailable(String)
    }

    var body: some View {
        NavigationStack {
            content
                .background(Color.tronBackground)
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        TronSheetTitle(title: name, accent: .tronBlue)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button { dismiss() } label: {
                            Image(systemName: "checkmark")
                                .font(TronTypography.buttonSM)
                                .foregroundStyle(Color.tronBlue)
                        }
                        .accessibilityLabel("Done")
                    }
                }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .tronPresentation()
        .task(id: source.loadID) { await load() }
        .onDisappear { cancelRemoteLoad() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            TronLoadingState(label: "Preparing file preview…", accent: .tronBlue)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable(let message):
            TronInfoCard(icon: "doc.text.magnifyingglass", text: message, accent: .tronBlue)
                .padding(TronSpacing.xlarge)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        case .prepared(let preview):
            preparedContent(preview)
        }
    }

    @ViewBuilder
    private func preparedContent(_ preview: PreparedAttachmentFilePreview) -> some View {
        switch preview.content {
        case .image(let preview):
            ScrollView([.horizontal, .vertical]) {
                Image(uiImage: preview.image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color.black.opacity(0.86))
            .tronScrollEdgeChrome()
        case .markdown(let document):
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: TronSpacing.lg) {
                    truncationNotice(if: preview.isTruncated)
                    TronMarkdownView(document: document, streaming: false)
                }
                .padding(.horizontal, TronSpacing.xlarge)
                .padding(.vertical, TronSpacing.large)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .tronScrollEdgeChrome()
        case .plainText(let text):
            VStack(spacing: 0) {
                truncationNotice(if: preview.isTruncated)
                    .padding(.horizontal, preview.isTruncated ? TronSpacing.xlarge : 0)
                    .padding(.top, preview.isTruncated ? TronSpacing.large : 0)
                TronReadOnlyTextView(text: text)
            }
            .tronTopBlurSurface()
        case .code(let text):
            VStack(spacing: 0) {
                truncationNotice(if: preview.isTruncated)
                    .padding(.horizontal, preview.isTruncated ? TronSpacing.xlarge : 0)
                    .padding(.top, preview.isTruncated ? TronSpacing.large : 0)
                TronReadOnlyTextView(text: text, style: .code)
            }
            .tronTopBlurSurface()
        case .pdf(let preview):
            AttachmentPDFView(document: preview.document)
                .tronTopBlurSurface()
        }
    }

    @ViewBuilder
    private func truncationNotice(if isTruncated: Bool) -> some View {
        if isTruncated {
            TronInfoCard(
                icon: "text.badge.ellipsis",
                text: "Preview shows the first \(AttachmentFilePreviewPolicy.maximumTextBytes.formatted()) bytes.",
                accent: .tronBlue
            )
        }
    }

    private func load() async {
        phase = .loading
        do {
            let payload: ChatMediaPayload
            switch source {
            case .local(_, let data):
                payload = ChatMediaPayload(data: data, mimeType: mimeType)
            case .remote(let identity, let leaseID):
                payload = try await model.chatMedia.filePreviewPayload(
                    for: identity,
                    leaseID: leaseID
                )
            case .unavailable:
                phase = .unavailable("The file content is not available for preview.")
                return
            }
            let fetchedMIME = payload.mimeType
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let effectiveMIME = fetchedMIME.isEmpty || fetchedMIME == "application/octet-stream"
                ? mimeType
                : payload.mimeType
            let prepared = try await AttachmentFilePreviewPolicy.prepare(
                data: payload.data,
                name: name,
                mimeType: effectiveMIME
            )
            guard !Task.isCancelled else { return }
            phase = .prepared(prepared)
        } catch is CancellationError {
            return
        } catch AttachmentFilePreviewError.unsupported {
            guard !Task.isCancelled else { return }
            phase = .unavailable("This file type does not have an in-app preview.")
        } catch AttachmentFilePreviewError.tooManyPDFPages {
            guard !Task.isCancelled else { return }
            phase = .unavailable("This PDF has too many pages to preview safely.")
        } catch {
            guard !Task.isCancelled else { return }
            phase = .unavailable("The file could not be prepared for preview.")
        }
    }

    private func cancelRemoteLoad() {
        guard case .remote(let identity, let leaseID) = source else { return }
        model.chatMedia.cancelFilePreview(for: identity, leaseID: leaseID)
    }
}

private struct AttachmentPDFView: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.backgroundColor = UIColor(Color.tronBackground)
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageShadowsEnabled = true
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== document {
            view.document = document
            view.autoScales = true
        }
        softenScrollEdges(in: view)
    }

    private func softenScrollEdges(in view: UIView) {
        if let scrollView = view as? UIScrollView {
            scrollView.topEdgeEffect.style = .soft
            scrollView.bottomEdgeEffect.style = .soft
            scrollView.leftEdgeEffect.style = .soft
            scrollView.rightEdgeEffect.style = .soft
        }
        view.subviews.forEach { softenScrollEdges(in: $0) }
    }
}
