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

enum DisplayInlineDisclosureDirection: Equatable, Sendable {
    case collapse
    case expand
}

struct DisplayInlineDisclosureTransition: Equatable, Sendable {
    let direction: DisplayInlineDisclosureDirection
    let generation: Int
}

struct DisplayInlineDisclosureState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case expanded
        case collapsing
        case collapsed
        case expanding
    }

    private(set) var phase: Phase = .expanded
    private(set) var generation = 0

    var rendersInlineContainer: Bool {
        phase == .expanded || phase == .collapsing
    }

    var inlineOpacity: Double { phase == .expanded ? 1 : 0 }
    var pillOpacity: Double { phase == .expanded ? 0 : 1 }
    var isCollapsed: Bool { phase == .collapsed || phase == .expanding }
    var permitsInteraction: Bool { phase == .expanded || phase == .collapsed }

    func proposed(_ direction: DisplayInlineDisclosureDirection) -> DisplayInlineDisclosureTransition? {
        guard (direction == .collapse && phase == .expanded)
                || (direction == .expand && phase == .collapsed) else { return nil }
        return DisplayInlineDisclosureTransition(direction: direction, generation: generation + 1)
    }

    @discardableResult
    mutating func begin(_ transition: DisplayInlineDisclosureTransition) -> Bool {
        let expectedSource: Phase = transition.direction == .collapse ? .expanded : .collapsed
        guard phase == expectedSource, transition.generation == generation + 1 else { return false }
        generation = transition.generation
        phase = transition.direction == .collapse ? .collapsing : .expanding
        return true
    }

    @discardableResult
    mutating func complete(_ transition: DisplayInlineDisclosureTransition) -> Bool {
        let expectedSource: Phase = transition.direction == .collapse ? .collapsing : .expanding
        guard generation == transition.generation, phase == expectedSource else { return false }
        phase = transition.direction == .collapse ? .collapsed : .expanded
        return true
    }

    mutating func settleTransientPhase() {
        generation &+= 1
        switch phase {
        case .collapsing: phase = .collapsed
        case .expanding: phase = .expanded
        case .expanded, .collapsed: break
        }
    }
}

struct DisplayToolView: View {
    let tool: ChatToolDescriptor
    let onOpenTechnicalDetails: () -> Void

    @Environment(\.canonicalResourceSessionID) private var sessionID
    @Environment(\.displayPresentationHandler) private var present
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @State private var disclosure = DisplayInlineDisclosureState()
    @State private var expandedHeight: CGFloat = 0
    @State private var pillHeight: CGFloat = 0

    private var display: DisplayProjection? { tool.display }
    private var effectiveSurface: DisplaySurface {
        display.map(DisplayPresentationPolicy.effectiveSurface)
            ?? tool.requestedDisplaySurface ?? .sheet
    }
    private var activationSurface: DisplaySurface {
        display.map(DisplayPresentationPolicy.activationSurface) ?? effectiveSurface
    }

    var body: some View {
        Group {
            if let display, completedInlineDisplay {
                inlineDisclosureHost(display)
            } else {
                displayPill
            }
        }
        // Projection installation never owns disclosure animation. Only an
        // explicit user action animates this measured, clipped row host, so
        // reconnect and retained resume cannot inherit a local height transition.
        .transaction { transaction in
            if scenePhase != .active || !presentationActivity.allowsContinuousAnimation {
                transaction.disablesAnimations = true
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { settleDisclosureWithoutAnimation() }
        }
        .onChange(of: presentationActivity.allowsViewportObservation) { _, active in
            if !active { settleDisclosureWithoutAnimation() }
        }
        .onDisappear { settleDisclosureWithoutAnimation() }
    }

    @ViewBuilder
    private func inlineDisclosureHost(_ display: DisplayProjection) -> some View {
        ZStack(alignment: .topLeading) {
            inlineExpandedSurface(display)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(disclosure.inlineOpacity)
                .scaleEffect(disclosure.isCollapsed ? 0.985 : 1, anchor: .topLeading)
                .allowsHitTesting(disclosure.phase == .expanded)
                .accessibilityHidden(disclosure.isCollapsed)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    recordDisclosureHeight($0, expanded: true)
                }

            displayPill
                .fixedSize(horizontal: false, vertical: true)
                .opacity(disclosure.pillOpacity)
                .scaleEffect(disclosure.isCollapsed ? 1 : 0.985, anchor: .topLeading)
                .allowsHitTesting(disclosure.phase == .collapsed)
                .accessibilityHidden(!disclosure.isCollapsed)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    recordDisclosureHeight($0, expanded: false)
                }
        }
        .frame(height: disclosureHeight, alignment: .top)
        .clipped()
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button("Tool Details", systemImage: "info.circle", action: onOpenTechnicalDetails)
        }
    }

    @ViewBuilder
    private func inlineExpandedSurface(_ display: DisplayProjection) -> some View {
        if display.kind == .image {
            DisplayInlineImageChip(
                sessionID: sessionID,
                display: display,
                onOpenSheet: inlineSheetAction(for: display),
                onCollapse: collapseInline
            )
        } else {
            DisplayInlineContainer(
                sessionID: sessionID,
                display: display,
                onCollapse: collapseInline,
                onOpenSheet: inlineSheetAction(for: display)
            )
        }
    }

    private var disclosureHeight: CGFloat? {
        let measured = disclosure.rendersInlineContainer ? expandedHeight : pillHeight
        return measured > 0 ? measured : nil
    }

    private func recordDisclosureHeight(_ height: CGFloat, expanded: Bool) {
        guard height.isFinite, height > 0 else { return }
        let current = expanded ? expandedHeight : pillHeight
        guard abs(current - height) > 0.5 else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if expanded { expandedHeight = height } else { pillHeight = height }
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

    private var disclosureAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.28)
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
        switch activationSurface {
        case .sheet:
            present?(.showSheet(route))
        case .inline:
            expandInline()
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
        return switch activationSurface {
        case .sheet: "Open"
        case .inline: disclosure.isCollapsed ? "Show inline" : "Inline"
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
        let action = switch activationSurface {
        case .sheet: "Opens sheet"
        case .inline: disclosure.isCollapsed ? "Expands inline" : "Displayed inline"
        case .floating: "Opens floating window"
        }
        return [display?.title ?? "Display", detail, action].joined(separator: ", ")
    }

    private func collapseInline() {
        transitionDisclosure(.collapse)
    }

    private func expandInline() {
        transitionDisclosure(.expand)
    }

    private func transitionDisclosure(_ direction: DisplayInlineDisclosureDirection) {
        guard let transition = disclosure.proposed(direction) else { return }
        // The persistent ZStack crossfades both endpoints while this one frame
        // animates between measured heights. Clipping follows the interpolated
        // host boundary, so neither endpoint can paint across neighboring rows.
        withAnimation(disclosureAnimation) {
            guard disclosure.begin(transition) else { return }
            _ = disclosure.complete(transition)
        }
    }

    private func settleDisclosureWithoutAnimation() {
        guard !disclosure.permitsInteraction else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { disclosure.settleTransientPhase() }
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
    static let imageChipScale: CGFloat = 1.7
    static var imageChipSide: CGFloat {
        PendingPhotoRemoveLayoutPolicy.previewSide * imageChipScale
    }

    static func openingViewportHeight(for kind: DisplayKind) -> CGFloat {
        switch kind {
        case .image, .video, .audio, .pdf: 220
        case .markdown, .text, .code, .html, .document, .webpage, .hls: 180
        }
    }
}

private struct DisplayInlineImageChip: View {
    let sessionID: String?
    let display: DisplayProjection
    let onOpenSheet: (() -> Void)?
    let onCollapse: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.displayTranscriptReady) private var transcriptReady
    @State private var image: UIImage?
    @State private var loadedIdentity: ChatMediaIdentity?
    @State private var failed = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: { onOpenSheet?() }) {
                imageSurface
            }
            .buttonStyle(.plain)
            .disabled(onOpenSheet == nil)
            .accessibilityLabel("Open \(display.title) photo preview")

            Button(action: onCollapse) {
                ZStack {
                    Circle().fill(.ultraThinMaterial)
                    Circle().stroke(Color.white.opacity(0.22), lineWidth: 0.5)
                    Image(systemName: "xmark")
                        .font(TronTypography.sans(size: 11, weight: .bold))
                        .foregroundStyle(Color.tronTextPrimary)
                }
                .frame(width: 24, height: 24)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Collapse \(display.title)")
            .padding(2)
        }
        .frame(
            width: DisplayInlineLayoutPolicy.imageChipSide,
            height: DisplayInlineLayoutPolicy.imageChipSide,
            alignment: .topLeading
        )
        .task(id: transcriptReady ? mediaIdentity : nil) { await loadThumbnail() }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var imageSurface: some View {
        ZStack {
            Color.black.opacity(0.88)
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
                    .tint(.tronLavender)
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
    }

    private var mediaIdentity: ChatMediaIdentity? {
        guard let artifact = display.artifact, let sessionID else { return nil }
        return model.chatMediaIdentity(blobID: artifact.id, sessionID: sessionID)
    }

    private func loadThumbnail() async {
        guard transcriptReady, let identity = mediaIdentity else { return }
        if loadedIdentity != identity {
            image = nil
            failed = false
        } else if image != nil {
            return
        }
        do {
            image = try await model.chatMedia.thumbnail(for: identity)
            loadedIdentity = identity
        } catch is CancellationError {
            return
        } catch {
            failed = true
            loadedIdentity = identity
        }
    }
}

private struct DisplayInlineContainer: View {
    let sessionID: String?
    let display: DisplayProjection
    let onCollapse: () -> Void
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

            Group {
                if transcriptReady {
                    inlineContent
                } else {
                    TronLoadingState(label: "Preparing display…", accent: .tronLavender)
                        .frame(height: DisplayInlineLayoutPolicy.openingViewportHeight(for: display.kind))
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
        .task(id: PresentationActivityTaskID(
            source: mediaIdentity,
            presentationActive: presentationActivity.allowsPresentationPublication
        )) {
            guard presentationActivity.allowsPresentationPublication else {
                tearDown()
                return
            }
            await prepare()
        }
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
