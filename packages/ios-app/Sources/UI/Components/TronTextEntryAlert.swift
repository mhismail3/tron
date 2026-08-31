import SwiftUI
import UIKit

/// Native single-line text-entry alert with a stable trailing clear control.
/// UIKit owns horizontal text scrolling, so long values move beneath the
/// fixed clear button instead of displacing it.
struct TronTextEntryAlertModifier: ViewModifier {
    let title: String
    let placeholder: String
    @Binding var text: String
    @Binding var isPresented: Bool
    let confirmTitle: String
    let cancelTitle: String
    let onConfirm: (String) -> Void

    func body(content: Content) -> some View {
        content.background {
            TronTextEntryAlertPresenter(
                title: title,
                placeholder: placeholder,
                text: $text,
                isPresented: $isPresented,
                confirmTitle: confirmTitle,
                cancelTitle: cancelTitle,
                onConfirm: onConfirm
            )
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }
}

extension View {
    func tronTextEntryAlert(
        _ title: String,
        isPresented: Binding<Bool>,
        text: Binding<String>,
        placeholder: String,
        confirmTitle: String = "Save",
        cancelTitle: String = "Cancel",
        onConfirm: @escaping (String) -> Void
    ) -> some View {
        modifier(TronTextEntryAlertModifier(
            title: title,
            placeholder: placeholder,
            text: text,
            isPresented: isPresented,
            confirmTitle: confirmTitle,
            cancelTitle: cancelTitle,
            onConfirm: onConfirm
        ))
    }
}

private struct TronTextEntryAlertPresenter: UIViewControllerRepresentable {
    let title: String
    let placeholder: String
    @Binding var text: String
    @Binding var isPresented: Bool
    let confirmTitle: String
    let cancelTitle: String
    let onConfirm: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        context.coordinator.update(configuration: self, host: controller)
    }

    static func dismantleUIViewController(_ controller: UIViewController, coordinator: Coordinator) {
        coordinator.dismissIfNeeded()
    }

    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        private var configuration: TronTextEntryAlertPresenter?
        private weak var alert: UIAlertController?
        private weak var field: UITextField?
        private weak var saveAction: UIAlertAction?

        func update(configuration: TronTextEntryAlertPresenter, host: UIViewController) {
            self.configuration = configuration
            guard configuration.isPresented else {
                dismissIfNeeded()
                return
            }

            if let field {
                if field.text != configuration.text { field.text = configuration.text }
                updateSaveAdmission(field.text ?? "")
                return
            }

            guard host.viewIfLoaded?.window != nil else { return }
            present(configuration: configuration, from: host)
        }

        func dismissIfNeeded() {
            alert?.dismiss(animated: false)
            retireAlert()
        }

        private func present(
            configuration: TronTextEntryAlertPresenter,
            from host: UIViewController
        ) {
            let alert = UIAlertController(
                title: configuration.title,
                message: nil,
                preferredStyle: .alert
            )
            alert.view.tintColor = UIColor(Color.tronEmerald)
            alert.addTextField { [weak self] field in
                guard let self else { return }
                field.placeholder = configuration.placeholder
                field.text = configuration.text
                field.clearButtonMode = .whileEditing
                field.returnKeyType = .done
                field.delegate = self
                field.addTarget(self, action: #selector(self.textChanged(_:)), for: .editingChanged)
                field.accessibilityLabel = configuration.placeholder
                self.field = field
            }

            let cancel = UIAlertAction(title: configuration.cancelTitle, style: .cancel) { [weak self] _ in
                self?.cancel()
            }
            let save = UIAlertAction(title: configuration.confirmTitle, style: .default) { [weak self] _ in
                self?.submit(dismissManually: false)
            }
            alert.addAction(cancel)
            alert.addAction(save)
            saveAction = save
            self.alert = alert
            updateSaveAdmission(configuration.text)

            presentingController(from: host).present(alert, animated: true) { [weak self] in
                self?.field?.becomeFirstResponder()
            }
        }

        @objc private func textChanged(_ sender: UITextField) {
            let value = sender.text ?? ""
            configuration?.text = value
            updateSaveAdmission(value)
        }

        func textFieldShouldClear(_ textField: UITextField) -> Bool {
            configuration?.text = ""
            updateSaveAdmission("")
            return true
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            guard admitted(textField.text ?? "") else { return false }
            submit(dismissManually: true)
            return false
        }

        private func cancel() {
            configuration?.isPresented = false
            retireAlert()
        }

        private func submit(dismissManually: Bool) {
            guard let configuration else { return }
            let value = field?.text ?? configuration.text
            guard admitted(value) else { return }
            configuration.text = value
            configuration.onConfirm(value)
            configuration.isPresented = false
            if dismissManually { alert?.dismiss(animated: true) }
            retireAlert()
        }

        private func updateSaveAdmission(_ value: String) {
            saveAction?.isEnabled = admitted(value)
        }

        private func admitted(_ value: String) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        private func retireAlert() {
            alert = nil
            field = nil
            saveAction = nil
        }

        private func presentingController(from host: UIViewController) -> UIViewController {
            var controller = host.view.window?.rootViewController ?? host
            while true {
                if let presented = controller.presentedViewController {
                    controller = presented
                } else if let navigation = controller as? UINavigationController,
                          let visible = navigation.visibleViewController {
                    controller = visible
                } else if let tabs = controller as? UITabBarController,
                          let selected = tabs.selectedViewController {
                    controller = selected
                } else {
                    return controller
                }
            }
        }
    }
}
