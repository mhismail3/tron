import SwiftUI
import TronMobileCore

/// A displayed `.swift` file that this iPhone may run as a mini-app (#1339):
/// a completed `code` display whose artifact is a `.swift` file, with the
/// experimental runner switched on. Everything else stays an ordinary code
/// display, so turning the switch off restores the source card at once.
enum SwiftAppDisplay {
    @MainActor static func runs(_ display: DisplayProjection) -> Bool {
        guard display.kind == .code, let artifact = display.artifact else { return false }
        return SwiftAppExperiment.shared.canRun(fileNamed: artifact.name)
    }

    /// The one preparation both the card and the runner use, so the runner
    /// reuses the card's retained value for the same artifact identity instead
    /// of fetching it again.
    static func prepare(
        _ artifact: DisplayArtifactDescriptor
    ) -> @Sendable (ChatMediaPayload) async throws -> PreparedAttachmentFilePreview {
        let name = artifact.name, mimeType = artifact.mimeType
        return { payload in
            try await AttachmentFilePreviewPolicy.prepare(data: payload.data, name: name, mimeType: mimeType)
        }
    }

    /// The complete source, or why it cannot run. A preview cut at the text
    /// bound never runs: it would execute a different program.
    enum Readiness {
        case runnable(String)
        case tooLarge
        case notSource
    }

    static func readiness(of preview: PreparedAttachmentFilePreview) -> Readiness {
        guard case .code(let source) = preview.content else { return .notSource }
        return preview.isTruncated ? .tooLarge : .runnable(source)
    }

    static let tooLargeMessage = "This app is larger than the \(AttachmentFilePreviewPolicy.maximumTextBytes.formatted())-byte limit for running Swift files. View Source shows its first part."
}

/// The inline chat card for a runnable `.swift` display: the app's title and
/// caption with an open control, in the inline display card's lavender glass.
/// The source stays one tap away in its context menu. The card loads the same
/// bounded artifact as an inline code card so it can tell, before the tap,
/// whether the file can run.
struct SwiftAppDisplayCard: View {
    let sessionID: String?
    let display: DisplayProjection
    let onOpenApp: (() -> Void)?
    let onOpenSource: (() -> Void)?

    @Environment(AppModel.self) private var model
    @Environment(\.displayTranscriptReady) private var transcriptReady
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @State private var loadedIdentity: ChatMediaIdentity?
    @State private var loadedPreview: PreparedAttachmentFilePreview?
    @State private var failed = false

    private enum Phase {
        case preparing
        case ready
        case tooLarge
        case unavailable
    }

    var body: some View {
        Button(action: activate) {
            HStack(spacing: 12) {
                appIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(display.title)
                        .font(TronTypography.buttonSM)
                        .foregroundStyle(Color.tronTextPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(TronTypography.secondaryDescription)
                        .foregroundStyle(phase == .tooLarge || phase == .unavailable
                            ? Color.tronAmber : Color.tronTextSecondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: DisplayInlineLayoutPolicy.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(phase == .preparing)
        .tronGlassSurface(
            accent: .tronLavender,
            cornerRadius: DisplayInlineLayoutPolicy.cornerRadius,
            tintOpacity: 0.10,
            interactive: true,
            respectsSettingsTheme: false
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("swiftApp.card")
        .task(id: PresentationActivityTaskID(
            source: transcriptReady ? mediaIdentity : nil,
            presentationActive: transcriptReady && presentationActivity.allowsPresentationPublication
        )) { await load() }
    }

    private var appIcon: some View {
        Image(systemName: "swift")
            .font(TronTypography.sans(size: 22, weight: .semibold))
            .foregroundStyle(Color.tronLavender)
            .frame(width: 44, height: 44)
            .glassEffect(
                .regular.tint(Color.tronLavender.opacity(0.16)),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var trailing: some View {
        switch phase {
        case .preparing:
            ProgressView()
                .tint(.tronLavender)
                .frame(
                    width: DisplayInlineLayoutPolicy.controlTouchTarget,
                    height: DisplayInlineLayoutPolicy.controlTouchTarget
                )
        case .ready:
            DisplayInlineControlFace(systemImage: "play.fill")
        case .tooLarge, .unavailable:
            DisplayInlineControlFace(systemImage: "doc.text")
        }
    }

    private var phase: Phase {
        if let preview {
            if case .runnable = SwiftAppDisplay.readiness(of: preview) { return .ready }
            return .tooLarge
        }
        // A missing identity while connecting is still preparing; only a
        // failed load or a display without an artifact is unavailable.
        return failed || display.artifact == nil ? .unavailable : .preparing
    }

    private var subtitle: String {
        switch phase {
        case .preparing: "Preparing Swift app…"
        case .ready: display.caption ?? "Swift app"
        case .tooLarge: "Too large to run · View Source"
        case .unavailable: "Unavailable · View Source"
        }
    }

    private var accessibilityLabel: String {
        switch phase {
        case .preparing: "\(display.title), Swift app, preparing"
        case .ready: "Open \(display.title), Swift app"
        case .tooLarge: "\(display.title), Swift app too large to run"
        case .unavailable: "\(display.title), Swift app unavailable"
        }
    }

    private var accessibilityHint: String {
        phase == .ready ? "Runs the app in a sheet" : "Shows the source"
    }

    /// A runnable app opens; anything else opens its source sheet, which shows
    /// the truncation notice or the display's fallback text.
    private func activate() {
        switch phase {
        case .ready: onOpenApp?()
        case .tooLarge, .unavailable: onOpenSource?()
        case .preparing: break
        }
    }

    private var preview: PreparedAttachmentFilePreview? {
        guard let identity = mediaIdentity else { return nil }
        if loadedIdentity == identity, let loadedPreview { return loadedPreview }
        return model.chatMedia.retainedInlineArtifact(for: identity, as: PreparedAttachmentFilePreview.self)
    }

    private var mediaIdentity: ChatMediaIdentity? {
        guard let artifact = display.artifact, let sessionID else { return nil }
        return model.chatMediaIdentity(blobID: artifact.id, sessionID: sessionID)
    }

    private func load() async {
        guard transcriptReady, presentationActivity.allowsPresentationPublication,
              let artifact = display.artifact, let identity = mediaIdentity else { return }
        if preview != nil { return }
        failed = false
        do {
            let value = try await model.chatMedia.inlineArtifact(for: identity, prepare: SwiftAppDisplay.prepare(artifact))
            guard !Task.isCancelled, presentationActivity.allowsPresentationPublication,
                  mediaIdentity == identity else { return }
            loadedIdentity = identity
            loadedPreview = value
        } catch is CancellationError {
            // The next activation asks again.
        } catch {
            guard !Task.isCancelled, presentationActivity.allowsPresentationPublication,
                  mediaIdentity == identity else { return }
            failed = true
        }
    }
}

/// The display sheet for a mini-app route: loads the displayed artifact through
/// the same bounded inline loader as its card, then hosts the unchanged
/// `SwiftAppRunnerSheet`. The program and its state live only as long as this
/// managed sheet; reopening the card starts a fresh run.
struct SwiftAppDisplayRunner: View {
    let route: DisplayRoute

    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @PresentationState private var launch: SwiftAppLaunch?
    @PresentationState private var problem: String?

    var body: some View {
        if let launch {
            SwiftAppRunnerSheet(launch: launch)
        } else {
            TronDocumentSheet(title: route.display.title) {
                if let problem {
                    ScrollView {
                        TronInfoCard(icon: "exclamationmark.triangle", text: problem, accent: .tronBlue)
                            .padding(TronSpacing.xlarge)
                            .accessibilityIdentifier("swiftApp.unavailable")
                    }
                } else {
                    TronSheetLoadingState(label: "Preparing Swift app…", accent: .tronBlue)
                }
            }
            .task(id: PresentationActivityTaskID(
                source: mediaIdentity,
                presentationActive: presentationActivity.allowsPresentationPublication
            )) { await load() }
        }
    }

    private var mediaIdentity: ChatMediaIdentity? {
        guard let artifact = route.display.artifact else { return nil }
        return model.chatMediaIdentity(blobID: artifact.id, sessionID: route.sessionID)
    }

    private func load() async {
        guard presentationActivity.allowsPresentationPublication, launch == nil, problem == nil else { return }
        guard let artifact = route.display.artifact, let identity = mediaIdentity else {
            problem = route.display.fallbackText
            return
        }
        do {
            let preview = try await model.chatMedia.inlineArtifact(for: identity, prepare: SwiftAppDisplay.prepare(artifact))
            guard !Task.isCancelled, presentationActivity.allowsPresentationPublication,
                  mediaIdentity == identity else { return }
            switch SwiftAppDisplay.readiness(of: preview) {
            case .runnable(let source):
                // The link host is the paired Gateway selected now, exactly as
                // the source sheet's Run control resolves it (#1160).
                launch = SwiftAppLaunch(name: artifact.name, source: source, linkHost: model.profiles.selected?.host)
            case .tooLarge:
                problem = SwiftAppDisplay.tooLargeMessage
            case .notSource:
                problem = route.display.fallbackText
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, presentationActivity.allowsPresentationPublication,
                  mediaIdentity == identity else { return }
            problem = route.display.fallbackText
        }
    }
}
