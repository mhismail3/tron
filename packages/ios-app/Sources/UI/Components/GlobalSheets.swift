import SwiftUI

struct GlobalSheets: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let notice = model.latestNotice {
                Text(notice).font(TronTypography.caption).foregroundStyle(Color.tronTextPrimary).padding(.horizontal, 12).padding(.vertical, 8)
                    .glassEffect(.regular.tint(Color.tronEmerald.opacity(0.16)), in: Capsule()).padding(.top, 8)
                    .onTapGesture { model.dismissNotices() }
            }
        }
    }
}

private struct ProviderAuthPresenter: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var presentedOperationID: String?

    private var currentOperationID: String? {
        model.authPrompt?.operationId ?? model.authEvent?.operationId
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: currentOperationID) { _, operationID in
                // Capture the operation when this presenter first opens. Do not
                // replace it while dismissal is in flight: a stale dismissal
                // callback must never cancel a newer login operation.
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
            )) {
                ProviderAuthSheet()
            }
    }
}

extension View {
    func gatewayGlobalSheets() -> some View { modifier(GlobalSheets()) }
    func providerAuthPresenter() -> some View { modifier(ProviderAuthPresenter()) }
}
