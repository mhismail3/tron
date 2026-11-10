import SwiftUI

struct HostedHomePushTap: ViewModifier {
    nonisolated static let openLatency: Duration? = ProcessInfo.processInfo.arguments.contains("-home-push-tap-on-foreground")
        ? .milliseconds(300) : nil

    let model: AppModel
    let machineID: String?
    @Environment(\.scenePhase) private var scenePhase
    @State private var backgrounded = false
    @State private var requested = false

    func body(content: Content) -> some View {
        if Self.openLatency == nil {
            content
        } else {
            content
                .overlay(alignment: .bottom) {
                    Text("push:\(!requested ? "none" : model.pushNavigationRequest == nil ? "consumed" : "pending")")
                        .accessibilityIdentifier("fixture.home-push")
                        .font(.system(size: 1)).opacity(0.01)
                }
                .task { await model.start() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { backgrounded = true }
                    guard phase == .active, backgrounded, !requested else { return }
                    requested = true
                    let ordinary = ProcessInfo.processInfo.arguments.contains("-home-push-ordinary")
                    model.requestPushNavigation(PushNotificationTap.admit([
                        "tron": ["kind": "agent_notification", "requestId": "fixture-home-push-0001"],
                        "sessionId": ordinary ? "ordinary-session" : "home-session",
                        "machineId": machineID ?? "",
                    ]))
                }
        }
    }
}
