import Foundation
@preconcurrency import UIKit

/// Native owner for the complete interactive chat surface. The transcript and
/// composer remain separate controllers, but this parent is the only owner of
/// their shared vertical geometry and keyboard relationship.
@MainActor
final class ChatUIKitSessionSurfaceController: UIViewController {
    let transcript: ChatUIKitChatViewController
    let composer: ChatUIKitComposerController

    private var composerHeightConstraint: NSLayoutConstraint?
    private var lastMeasuredWidth: CGFloat = 0
    private var isUpdatingComposerHeight = false

    #if HOSTED_TEST
    var hostedComposerHeight: CGFloat { composerHeightConstraint?.constant ?? 0 }
    #endif

    init(
        transcript: ChatUIKitChatViewController = ChatUIKitChatViewController(),
        composer: ChatUIKitComposerController = ChatUIKitComposerController()
    ) {
        self.transcript = transcript
        self.composer = composer
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ChatUIKitTheme.background
        view.keyboardLayoutGuide.followsUndockedKeyboard = false
        view.keyboardLayoutGuide.usesBottomSafeArea = true

        addChild(transcript)
        addChild(composer)
        transcript.view.translatesAutoresizingMaskIntoConstraints = false
        composer.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(transcript.view)
        view.addSubview(composer.view)

        let composerHeight = composer.view.heightAnchor.constraint(equalToConstant: 48)
        composerHeight.priority = .required
        composerHeightConstraint = composerHeight
        NSLayoutConstraint.activate([
            transcript.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            transcript.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            transcript.view.topAnchor.constraint(equalTo: view.topAnchor),
            transcript.view.bottomAnchor.constraint(equalTo: composer.view.topAnchor),
            composer.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composer.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composer.view.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            composerHeight
        ])
        transcript.didMove(toParent: self)
        composer.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = view.bounds.width
        guard width > 0, abs(width - lastMeasuredWidth) > 0.5 else { return }
        lastMeasuredWidth = width
        if updateComposerHeight() { view.setNeedsLayout() }
    }

    @discardableResult
    func applyTranscript(_ input: ChatUIKitPresentationInput) -> ChatUIKitViewportTransactionOutcome {
        loadViewIfNeeded()
        let outcome = transcript.apply(input)
        view.layoutIfNeeded()
        return outcome
    }

    @discardableResult
    func applyComposer(_ input: ChatUIKitComposerInput) -> Bool {
        loadViewIfNeeded()
        guard composer.apply(input) else { return false }
        if updateComposerHeight() { view.layoutIfNeeded() }
        return true
    }

    func setPresentationActivity(_ activity: ChatUIKitPresentationActivity) {
        transcript.setPresentationActivity(activity)
    }

    /// Auto Layout measures the complete native composer after each immutable
    /// projection. No SwiftUI geometry callback or keyboard-height mirror is
    /// allowed to participate in transcript sizing.
    @discardableResult
    private func updateComposerHeight() -> Bool {
        guard !isUpdatingComposerHeight,
              let composerHeightConstraint,
              view.bounds.width > 0 else { return false }
        isUpdatingComposerHeight = true
        defer { isUpdatingComposerHeight = false }

        composer.view.setNeedsLayout()
        composer.view.layoutIfNeeded()
        guard let measured = composer.preferredContentHeight(for: view.bounds.width) else {
            return false
        }
        guard abs(measured - composerHeightConstraint.constant) > 0.5 else { return false }
        composerHeightConstraint.constant = measured
        return true
    }
}
