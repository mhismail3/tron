import SwiftUI
import UIKit

struct ChatMessageMenuAction: Identifiable {
    enum ID: String { case moveEarlier, moveLater, clearQueue }
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

    func body(content: Content) -> some View {
        ChatMessageContextMenuSurface(content: content, text: text, mutationIdentity: mutationIdentity, actions: actions)
            .accessibilityActions {
                if !text.isEmpty { Button("Copy") { UIPasteboard.general.string = text } }
                ForEach(actions) { action in
                    Button(action.title, role: action.destructive ? .destructive : nil, action: action.perform)
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

    func makeCoordinator() -> ChatMessageContextMenuOwner { ChatMessageContextMenuOwner() }

    func makeUIViewController(context: Context) -> UIHostingController<ChatMessageNativeContent<Content>> {
        let host = UIHostingController(rootView: ChatMessageNativeContent(content: content, values: context.environment))
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        context.coordinator.attach(to: host.view)
        return host
    }

    func updateUIViewController(_ host: UIHostingController<ChatMessageNativeContent<Content>>, context: Context) {
        host.rootView = ChatMessageNativeContent(content: content, values: context.environment)
        context.coordinator.text = text
        context.coordinator.mutationIdentity = mutationIdentity
        context.coordinator.actions = actions
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

    func makeMenu() -> UIMenu? {
        let copiedText = text
        let identity = mutationIdentity
        var items: [UIMenuElement] = []
        if !copiedText.isEmpty {
            items.append(UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = copiedText
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
        guard let source, source.window != nil else { return nil }
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear
        parameters.visiblePath = UIBezierPath(roundedRect: source.bounds, cornerRadius: ChatPromptContainerStyle.cornerRadius)
        return UITargetedPreview(view: source, parameters: parameters)
    }
}
