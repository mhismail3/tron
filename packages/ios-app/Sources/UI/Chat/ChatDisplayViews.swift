import AVFoundation
import AVKit
import ImageIO
import SwiftUI
import TronMobileCore
import WebKit

struct DisplayRoute: Identifiable, Hashable, Sendable {
    let sessionID: String
    let display: DisplayProjection
    var technicalTool: ChatToolPresentation? = nil

    var id: String { "\(sessionID):\(display.presentationIdentity)" }
    var sheetPresentationID: String { "chat.display.\(id)" }
}

struct LiveFrameSource: Hashable, Sendable {
    let sessionID: String?
    let profileID: String?
    let presentationIdentity: String
    let viewID: String
    let generation: String
    let surface: PresentationSurfaceToken?
    let producerID: UUID
    let activityGeneration: UInt64
}

struct LiveFrameGeometry: Equatable, Sendable {
    let width: CGFloat
    let height: CGFloat

    var aspectRatio: CGFloat? {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        let ratio = width / height
        return ratio.isFinite && ratio > 0 ? ratio : nil
    }
}

struct LiveFrameUpdate: Equatable, Sendable {
    let source: LiveFrameSource
    let geometry: LiveFrameGeometry?
}

enum DisplayPresentationCommand: Hashable, Sendable {
    case showSheet(DisplayRoute)
    case showFloating(DisplayRoute)

    var route: DisplayRoute {
        switch self { case .showSheet(let route), .showFloating(let route): route }
    }
}

/// Every tool entrypoint uses the same admitted display, never raw result text.
/// Grouped and inline content open the same full viewer.
enum ToolDisplayActivation {
    static func command(for tool: ChatToolPresentation, sessionID: String?) -> DisplayPresentationCommand? {
        guard let command = command(for: tool.descriptor, sessionID: sessionID) else { return nil }
        var route = command.route
        route.technicalTool = tool
        if case .showFloating = command { return .showFloating(route) }
        return .showSheet(route)
    }

    static func command(for tool: ChatToolDescriptor, sessionID: String?) -> DisplayPresentationCommand? {
        guard let sessionID, let display = tool.display, !tool.isRunning,
              !tool.error || display.kind.isLive else { return nil }
        let route = DisplayRoute(sessionID: sessionID, display: display)
        return DisplayPresentationPolicy.activationSurface(for: display) == .floating
            ? .showFloating(route) : .showSheet(route)
    }
}

typealias DisplayPresentationHandler = @MainActor @Sendable (DisplayPresentationCommand) -> Void

private struct DisplayPresentationHandlerKey: EnvironmentKey {
    static let defaultValue: DisplayPresentationHandler? = nil
}

private struct DisplayTranscriptReadyKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var displayPresentationHandler: DisplayPresentationHandler? {
        get { self[DisplayPresentationHandlerKey.self] }
        set { self[DisplayPresentationHandlerKey.self] = newValue }
    }

    var displayTranscriptReady: Bool {
        get { self[DisplayTranscriptReadyKey.self] }
        set { self[DisplayTranscriptReadyKey.self] = newValue }
    }
}

struct DisplayToolView: View {
    let tool: ChatToolDescriptor
    let onOpenTechnicalDetails: () -> Void

    @Environment(\.canonicalResourceSessionID) private var sessionID
    @Environment(\.displayPresentationHandler) private var present

    private var display: DisplayProjection? { tool.display }
    private var effectiveSurface: DisplaySurface {
        display.map(DisplayPresentationPolicy.effectiveSurface)
            ?? tool.requestedDisplaySurface ?? .sheet
    }
    private var activationSurface: DisplaySurface {
        display.map(DisplayPresentationPolicy.activationSurface) ?? effectiveSurface
    }

    @ViewBuilder
    var body: some View {
        if let display, completedInlineDisplay {
            Group {
                if display.kind == .image {
                    DisplayThumbnailButton(
                        sessionID: sessionID,
                        content: .image(display),
                        accessibilityLabel: DisplayThumbnailButton.imageLabel(display.title),
                        action: inlineSheetAction(for: display)
                    )
                } else {
                    DisplayInlineContainer(
                        sessionID: sessionID,
                        display: display,
                        onOpenSheet: inlineSheetAction(for: display)
                    )
                }
            }
            .contextMenu {
                Button("Tool Details", systemImage: "info.circle", action: onOpenTechnicalDetails)
            }
        } else {
            displayPill
        }
    }

    private func inlineSheetAction(for display: DisplayProjection) -> (() -> Void)? {
        guard (display.kind == .image || display.presentation.inlineTapAction == .sheet),
              let sessionID else { return nil }
        return { present?(.showSheet(DisplayRoute(sessionID: sessionID, display: display))) }
    }

    private var completedInlineDisplay: Bool {
        display != nil && !tool.error && !tool.isRunning && effectiveSurface == .inline
    }

    /// A completed inline card other than the photo thumbnail spans the
    /// transcript width; every other display can share a grouped row, where it
    /// renders as a thumbnail (`DisplayStripThumbnail`).
    static func rendersFullWidth(_ tool: ChatToolDescriptor) -> Bool {
        guard let display = tool.display, !tool.error, !tool.isRunning else { return false }
        return DisplayPresentationPolicy.effectiveSurface(for: display) == .inline && display.kind != .image
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
        guard display != nil, !tool.error, !tool.isRunning, let sessionID else {
            onOpenTechnicalDetails()
            return
        }
        if let command = ToolDisplayActivation.command(for: tool, sessionID: sessionID) {
            present?(command)
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
        return switch activationSurface {
        case .sheet: "Open"
        case .inline: "Inline"
        case .floating: "Open window"
        }
    }

    private var icon: String {
        if tool.error { return "exclamationmark.triangle.fill" }
        return DisplayKindSymbol.name(for: display?.kind)
    }

    private var tone: ChatNotificationTone {
        if tool.error { return .error }
        return tool.isRunning ? .warning : .tool
    }

    private var accessibilityLabel: String {
        let action = switch activationSurface {
        case .sheet: "Opens sheet"
        case .inline: "Displayed inline"
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
            TimelineView(timelineSchedule) { context in
                value(at: context.date)
            }
        } else {
            value(at: .now)
        }
    }

    private var timelineSchedule: ToolElapsedTimelineSchedule {
        let tool = tool
        return ToolElapsedTimelineSchedule(interval: 1) { date, uptime in
            tool.elapsedMilliseconds(at: date, uptime: uptime)
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
    static let imageChipScale: CGFloat = 1.45
    static var imageChipSide: CGFloat {
        PendingPhotoRemoveLayoutPolicy.previewSide * imageChipScale
    }

    /// The height an inline card reserves before its artifact is prepared,
    /// decided by the kind it will render rather than by whether the payload has
    /// arrived. It is the viewport its own content occupies, so preparing cannot
    /// resize the row: an inline PDF renders in its 320-point viewport, and the
    /// inline image chip is one exact square. Textual artifacts fill a bounded
    /// 180-point viewport or their measured height, which the retained prepared
    /// document makes exact on a remount.
    static func reservedViewportHeight(for kind: DisplayKind) -> CGFloat {
        switch kind {
        case .image: imageChipSide
        case .pdf: maximumViewportHeight
        case .markdown, .text, .code, .html, .document, .webpage, .hls, .browserLive, .nativeLive: 180
        case .video, .audio: 220
        }
    }

}

/// One display in a grouped run's horizontal row. It renders the same thumbnail
/// card as a lone inline image display, and a tap opens that display's own
/// preview directly, exactly as its chip did when shown alone. Displays still
/// preparing or failed keep the card's shape with a progress or warning face,
/// so the row never mixes thumbnails with tool chips.
struct DisplayStripThumbnail: View {
    let tool: ChatToolDescriptor
    let onOpenTechnicalDetails: () -> Void

    @Environment(\.canonicalResourceSessionID) private var sessionID
    @Environment(\.displayPresentationHandler) private var present

    var body: some View {
        DisplayThumbnailButton(
            sessionID: sessionID,
            content: content,
            accessibilityLabel: accessibilityLabel,
            action: activate
        )
        .contextMenu {
            Button("Tool Details", systemImage: "info.circle", action: onOpenTechnicalDetails)
        }
    }

    /// A failed live view still opens its viewer, as its chip did alone.
    private var failed: Bool { tool.error && !(tool.display?.kind.isLive ?? false) }

    private var content: DisplayThumbnailContent {
        if failed { return .symbol("exclamationmark.triangle.fill", title: title) }
        guard let display = tool.display, !tool.isRunning else { return .preparing }
        if display.kind == .image { return .image(display) }
        return .symbol(DisplayKindSymbol.name(for: display.kind), title: display.title)
    }

    private var title: String { tool.display?.title ?? "Display" }

    private var accessibilityLabel: String {
        if failed { return "\(title), Failed" }
        if tool.isRunning { return "\(title), Preparing" }
        if tool.display?.kind == .image { return DisplayThumbnailButton.imageLabel(title) }
        return "Open \(title)"
    }

    private func activate() {
        if let present, let command = ToolDisplayActivation.command(for: tool, sessionID: sessionID) {
            present(command)
        } else {
            onOpenTechnicalDetails()
        }
    }
}

enum DisplayThumbnailContent: Equatable {
    case image(DisplayProjection)
    case symbol(String, title: String)
    case preparing
}

enum DisplayKindSymbol {
    static func name(for kind: DisplayKind?) -> String {
        switch kind {
        case .image: "photo"
        case .video: "play.rectangle.fill"
        case .audio: "waveform"
        case .pdf, .document: "doc.richtext"
        case .html, .webpage: "safari"
        case .hls: "dot.radiowaves.left.and.right"
        case .browserLive, .nativeLive: "rectangle.inset.filled.and.person.filled"
        case .markdown, .text, .code: "text.page"
        case nil: "rectangle.on.rectangle"
        }
    }
}

/// The transcript's display thumbnail control: the bounded square glass card a
/// lone inline image display renders, shared by every display in a grouped row.
/// The UI journeys find it by its identifier, so both cases stay on this one
/// component rather than drifting into separate visuals.
struct DisplayThumbnailButton: View {
    let sessionID: String?
    let content: DisplayThumbnailContent
    let accessibilityLabel: String
    let action: (() -> Void)?

    static func imageLabel(_ title: String) -> String { "Open \(title) photo preview" }

    var body: some View {
        Button(action: { action?() }) {
            DisplayThumbnailSurface(sessionID: sessionID, content: content)
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("display-inline-thumbnail")
    }
}

private struct DisplayThumbnailSurface: View {
    let sessionID: String?
    let content: DisplayThumbnailContent

    @Environment(AppModel.self) private var model
    @Environment(\.displayTranscriptReady) private var transcriptReady
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: UIImage?
    @State private var loadedIdentity: ChatMediaIdentity?
    @State private var failed = false
    @State private var loadGeneration = 0

    private var display: DisplayProjection? {
        if case .image(let display) = content { display } else { nil }
    }

    var body: some View {
        ZStack {
            transparencyBackdrop
            switch content {
            case .image:
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else if failed {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(TronTypography.sans(size: 28, weight: .semibold))
                        .foregroundStyle(Color.tronTextSecondary)
                } else {
                    ProgressView()
                        .tint(.tronEmerald)
                }
            case .symbol(let symbol, let title):
                VStack(spacing: 8) {
                    Image(systemName: symbol)
                        .font(TronTypography.sans(size: 28, weight: .semibold))
                        .foregroundStyle(Color.tronTextSecondary)
                    Text(title)
                        .font(TronTypography.secondaryDescription)
                        .foregroundStyle(Color.tronTextSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                .padding(10)
            case .preparing:
                ProgressView()
                    .tint(.tronEmerald)
            }
        }
        .frame(
            width: DisplayInlineLayoutPolicy.imageChipSide,
            height: DisplayInlineLayoutPolicy.imageChipSide
        )
        .clipped()
        .glassEffect(
            .regular.tint(Color.tronLavender.opacity(0.08)).interactive(),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .task(id: PresentationActivityTaskID(
            source: transcriptReady ? mediaIdentity : nil,
            presentationActive: transcriptReady && presentationActivity.allowsPresentationPublication
        )) {
            // The task owns its request fence. Separate onChange callbacks can
            // invalidate the newly started load without changing its task ID,
            // stranding the spinner until another presentation transition.
            loadGeneration &+= 1
            await loadThumbnail(generation: loadGeneration)
        }
    }

    /// Only a photo needs an opaque backdrop behind its transparent pixels;
    /// every other face sits directly on the card's glass.
    private var transparencyBackdrop: Color {
        guard display != nil else { return .clear }
        return colorScheme == .dark
            ? Color(uiColor: .black)
            : Color(uiColor: .systemBackground)
    }

    private var mediaIdentity: ChatMediaIdentity? {
        guard let artifact = display?.artifact, let sessionID else { return nil }
        return model.chatMediaIdentity(blobID: artifact.id, sessionID: sessionID)
    }

    private func loadThumbnail(generation: Int) async {
        guard transcriptReady,
              presentationActivity.allowsPresentationPublication,
              !Task.isCancelled,
              let identity = mediaIdentity else { return }
        guard generation == loadGeneration, mediaIdentity == identity else { return }
        if loadedIdentity != identity {
            image = nil
            failed = false
        } else if image != nil {
            return
        }
        do {
            let loaded = try await model.chatMedia.thumbnail(for: identity)
            guard !Task.isCancelled,
                  generation == loadGeneration,
                  mediaIdentity == identity,
                  transcriptReady,
                  presentationActivity.allowsPresentationPublication else { return }
            image = loaded
            loadedIdentity = identity
        } catch {
            // Only retirement of this view task is silent. A dependency that
            // cancels a still-current request must not leave a permanent spinner.
            guard !Task.isCancelled,
                  generation == loadGeneration,
                  mediaIdentity == identity,
                  transcriptReady,
                  presentationActivity.allowsPresentationPublication else { return }
            failed = true
            loadedIdentity = identity
        }
    }
}

private struct DisplayInlineContainer: View {
    let sessionID: String?
    let display: DisplayProjection
    let onOpenSheet: (() -> Void)?
    @Environment(\.displayTranscriptReady) private var transcriptReady

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
                    }
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .padding(.top, 8)
            .padding(.bottom, 2)

            Group {
                if transcriptReady {
                    inlineContent
                } else {
                    TronLoadingState(label: "Preparing display…", accent: .tronLavender)
                        .frame(height: DisplayInlineLayoutPolicy.reservedViewportHeight(for: display.kind))
                }
            }
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

private struct DisplayRenderContextKey: EnvironmentKey {
    static let defaultValue: DisplayRenderContext = .sheet
}

private extension EnvironmentValues {
    var displayRenderContext: DisplayRenderContext {
        get { self[DisplayRenderContextKey.self] }
        set { self[DisplayRenderContextKey.self] = newValue }
    }
}

struct DisplayArtifactContent: View {
    let sessionID: String?
    let display: DisplayProjection
    let context: DisplayRenderContext
    var onLiveFrameGeometry: (@MainActor (LiveFrameUpdate) -> Void)? = nil

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
                DisplayVideoArtifactView(sessionID: sessionID, display: display, context: context)
            case .browserLive, .nativeLive:
                LiveDisplayView(
                    sessionID: sessionID,
                    display: display,
                    onFrameGeometry: onLiveFrameGeometry
                )
            case .webpage, .hls:
                // Public remote content stays in Safari's isolated, explicit-
                // gesture browser boundary. Gateway credentials are never
                // attached to playlists, redirects, segments, or keys.
                DisplayRemoteWebView(display: display)
            }
        }
        .environment(\.displayRenderContext, context)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(display.altText)
    }
}

private struct DisplayImageArtifactView: View {
    let sessionID: String?
    let display: DisplayProjection
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @State private var image: UIImage?
    @State private var failed = false
    @State private var leaseID = UUID()
    @State private var loadGeneration = 0
    @State private var loadedIdentity: ChatMediaIdentity?

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
        .task(id: PresentationActivityTaskID(
            source: mediaIdentity,
            presentationActive: presentationActivity.allowsPresentationPublication
        )) { await load() }
        .onDisappear {
            guard let identity = mediaIdentity else { return }
            model.chatMedia.cancelFullPreview(for: identity, leaseID: leaseID)
        }
    }

    private func load() async {
        // Covered or retired surfaces neither start nor publish this work.
        guard presentationActivity.allowsPresentationPublication else { return }
        guard let identity = mediaIdentity else {
            loadGeneration &+= 1
            image = nil
            failed = true
            loadedIdentity = nil
            return
        }
        // A decoded image for this exact source stays mounted; only a new
        // source, a failed attempt, or interrupted work reloads it.
        if loadedIdentity == identity, image != nil { return }
        loadGeneration &+= 1
        let generation = loadGeneration
        image = nil
        failed = false
        do {
            let value = try await model.chatMedia.fullPreview(for: identity, leaseID: leaseID)
            guard generation == loadGeneration,
                  !Task.isCancelled,
                  presentationActivity.allowsPresentationPublication else { return }
            image = value
            loadedIdentity = identity
        } catch is CancellationError {
            // Interrupted work publishes nothing, so the next activation retries.
            return
        } catch {
            guard generation == loadGeneration,
                  !Task.isCancelled,
                  presentationActivity.allowsPresentationPublication else { return }
            failed = true
            loadedIdentity = nil
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
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @State private var loadedIdentity: ChatMediaIdentity?
    @State private var loadedDocument: PreparedAttachmentFilePreview?
    @State private var failed = false
    #if HOSTED_TEST
    @Environment(\.chatHostedRecorder) private var hostedRecorder
    #endif

    var body: some View {
        Group {
            if let prepared {
                rendered(prepared)
            } else if failed {
                DisplayUnavailableView(text: display.fallbackText)
            } else {
                TronLoadingState(label: "Preparing content…", accent: .tronBlue)
                    .frame(height: context == .inline
                        ? DisplayInlineLayoutPolicy.reservedViewportHeight(for: display.kind)
                        : DisplayInlineLayoutPolicy.maximumViewportHeight)
            }
        }
        .task(id: PresentationActivityTaskID(
            source: mediaIdentity,
            presentationActive: presentationActivity.allowsPresentationPublication
        )) { await load() }
    }

    /// What this card shows: the document its own load published, or — only for
    /// the first frame after a remount — the document the loader retained for
    /// this exact identity. The mounted card owns its value, so the loader's
    /// bounded store can evict the identity under it without sending the card
    /// back to a placeholder that resizes the row.
    private var prepared: PreparedAttachmentFilePreview? {
        guard let identity = mediaIdentity else { return nil }
        if loadedIdentity == identity, let loadedDocument { return loadedDocument }
        return model.chatMedia.retainedInlineArtifact(
            for: identity,
            as: PreparedAttachmentFilePreview.self
        )
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

    private func load() async {
        // Covered or retired surfaces neither start nor publish this work.
        guard presentationActivity.allowsPresentationPublication else { return }
        guard let artifact = display.artifact, let identity = mediaIdentity else {
            failed = true
            return
        }
        // The document this card already holds, or the loader's retained one for
        // this identity, is the answer: a mounted card starts no second request.
        if prepared != nil { return }
        failed = false
        do {
            let document = try await model.chatMedia.inlineArtifact(for: identity) { payload in
                return try await AttachmentFilePreviewPolicy.prepare(
                    data: payload.data,
                    name: artifact.name,
                    mimeType: artifact.mimeType
                )
            }
            // A retired surface or a superseded identity publishes nothing.
            guard !Task.isCancelled,
                  presentationActivity.allowsPresentationPublication,
                  mediaIdentity == identity else { return }
            loadedIdentity = identity
            loadedDocument = document
            #if HOSTED_TEST
            // The card's own render, which nothing else can observe for an
            // artifact the loader deliberately does not retain.
            hostedRecorder?.recorder?.recordInlineArtifactPublication(
                id: artifact.id,
                bytes: document.accountedBytes
            )
            #endif
        } catch is CancellationError {
            // Interrupted work publishes nothing, so the next activation asks
            // again instead of keeping a placeholder forever.
        } catch {
            guard !Task.isCancelled,
                  presentationActivity.allowsPresentationPublication,
                  mediaIdentity == identity else { return }
            failed = true
        }
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

/// Prepared generated HTML, retained by `ChatMediaLoader` for its exact
/// artifact identity like any other inline display artifact.
struct PreparedDisplayHTML: Sendable, ChatInlineArtifact {
    let source: String

    var accountedBytes: Int { source.utf8.count }
}

private struct DisplayHTMLArtifactView: View {
    let sessionID: String?
    let display: DisplayProjection
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @State private var loadedIdentity: ChatMediaIdentity?
    @State private var loadedHTML: String?
    @State private var failed = false
    #if HOSTED_TEST
    @Environment(\.chatHostedRecorder) private var hostedRecorder
    #endif

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
        .task(id: PresentationActivityTaskID(
            source: mediaIdentity,
            presentationActive: presentationActivity.allowsPresentationPublication
        )) { await load() }
    }

    private var mediaIdentity: ChatMediaIdentity? {
        guard let artifact = display.artifact, let sessionID else { return nil }
        return model.chatMediaIdentity(blobID: artifact.id, sessionID: sessionID)
    }

    /// Prepared markup this card loaded itself, or — only for the first frame
    /// after a remount — the markup the loader retained for this exact source.
    /// Markup above the loader's per-value ceiling is never retained, and the
    /// card that prepared it still renders it.
    private var html: String? {
        guard let identity = mediaIdentity else { return nil }
        if loadedIdentity == identity, let loadedHTML { return loadedHTML }
        return model.chatMedia.retainedInlineArtifact(for: identity, as: PreparedDisplayHTML.self)?.source
    }

    private func load() async {
        // Covered or retired surfaces neither start nor publish this work.
        guard presentationActivity.allowsPresentationPublication else { return }
        guard let artifact = display.artifact, artifact.size <= 5 * 1_024 * 1_024,
              let identity = mediaIdentity else {
            failed = true
            return
        }
        if html != nil { return }
        failed = false
        do {
            let source = try await model.chatMedia.inlineArtifact(for: identity) { payload in
                guard let source = String(data: payload.data, encoding: .utf8) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return PreparedDisplayHTML(source: source)
            }
            // A retired surface or a superseded identity publishes nothing.
            guard !Task.isCancelled,
                  presentationActivity.allowsPresentationPublication,
                  mediaIdentity == identity else { return }
            loadedIdentity = identity
            loadedHTML = source.source
            #if HOSTED_TEST
            // The card's own render, which nothing else can observe for markup
            // the loader deliberately does not retain.
            hostedRecorder?.recorder?.recordInlineArtifactPublication(
                id: artifact.id,
                bytes: source.source.utf8.count
            )
            #endif
        } catch is CancellationError {
            // Interrupted work publishes nothing, so the next activation asks
            // again instead of keeping a placeholder forever.
        } catch {
            guard !Task.isCancelled,
                  presentationActivity.allowsPresentationPublication,
                  mediaIdentity == identity else { return }
            failed = true
        }
    }
}

struct StaticDisplayWebView: UIViewRepresentable {
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
        // The document sheet owns the custom top blur. WebKit's automatic
        // edge treatment can add a hard cutoff and dividing line beneath it.
        view.scrollView.topEdgeEffect.isHidden = true
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
    let context: DisplayRenderContext
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @State private var playback = DisplayVideoPlayback()

    var body: some View {
        Group {
            if let player = playback.player {
                VideoPlayer(player: player)
                    .accessibilityIdentifier(context == .sheet ? "display.video.sheet.player" : "display.video.player")
                    .frame(minHeight: 220)
            } else if playback.failed || mediaIdentity == nil {
                DisplayUnavailableView(text: display.fallbackText)
            } else {
                TronLoadingState(label: "Preparing media…", accent: .tronBlue)
                    .frame(minHeight: 220)
            }
        }
        .task(id: PresentationActivityTaskID(
            source: mediaIdentity,
            presentationActive: presentationActivity.allowsPresentationPublication
        )) {
            guard presentationActivity.allowsPresentationPublication,
                  let artifact = display.artifact, let sessionID,
                  let identity = mediaIdentity else {
                playback.stop()
                return
            }
            await playback.prepare(mimeType: artifact.mimeType) {
                let url = try await model.displayArtifactFile(
                    id: artifact.id,
                    sessionID: sessionID,
                    profileID: identity.profileID,
                    maximumBytes: artifact.size,
                    expectedBytes: Int64(artifact.size)
                )
                guard presentationActivity.allowsPresentationPublication,
                      mediaIdentity == identity else {
                    BoundedHTTPFileStaging.shared.discard(url)
                    throw CancellationError()
                }
                return url
            }
        }
        .onChange(of: presentationActivity) { _, activity in
            if !activity.allowsPresentationPublication { playback.stop() }
        }
        .onDisappear { playback.stop() }
        #if HOSTED_TEST
        .overlay(alignment: .topLeading) {
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                Text(String(format: "%.2f", playback.player?.currentTime().seconds ?? 0))
                    .font(.system(size: 1))
                    .accessibilityIdentifier(context == .sheet ? "display.video.sheet.playback-time" : "display.video.playback-time")
            }
            .frame(width: 1, height: 1)
            .opacity(0)
            .allowsHitTesting(false)
        }
        #endif
    }

    private var mediaIdentity: ChatMediaIdentity? {
        guard let artifact = display.artifact, let sessionID else { return nil }
        return model.chatMediaIdentity(blobID: artifact.id, sessionID: sessionID)
    }
}

private struct DisplayRemoteWebView: View {
    let display: DisplayProjection

    var body: some View {
        if let value = display.remoteURL, let url = URL(string: value) {
            TronSafariView(url: url)
        } else {
            DisplayUnavailableView(text: display.fallbackText)
        }
    }
}

private struct DisplayUnavailableView: View {
    let text: String
    @Environment(\.displayRenderContext) private var context

    var body: some View {
        if context == .floating {
            // The floating window already owns its glass surface. A nested
            // info card adds a second container and overflows small windows.
            Text(text)
                .font(TronTypography.secondaryDescription)
                .foregroundStyle(Color.tronTextSecondary)
                .multilineTextAlignment(.center)
                #if HOSTED_TEST
                .background(ChatHostedNativeRowProbe(physicalID: "floating-unavailable", semanticID: "floating-unavailable", identity: UUID()))
                #endif
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            TronInfoCard(icon: "rectangle.slash", text: text, accent: .tronBlue)
                .padding(20)
                .frame(maxWidth: .infinity, minHeight: 160)
        }
    }
}

private struct LiveDisplayView: View {
    private struct Source: Hashable {
        let sessionID: String?
        let profileID: String?
        let display: DisplayProjection
        let surface: PresentationSurfaceToken?
        let producerID: UUID
        let activityGeneration: UInt64

        var frameSource: LiveFrameSource {
            LiveFrameSource(
                sessionID: sessionID,
                profileID: profileID,
                presentationIdentity: display.presentationIdentity,
                viewID: display.liveView?.viewId ?? "",
                generation: display.liveView?.generation ?? "",
                surface: surface,
                producerID: producerID,
                activityGeneration: activityGeneration
            )
        }
    }
    let sessionID: String?
    let display: DisplayProjection
    var onFrameGeometry: (@MainActor (LiveFrameUpdate) -> Void)? = nil
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @Environment(\.tronPresentationActivityCoordinator) private var activityCoordinator
    @Environment(\.tronPresentationSurfaceToken) private var surfaceToken
    @State private var image: UIImage?
    @State private var failure: GatewayClient.LiveError?
    @State private var renderedSource: Source?
    @State private var admittedTaskSource: Source?
    @State private var requestID = UUID()
    @State private var viewingActivity = LiveViewingActivity()
    @State private var producerID = UUID()

    var body: some View {
        let source = Source(sessionID: sessionID, profileID: model.selectedGatewayProfileID(), display: display,
                            surface: surfaceToken, producerID: producerID, activityGeneration: viewingActivity.generation)
        let managedActivityAllowsPublication = surfaceToken.map {
            activityCoordinator?.activity(for: $0).allowsPresentationPublication == true
        } ?? false
        let active = scenePhase == .active && viewingActivity.allowsViewing && presentationActivity.allowsPresentationPublication
            && managedActivityAllowsPublication
        // Keep the native activity host on one structural container. A Group
        // distributes its background to each conditional branch: the first
        // image/error would remount the host, restart the task and clear itself.
        // The source/activity check is evaluated by the body, before the task
        // that retires old pixels gets a chance to run.
        let rendersCurrentResult = renderedSource == source && active
        ZStack {
            if rendersCurrentResult, let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rendersCurrentResult, let failure {
                DisplayUnavailableView(text: failure.message)
            } else {
                TronLoadingState(label: display.kind == .nativeLive ? "Connecting to window…" : "Connecting to browser…", accent: .tronBlue)
            }
        }
        .accessibilityLabel((rendersCurrentResult ? failure?.message : nil) ?? display.altText)
        .background(LiveActivityHost(activity: viewingActivity).allowsHitTesting(false))
        // Phase already participates in this task ID. An onChange that also
        // increments the native generation feeds a second ID change back into
        // the same update, so SwiftUI can suppress the final resume task. Only
        // native transitions own that generation and its post-await fence.
        .task(id: PresentationActivityTaskID(source: source, presentationActive: active)) {
            // A cancelled task may still enter its body; it cannot supersede
            // the newer task's request fence or clear its pixels.
            guard !Task.isCancelled else { return }
            let request = UUID()
            requestID = request
            if admittedTaskSource != source {
                admittedTaskSource = source
                onFrameGeometry?(LiveFrameUpdate(source: source.frameSource, geometry: nil))
            }
            image = nil
            failure = nil
            renderedSource = nil
            guard active else { return }
            await receiveFrames(source: source, request: request)
        }
    }

    private func receiveFrames(source: Source, request: UUID) async {
        guard let sessionID = source.sessionID, let liveView = source.display.liveView,
              let profileID = source.profileID else {
            if !Task.isCancelled, requestID == request {
                renderedSource = source
                failure = .ended
            }
            return
        }
        func current() -> Bool {
            // Read the mutable presentation owner after each await, not the
            // captured Environment activity or SwiftUI cancellation timing.
            guard let activityCoordinator, let surface = source.surface else { return false }
            let activity = activityCoordinator.activity(for: surface)
            return !Task.isCancelled && requestID == request && model.selectedGatewayProfileID() == profileID
                && viewingActivity.generation == source.activityGeneration && viewingActivity.allowsViewing
                && activity.allowsPresentationPublication
        }
        guard current() else { return }
        let lease: GatewayClient.LiveLease
        do {
            lease = try await model.openLiveView(kind: source.display.kind, viewId: liveView.viewId, generation: liveView.generation, sessionID: sessionID, profileID: profileID)
        } catch {
            if current() {
                renderedSource = source
                failure = .classify(error)
            }
            return
        }
        await withTaskCancellationHandler {
            do {
                var lastSequence = 0
                while current() {
                    let update = try await lease.frame(after: lastSequence)
                    guard current() else { break }
                    switch update {
                    case .waiting: image = nil
                    case .unchanged: break
                    case let .frame(frame):
                        if frame.sequence > lastSequence {
                            let decoded = try await frame.decode()
                            guard current() else { break }
                            if let decoded {
                                lastSequence = frame.sequence
                                renderedSource = source
                                image = decoded
                                onFrameGeometry?(LiveFrameUpdate(
                                    source: source.frameSource,
                                    geometry: LiveFrameGeometry(
                                        width: CGFloat(frame.width),
                                        height: CGFloat(frame.height)
                                    )
                                ))
                            }
                        }
                    }
                    try await Task.sleep(for: .milliseconds(200))
                }
            } catch {
                if current() {
                    renderedSource = source
                    image = nil
                    failure = .classify(error)
                }
            }
            if requestID == request { image = nil }
            await lease.close()
        } onCancel: {
            // Stop remote capture without waiting for synchronous ImageIO to
            // drain. The original lease owns one cleanup task, joined above.
            Task { await lease.close() }
        }
    }
}

struct DisplaySheet: View {
    let route: DisplayRoute
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @PresentationState private var showingTechnicalDetails = false
    @PresentationState private var imageLeaseID = UUID()
    @PresentationState private var documentLeaseID = UUID()
    @PresentationState private var liveDetent: PresentationDetent = .medium

    @ViewBuilder
    var body: some View {
        if route.display.kind.isLive {
            NavigationStack {
                LiveDisplayView(sessionID: route.sessionID, display: route.display)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .tronTopBlurSurface()
                    .navigationTitle("")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackgroundVisibility(.hidden, for: .navigationBar, .bottomBar)
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            TronSheetTitle(title: route.display.title, accent: .tronBlue)
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button { dismiss() } label: {
                                Image(systemName: "checkmark")
                                    .font(TronTypography.buttonSM)
                                    .tronToolbarAction(accent: .tronBlue)
                            }
                            .accessibilityLabel("Done")
                        }
                    }
            }
            .tronTopBlur(.sheet)
            .presentationDetents([.medium, .large], selection: $liveDetent)
            .presentationDragIndicator(.hidden)
            .tronPresentation()
        } else if (route.display.kind == .webpage || route.display.kind == .hls),
           let value = route.display.remoteURL,
           let url = URL(string: value) {
            TronSafariView(url: url)
                .ignoresSafeArea(.container, edges: .all)
                .accessibilityLabel(route.display.altText)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
        } else if let artifact = route.display.artifact,
                  route.display.kind == .image,
           let identity = model.chatMediaDestinationIdentity(blobID: artifact.id, sessionID: route.sessionID) {
            AttachmentImagePreviewSheet(
                remote: identity,
                leaseID: imageLeaseID,
                title: route.display.title,
                accessibilityLabel: route.display.altText,
                initialImage: nil,
                onTechnicalDetails: route.technicalTool == nil ? nil : { showingTechnicalDetails = true }
            )
            .tronManagedSheet(isPresented: $showingTechnicalDetails, identity: "\(route.sheetPresentationID).technical") {
                if let tool = route.technicalTool {
                    ToolTechnicalDetailsSheet(tool: tool, presentation: ToolDetailPresentation(tool: tool))
                }
            }
        } else if let artifact = route.display.artifact,
                  [.markdown, .text, .code, .pdf, .document].contains(route.display.kind),
                  let identity = model.chatMediaDestinationIdentity(blobID: artifact.id, sessionID: route.sessionID) {
            AttachmentFilePreviewSheet(
                name: artifact.name,
                mimeType: artifact.mimeType,
                source: .remote(identity: identity, leaseID: documentLeaseID),
                title: route.display.title,
                fallbackText: route.display.fallbackText
            )
            .accessibilityLabel(route.display.altText)
        } else {
            let isVideo = route.display.kind == .video
            TronDocumentSheet(
                title: route.display.title,
                detents: isVideo ? [.medium, .large] : [.large],
                initialDetent: isVideo ? .medium : nil
            ) {
                let content = DisplayArtifactContent(sessionID: route.sessionID, display: route.display, context: .sheet)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if isVideo {
                    content
                } else {
                    content.tronDocumentTopBlurSurface()
                }
            }
        }
    }
}
