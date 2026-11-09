import SwiftUI
import UIKit

struct ChatMessageMenuAction: Identifiable {
    enum ID: String { case moveEarlier, moveLater, clearQueue, toolDetails }
    let id: ID
    let title: String
    let icon: String
    var destructive = false
    let perform: @MainActor () -> Void
}

struct ChatMessageCopyMenu: ViewModifier {
    let text: String
    var mutationIdentity: String? = nil
    var actions: [ChatMessageMenuAction] = []
    /// A plain bubble is one accessibility element: its text, its delivery
    /// state and its menu actions. A card whose content holds its own controls
    /// passes false and keeps them reachable.
    var isOneElement = true
    @Environment(\.chatMessageDeliveryState) private var deliveryState

    func body(content: Content) -> some View {
        let surface = ChatMessageContextMenuSurface(content: content, text: text, mutationIdentity: mutationIdentity,
                                                    actions: actions, element: isOneElement ? .init(value: deliveryState) : nil)
        if isOneElement {
            surface
        } else {
            surface.accessibilityActions {
                if !text.isEmpty { Button("Copy") { ChatMessageContextMenuOwner.copy(text) } }
                ForEach(actions) { action in
                    Button(action.title, role: action.destructive ? .destructive : nil, action: action.perform)
                }
            }
        }
    }
}

/// A native container is necessary: a background interaction loses hits to the
/// glass surface, while an overlay steals attachment taps. Owning the ancestor
/// preserves descendant controls and gives UIKit the actual bubble as a preview.
private struct ChatMessageContextMenuSurface<Content: View>: UIViewControllerRepresentable {
    let content: Content
    let text: String
    let mutationIdentity: String?
    let actions: [ChatMessageMenuAction]
    /// Set for a one-element bubble, described by the host view itself.
    let element: ChatMessageAccessibilityElement?

    func makeCoordinator() -> ChatMessageContextMenuOwner { ChatMessageContextMenuOwner() }

    func makeUIViewController(context: Context) -> UIHostingController<ChatMessageNativeContent<Content>> {
        let host = UIHostingController(rootView: ChatMessageNativeContent(content: content, values: context.environment))
        host.safeAreaRegions = []
        // Loaded media changes inside this nested host without a representable
        // update. Propagate its new ideal size to the outer SwiftUI row too.
        host.sizingOptions = .intrinsicContentSize
        host.view.backgroundColor = .clear
        context.coordinator.attach(to: host.view)
        return host
    }

    func updateUIViewController(_ host: UIHostingController<ChatMessageNativeContent<Content>>, context: Context) {
        host.rootView = ChatMessageNativeContent(content: content, values: context.environment)
        context.coordinator.text = text
        context.coordinator.mutationIdentity = mutationIdentity
        context.coordinator.actions = actions
        context.coordinator.describe(host.view, as: element)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: UIHostingController<ChatMessageNativeContent<Content>>,
                     context: Context) -> CGSize? {
        uiViewController.sizeThatFits(in: CGSize(width: proposal.width ?? UserPromptTextLayoutPolicy.maximumWidth,
                                                height: proposal.height ?? .greatestFiniteMagnitude))
    }

    static func dismantleUIViewController(_ host: UIHostingController<ChatMessageNativeContent<Content>>,
                                          coordinator: ChatMessageContextMenuOwner) {
        coordinator.retire()
    }
}

private struct ChatMessageNativeContent<Content: View>: View {
    let content: Content
    let values: EnvironmentValues
    var body: some View { content.environment(\.self, values) }
}

struct ChatMessageAccessibilityElement {
    let value: String?
}

/// One UIKit interaction owns an immutable open menu. SwiftUI updates configure
/// future requests only, never call updateVisibleMenu during a Siri handoff.
final class ChatMessageContextMenuOwner: NSObject, UIContextMenuInteractionDelegate {
    var text = ""
    var mutationIdentity: String?
    var actions: [ChatMessageMenuAction] = []
    private weak var source: UIView?
    private lazy var interaction = UIContextMenuInteraction(delegate: self)

    func attach(to view: UIView) {
        source = view
        view.addInteraction(interaction)
    }

    func retire() {
        let oldSource = source
        source = nil
        actions = []
        interaction.dismissMenu()
        oldSource?.removeInteraction(interaction)
    }

    static func copy(_ text: String) {
        UIPasteboard.general.string = text
        TronHaptics.shared.play(.copied)
    }

    /// A one-element bubble is described on the nested host's own view, in
    /// UIKit: that host's SwiftUI tree reached accessibility only in some
    /// launches, and a SwiftUI element around it still exposed it in others.
    func describe(_ view: UIView, as element: ChatMessageAccessibilityElement?) {
        view.isAccessibilityElement = element != nil
        guard let element else {
            view.accessibilityLabel = nil
            view.accessibilityValue = nil
            view.accessibilityCustomActions = nil
            return
        }
        view.accessibilityLabel = text
        view.accessibilityValue = element.value
        view.accessibilityTraits = .staticText
        let copiedText = text
        view.accessibilityCustomActions = (copiedText.isEmpty ? [] : [UIAccessibilityCustomAction(name: "Copy") { _ in
            Self.copy(copiedText)
            return true
        }]) + actions.map { action in
            UIAccessibilityCustomAction(name: action.title) { _ in
                action.perform()
                return true
            }
        }
    }

    func makeMenu() -> UIMenu? {
        let copiedText = text
        let identity = mutationIdentity
        var items: [UIMenuElement] = []
        if !copiedText.isEmpty {
            items.append(UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
                Self.copy(copiedText)
            })
        }
        for action in actions {
            let id = action.id
            items.append(UIAction(title: action.title, image: UIImage(systemName: action.icon),
                                  attributes: action.destructive ? .destructive : []) { [weak self] _ in
                // Retained menu commands must recheck live authority after a
                // queue update, row reuse, or removal; Copy retains its text.
                guard let self, self.source?.window != nil, let identity,
                      self.mutationIdentity == identity,
                      let current = self.actions.first(where: { $0.id == id }) else { return }
                current.perform()
            })
        }
        return items.isEmpty ? nil : UIMenu(children: items)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let source, source.window != nil, source.bounds.contains(location),
              let menu = makeMenu() else { return nil }
        // Omit suggestedActions rather than filtering localized Siri titles or
        // reaching into Apple's private identifiers/responder implementation.
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
                                highlightPreviewForItemWithIdentifier identifier: NSCopying) -> UITargetedPreview? {
        preview()
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
                                dismissalPreviewForItemWithIdentifier identifier: NSCopying) -> UITargetedPreview? {
        preview()
    }

    private func preview() -> UITargetedPreview? {
        guard let source, let window = source.window else { return nil }
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        parameters.visiblePath = UIBezierPath(roundedRect: source.bounds, cornerRadius: ChatPromptContainerStyle.cornerRadius)
        // The nearest scroll ancestor can be reflected. UIKit must animate the
        // upright source in window space, never inherit that ancestor's flip.
        let center = source.convert(CGPoint(x: source.bounds.midX, y: source.bounds.midY), to: window)
        return UITargetedPreview(view: source, parameters: parameters,
            target: UIPreviewTarget(container: window, center: center, transform: .identity))
    }
}
