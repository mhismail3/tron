import AVFoundation
import AVKit
import SafariServices
import SwiftUI
import WebKit

struct DisplayRoute: Identifiable, Hashable, Sendable {
    let sessionID: String
    let display: DisplayProjection

    var id: String { "\(sessionID):\(display.displayId)" }
}

enum DisplayPresentationCommand: Sendable {
    case showSheet(DisplayRoute)
    case showFloating(DisplayRoute)
}

typealias DisplayPresentationHandler = @MainActor @Sendable (DisplayPresentationCommand) -> Void

private struct DisplayPresentationHandlerKey: EnvironmentKey {
    static let defaultValue: DisplayPresentationHandler? = nil
}

extension EnvironmentValues {
    var displayPresentationHandler: DisplayPresentationHandler? {
        get { self[DisplayPresentationHandlerKey.self] }
        set { self[DisplayPresentationHandlerKey.self] = newValue }
    }
}

struct DisplayToolView: View {
    let tool: ChatToolDescriptor
    let onOpenTechnicalDetails: () -> Void

    @Environment(\.canonicalResourceSessionID) private var sessionID
    @Environment(\.displayPresentationHandler) private var present
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var collapsed = false

    private var display: DisplayProjection? { tool.display }
    private var effectiveSurface: DisplaySurface {
        display.map(DisplayPresentationPolicy.effectiveSurface)
            ?? tool.requestedDisplaySurface ?? .sheet
    }

    var body: some View {
        Group {
            if let display, !tool.error, !tool.isRunning,
               effectiveSurface == .inline, !collapsed {
                DisplayInlineContainer(
                    sessionID: sessionID,
                    display: display,
                    onCollapse: { withAnimation(animation) { collapsed = true } },
                    onOpenSheet: inlineSheetAction(for: display)
                )
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.985)))
                .contextMenu {
                    Button("Tool Details", systemImage: "info.circle", action: onOpenTechnicalDetails)
                }
            } else {
                displayPill
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(animation, value: tool.isRunning)
        .animation(animation, value: tool.display)
        .animation(animation, value: collapsed)
    }

    private func inlineSheetAction(for display: DisplayProjection) -> (() -> Void)? {
        guard display.presentation.inlineTapAction == .sheet, let sessionID else { return nil }
        return { present?(.showSheet(DisplayRoute(sessionID: sessionID, display: display))) }
    }

    private var animation: Animation? {
        reduceMotion ? .linear(duration: 0.10) : .smooth(duration: 0.24)
    }

    private var displayPill: some View {
        ChatCompactPillSurface(
            tone: tone,
            material: .glass,
            interactive: true,
            cornerRadiusOverride: ChatToolChipShapePolicy.cornerRadius
        ) {
            ChatCompactPillLabel(
                icon: icon,
                title: display?.title ?? "Display",
                detail: detail,
                tone: tone,
                showsProgress: tool.isRunning,
                iconSize: ChatCompactPillLayoutPolicy.toolIconSize
            ) {
                if tool.isRunning {
                    DisplayToolElapsedText(tool: tool, color: tone.secondaryColor)
                }
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: ChatToolChipShapePolicy.cornerRadius, style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
        .chatCompactPillInteraction(
            accessibilityLabel: accessibilityLabel,
            accessibilityValue: display?.title,
            action: activatePill
        )
        .contextMenu {
            Button("Tool Details", systemImage: "info.circle", action: onOpenTechnicalDetails)
        }
    }

    private func activatePill() {
        guard let display, !tool.error, !tool.isRunning, let sessionID else {
            onOpenTechnicalDetails()
            return
        }
        let route = DisplayRoute(sessionID: sessionID, display: display)
        switch effectiveSurface {
        case .sheet:
            present?(.showSheet(route))
        case .inline:
            withAnimation(animation) { collapsed = false }
        case .floating:
            present?(.showFloating(route))
        }
    }

    private var detail: String {
        if tool.error { return "Failed" }
        if tool.isRunning {
            return switch tool.requestedDisplaySurface ?? .sheet {
            case .sheet: "Preparing"
            case .inline: "Preparing inline"
            case .floating: "Preparing window"
            }
        }
        return switch effectiveSurface {
        case .sheet: "Open"
        case .inline: collapsed ? "Show inline" : "Inline"
        case .floating: "Open window"
        }
    }

    private var icon: String {
        if tool.error { return "exclamationmark.triangle.fill" }
        return switch display?.kind {
        case .image: "photo"
        case .video: "play.rectangle.fill"
        case .audio: "waveform"
        case .pdf, .document: "doc.richtext"
        case .html, .webpage: "safari"
        case .hls: "dot.radiowaves.left.and.right"
        case .markdown, .text, .code: "text.page"
        case nil: "rectangle.on.rectangle"
        }
    }

    private var tone: ChatNotificationTone {
        if tool.error { return .error }
        return tool.isRunning ? .warning : .tool
    }

    private var accessibilityLabel: String {
        let action = switch effectiveSurface {
        case .sheet: "Opens sheet"
        case .inline: collapsed ? "Expands inline" : "Displayed inline"
        case .floating: "Opens floating window"
        }
        return [display?.title ?? "Display", detail, action].joined(separator: ", ")
    }
}

private struct DisplayToolElapsedText: View {
    let tool: ChatToolDescriptor
    let color: Color
    @Environment(\.tronPresentationActivity) private var activity
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        if PresentationClockPolicy.runs(
            surfaceActive: activity.allowsContinuousAnimation,
            sceneActive: scenePhase == .active
        ) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                value(at: context.date)
            }
        } else {
            value(at: .now)
        }
    }

    private func value(at date: Date) -> some View {
        Text(tool.elapsedMilliseconds(at: date).map(ToolTiming.format(milliseconds:)) ?? "")
            .font(TronTypography.caption)
            .foregroundStyle(color)
            .monospacedDigit()
    }
}

enum DisplayInlineLayoutPolicy {
    static let maximumViewportHeight: CGFloat = 320
    static let cornerRadius: CGFloat = 22
    static let controlDiameter: CGFloat = 34
    static let controlTouchTarget: CGFloat = 44
    static let contentTopPadding: CGFloat = 4
}

private struct DisplayInlineContainer: View {
    let sessionID: String?
    let display: DisplayProjection
    let onCollapse: () -> Void
    let onOpenSheet: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(display.title)
                        .font(TronTypography.buttonSM)
                        .foregroundStyle(Color.tronTextPrimary)
                        .lineLimit(1)
                    if let caption = display.caption {
                        Text(caption)
                            .font(TronTypography.secondaryDescription)
                            .foregroundStyle(Color.tronTextSecondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                GlassEffectContainer(spacing: 2) {
                    HStack(spacing: 2) {
                        if let onOpenSheet {
                            DisplayInlineHeaderButton(
                                systemImage: "arrow.up.left.and.arrow.down.right",
                                accessibilityLabel: "Open \(display.title) in sheet",
                                action: onOpenSheet
                            )
                        }
                        DisplayInlineHeaderButton(
                            systemImage: "chevron.up",
                            accessibilityLabel: "Collapse \(display.title)",
                            action: onCollapse
                        )
                    }
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .padding(.top, 8)
            .padding(.bottom, 2)

            inlineContent
                .frame(maxWidth: .infinity, alignment: .top)
                .frame(maxHeight: DisplayInlineLayoutPolicy.maximumViewportHeight, alignment: .top)
                .clipped()
        }
        .clipShape(RoundedRectangle(
            cornerRadius: DisplayInlineLayoutPolicy.cornerRadius,
            style: .continuous
        ))
        .tronGlassSurface(
            accent: .tronLavender,
            cornerRadius: DisplayInlineLayoutPolicy.cornerRadius,
            tintOpacity: 0.10,
            interactive: false,
            respectsSettingsTheme: false
        )
        .tint(.tronLavender)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var inlineContent: some View {
        let content = DisplayArtifactContent(
            sessionID: sessionID,
            display: display,
            context: .inline
        )
        if let onOpenSheet,
           display.kind != .video, display.kind != .audio {
            content
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpenSheet)
        } else {
            content
        }
    }
}

private struct DisplayInlineHeaderButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(TronTypography.buttonSM)
                .foregroundStyle(Color.tronLavender)
                .frame(
                    width: DisplayInlineLayoutPolicy.controlDiameter,
                    height: DisplayInlineLayoutPolicy.controlDiameter
                )
                .glassEffect(
                    .regular.tint(Color.tronLavender.opacity(0.10)).interactive(),
                    in: .circle
                )
                .frame(
                    width: DisplayInlineLayoutPolicy.controlTouchTarget,
                    height: DisplayInlineLayoutPolicy.controlTouchTarget
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

enum DisplayRenderContext: Sendable {
    case inline
    case sheet
    case floating
}

struct DisplayArtifactContent: View {
    let sessionID: String?
    let display: DisplayProjection
    let context: DisplayRenderContext

    var body: some View {
        Group {
            switch display.kind {
            case .image:
                DisplayImageArtifactView(sessionID: sessionID, display: display)
            case .markdown, .text, .code, .pdf:
                DisplayTextArtifactView(sessionID: sessionID, display: display, context: context)
            case .document:
                DisplayDocumentSummary(display: display)
            case .html:
                DisplayHTMLArtifactView(sessionID: sessionID, display: display)
            case .video, .audio:
                DisplayVideoArtifactView(sessionID: sessionID, display: display)
            case .webpage, .hls:
                // Public remote content stays in Safari's isolated, explicit-
                // gesture browser boundary. Gateway credentials are never
                // attached to playlists, redirects, segments, or keys.
                DisplayRemoteWebView(display: display)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(display.altText)
    }
}

private struct DisplayImageArtifactView: View {
    let sessionID: String?
    let display: DisplayProjection
    @Environment(AppModel.self) private var model
    @State private var image: UIImage?
    @State private var failed = false
    @State private var leaseID = UUID()

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 520)
                    .background(Color.black.opacity(0.88))
            } else if failed {
                DisplayUnavailableView(text: display.fallbackText)
            } else {
                TronLoadingState(label: "Loading image…", accent: .tronBlue)
                    .frame(height: 220)
            }
        }
        .accessibilityLabel(display.altText)
        .task(id: mediaIdentity) {
            image = nil
            failed = false
            guard let identity = mediaIdentity else {
                failed = true
                return
            }
            do { image = try await model.chatMedia.fullPreview(for: identity, leaseID: leaseID) }
            catch is CancellationError { return }
            catch { failed = true }
        }
        .onDisappear {
            guard let identity = mediaIdentity else { return }
            model.chatMedia.cancelFullPreview(for: identity, leaseID: leaseID)
        }
    }

    private var mediaIdentity: ChatMediaIdentity? {
        guard let artifact = display.artifact, let sessionID else { return nil }
        return model.chatMediaIdentity(blobID: artifact.id, sessionID: sessionID)
    }
}

private struct DisplayTextArtifactView: View {
    let sessionID: String?
    let display: DisplayProjection
    let context: DisplayRenderContext
    @Environment(AppModel.self) private var model
    @State private var prepared: PreparedAttachmentFilePreview?
    @State private var failed = false
    @State private var leaseID = UUID()

    var body: some View {
        Group {
            if let prepared {
                rendered(prepared)
            } else if failed {
                DisplayUnavailableView(text: display.fallbackText)
            } else {
                TronLoadingState(label: "Preparing content…", accent: .tronBlue)
                    .frame(height: context == .inline ? 180 : 320)
            }
        }
        .task(id: mediaIdentity) { await load() }
        .onDisappear { cancelLoad() }
    }

    @ViewBuilder
    private func rendered(_ value: PreparedAttachmentFilePreview) -> some View {
        switch value.content {
        case .markdown(let document):
            if context == .inline {
                // The transcript remains the sole vertical scroll owner. The
                // fixed card viewport clips this bounded preview; its header
                // exposes the complete scrolling sheet.
                TronMarkdownView(document: document, streaming: false)
                    .padding(.horizontal, 16)
                    .padding(.top, DisplayInlineLayoutPolicy.contentTopPadding)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    TronMarkdownView(document: document, streaming: false)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .plainText(let text):
            TronReadOnlyTextView(text: text)
                .frame(minHeight: context == .inline ? 180 : 320, maxHeight: context == .inline ? 520 : .infinity)
        case .code(let text):
            TronReadOnlyTextView(text: text, style: .code)
                .frame(minHeight: context == .inline ? 180 : 320, maxHeight: context == .inline ? 520 : .infinity)
        case .pdf(let preview):
            AttachmentPDFView(document: preview.document)
                .frame(minHeight: context == .inline ? 320 : 480)
        case .image:
            DisplayUnavailableView(text: display.fallbackText)
        }
    }

    private var mediaIdentity: ChatMediaIdentity? {
        guard let artifact = display.artifact, let sessionID else { return nil }
        return model.chatMediaIdentity(blobID: artifact.id, sessionID: sessionID)
    }

    private func cancelLoad() {
        guard let identity = mediaIdentity else { return }
        model.chatMedia.cancelFilePreview(for: identity, leaseID: leaseID)
    }

    private func load() async {
        prepared = nil
        failed = false
        guard let artifact = display.artifact, let identity = mediaIdentity else {
            failed = true
            return
        }
        do {
            let payload = try await model.chatMedia.filePreviewPayload(for: identity, leaseID: leaseID)
            prepared = try await AttachmentFilePreviewPolicy.prepare(
                data: payload.data,
                name: artifact.name,
                mimeType: payload.mimeType
            )
        } catch is CancellationError { return }
        catch { failed = true }
    }
}

private struct DisplayDocumentSummary: View {
    let display: DisplayProjection

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: display.kind == .pdf ? "doc.richtext.fill" : "doc.fill")
                .font(TronTypography.sans(size: 38, weight: .semibold))
                .foregroundStyle(Color.tronBlue)
            Text(display.artifact?.name ?? display.title)
                .font(TronTypography.buttonSM)
                .foregroundStyle(Color.tronTextPrimary)
            Text(display.fallbackText)
                .font(TronTypography.secondaryDescription)
                .foregroundStyle(Color.tronTextSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 180)
    }
}

private struct DisplayHTMLArtifactView: View {
    let sessionID: String?
    let display: DisplayProjection
    @Environment(AppModel.self) private var model
    @State private var html: String?
    @State private var failed = false
    @State private var leaseID = UUID()

    var body: some View {
        Group {
            if let html {
                StaticDisplayWebView(html: html)
            } else if failed {
                DisplayUnavailableView(text: display.fallbackText)
            } else {
                TronLoadingState(label: "Preparing HTML…", accent: .tronBlue)
            }
        }
        .task(id: mediaIdentity) { await load() }
        .onDisappear { cancelLoad() }
    }

    private var mediaIdentity: ChatMediaIdentity? {
        guard let artifact = display.artifact, let sessionID else { return nil }
        return model.chatMediaIdentity(blobID: artifact.id, sessionID: sessionID)
    }

    private func cancelLoad() {
        guard let identity = mediaIdentity else { return }
        model.chatMedia.cancelFilePreview(for: identity, leaseID: leaseID)
    }

    private func load() async {
        html = nil
        failed = false
        guard let artifact = display.artifact, artifact.size <= 5 * 1_024 * 1_024,
              let identity = mediaIdentity else {
            failed = true
            return
        }
        do {
            let payload = try await model.chatMedia.filePreviewPayload(for: identity, leaseID: leaseID)
            guard let source = String(data: payload.data, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
            html = source
        } catch is CancellationError { return }
        catch { failed = true }
    }
}

private struct StaticDisplayWebView: UIViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsLinkPreview = false
        view.isOpaque = false
        view.backgroundColor = UIColor(Color.tronBackground)
        view.scrollView.backgroundColor = UIColor(Color.tronBackground)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html
        let policy = "default-src 'none'; img-src data: blob:; media-src data: blob:; style-src 'unsafe-inline'; font-src data:; form-action 'none'; frame-src 'none'; connect-src 'none'"
        let prefix = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">"
        view.loadHTMLString(prefix + html, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var loadedHTML: String?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let scheme = navigationAction.request.url?.scheme?.lowercased() else {
                decisionHandler(.allow)
                return
            }
            decisionHandler(scheme == "about" ? .allow : .cancel)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? { nil }
    }
}

private struct DisplayVideoArtifactView: View {
    let sessionID: String?
    let display: DisplayProjection
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @State private var player: AVPlayer?
    @State private var localFileURL: URL?
    @State private var failed = false

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .frame(minHeight: 220)
            } else if failed {
                DisplayUnavailableView(text: display.fallbackText)
            } else {
                TronLoadingState(label: "Preparing media…", accent: .tronBlue)
                    .frame(minHeight: 220)
            }
        }
        .task(id: mediaIdentity) { await prepare() }
        .onChange(of: presentationActivity) { _, activity in
            if !activity.allowsPresentationPublication { player?.pause() }
        }
        .onDisappear { tearDown() }
    }

    private var mediaIdentity: ChatMediaIdentity? {
        guard let artifact = display.artifact, let sessionID else { return nil }
        return model.chatMediaIdentity(blobID: artifact.id, sessionID: sessionID)
    }

    private func prepare() async {
        tearDown()
        failed = false
        guard let artifact = display.artifact, let sessionID,
              let identity = mediaIdentity else {
            failed = true
            return
        }
        do {
            let url = try await model.displayArtifactFile(
                id: artifact.id,
                sessionID: sessionID,
                profileID: identity.profileID,
                maximumBytes: artifact.size,
                expectedBytes: Int64(artifact.size)
            )
            guard !Task.isCancelled else {
                BoundedHTTPFileStaging.shared.discard(url)
                return
            }
            localFileURL = url
            player = AVPlayer(url: url)
        } catch is CancellationError { return }
        catch { failed = true }
    }

    private func tearDown() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        if let localFileURL {
            BoundedHTTPFileStaging.shared.discard(localFileURL)
            self.localFileURL = nil
        }
    }
}

private struct DisplayRemoteWebView: View {
    let display: DisplayProjection

    var body: some View {
        if let value = display.remoteURL, let url = URL(string: value) {
            SafariDisplayView(url: url)
        } else {
            DisplayUnavailableView(text: display.fallbackText)
        }
    }
}

private struct SafariDisplayView: UIViewControllerRepresentable {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: { dismiss() })
    }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.barCollapsingEnabled = true
        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.delegate = context.coordinator
        controller.dismissButtonStyle = .close
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, @preconcurrency SFSafariViewControllerDelegate {
        private let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            onFinish()
        }
    }
}

private struct DisplayUnavailableView: View {
    let text: String
    var body: some View {
        TronInfoCard(icon: "rectangle.slash", text: text, accent: .tronBlue)
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: 160)
    }
}

struct DisplaySheet: View {
    let route: DisplayRoute
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var imageLeaseID = UUID()
    @State private var documentLeaseID = UUID()

    @ViewBuilder
    var body: some View {
        if (route.display.kind == .webpage || route.display.kind == .hls),
           let value = route.display.remoteURL,
           let url = URL(string: value) {
            SafariDisplayView(url: url)
                .ignoresSafeArea(.container, edges: .all)
                .accessibilityLabel(route.display.altText)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
        } else if let artifact = route.display.artifact,
                  route.display.kind == .image,
           let identity = model.chatMediaIdentity(blobID: artifact.id, sessionID: route.sessionID) {
            AttachmentImagePreviewSheet(
                remote: identity,
                leaseID: imageLeaseID,
                title: route.display.title,
                accessibilityLabel: route.display.altText
            )
        } else if let artifact = route.display.artifact,
                  route.display.kind == .pdf || route.display.kind == .document,
                  let identity = model.chatMediaIdentity(blobID: artifact.id, sessionID: route.sessionID) {
            AttachmentFilePreviewSheet(
                name: artifact.name,
                mimeType: artifact.mimeType,
                source: .remote(identity: identity, leaseID: documentLeaseID)
            )
        } else {
            NavigationStack {
                DisplayArtifactContent(sessionID: route.sessionID, display: route.display, context: .sheet)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.tronBackground)
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            TronSheetTitle(title: route.display.title, accent: .tronBlue)
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
        }
    }
}
