import SwiftUI

/// `-home-push-tap-on-foreground` (#1684): after the Home dashboard fixture returns
/// from the background, delivers the push tap the production handler delivers while
/// the scene activates (`ProductionSceneRoot`): for Home's chapter, or with
/// `-home-push-ordinary` for the ordinary chat. The fixture Gateway then answers
/// `session.open` with a device-sized latency, so the push target overlaps the
/// restoring Home chat's open.
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
                // Push navigation admits taps only once the app has started.
                .task { await model.start() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { backgrounded = true }
                    guard phase == .active, backgrounded, !requested else { return }
                    requested = true
                    let ordinary = ProcessInfo.processInfo.arguments.contains("-home-push-ordinary")
                    // An approval push carries the relay's category: its tap opens the chat's sheet (#2050).
                    let approval = ProcessInfo.processInfo.arguments.contains("-home-push-approval")
                    model.requestPushNavigation(PushNotificationTap.admit([
                        "tron": ["kind": "agent_notification", "requestId": "fixture-home-push-0001"],
                        "sessionId": ordinary ? "ordinary-session" : "home-session",
                        "machineId": machineID ?? "",
                    ], categoryIdentifier: approval ? "settings-approval" : ""))
                }
        }
    }
}
