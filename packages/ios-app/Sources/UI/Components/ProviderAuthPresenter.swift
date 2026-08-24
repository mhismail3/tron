import SwiftUI

struct ProviderAuthPresenter: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var presentedOperationID: String?

    private var currentOperationID: String? { model.authPrompt?.operationId ?? model.authEvent?.operationId }

    func body(content: Content) -> some View {
        content
            .onChange(of: currentOperationID) { _, operationID in
                guard presentedOperationID == nil, let operationID else { return }
                presentedOperationID = operationID
            }
            .sheet(isPresented: Binding(
                get: { currentOperationID != nil },
                set: { presented in
                    guard !presented else { return }
                    let closingOperationID = presentedOperationID
                    presentedOperationID = currentOperationID == closingOperationID ? nil : currentOperationID
                    guard let closingOperationID else { return }
                    Task { await model.cancelAuth(operationID: closingOperationID) }
                }
            )) { ProviderAuthSheet() }
    }
}


extension View {
    func providerAuthPresenter() -> some View { modifier(ProviderAuthPresenter()) }
}
