import SwiftUI

struct GlobalSheets: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let notice = model.notifications.last {
                Text(notice).font(TronTypography.caption).foregroundStyle(Color.tronTextPrimary).padding(.horizontal, 12).padding(.vertical, 8)
                    .glassEffect(.regular.tint(Color.tronEmerald.opacity(0.16)), in: Capsule()).padding(.top, 8)
                    .onTapGesture { model.notifications.removeAll() }
            }
        }
    }
}

private struct ProviderAuthPresenter: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { model.authPrompt != nil || model.authEvent != nil },
            set: { presented in if !presented { Task { await model.cancelAuth() } } }
        )) {
            ProviderAuthSheet()
        }
    }
}

extension View {
    func gatewayGlobalSheets() -> some View { modifier(GlobalSheets()) }
    func providerAuthPresenter() -> some View { modifier(ProviderAuthPresenter()) }
}
