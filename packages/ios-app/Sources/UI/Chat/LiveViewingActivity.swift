import Observation
import SwiftUI
import UIKit

/// The mounted UIKit view supplies the exact scene, not an arbitrary connected
/// scene or a captured SwiftUI phase. Native transitions fence awaits immediately;
/// the generation also restarts a task after coalesced inactive/active transitions.
@MainActor
@Observable
final class LiveViewingActivity {
    private(set) var generation: UInt64 = 0
    @ObservationIgnored private weak var nativeView: LiveActivityView?
    var allowsViewing: Bool { nativeView?.allowsViewing == true }

    fileprivate func mounted(_ view: LiveActivityView) {
        nativeView = view
        generation &+= 1
    }

    fileprivate func changed(_ view: LiveActivityView) {
        guard nativeView === view else { return }
        generation &+= 1
    }

    fileprivate func retired(_ view: LiveActivityView) {
        guard nativeView === view else { return }
        nativeView = nil
        generation &+= 1
    }
}

struct LiveActivityHost: UIViewRepresentable {
    let activity: LiveViewingActivity
    func makeUIView(context: Context) -> LiveActivityView { LiveActivityView(activity: activity) }
    func updateUIView(_ uiView: LiveActivityView, context: Context) { uiView.bind(activity) }
    static func dismantleUIView(_ uiView: LiveActivityView, coordinator: ()) { uiView.retire() }
}

final class LiveActivityView: UIView {
    private weak var activity: LiveViewingActivity?
    private var applicationActive = false
    private var sceneActive = false

    fileprivate var allowsViewing: Bool {
        applicationActive && sceneActive
            && UIApplication.shared.applicationState == .active
            && window?.windowScene?.activationState == .foregroundActive
    }

    init(activity: LiveViewingActivity) {
        self.activity = activity
        super.init(frame: .zero)
        isUserInteractionEnabled = false
    }

    fileprivate func bind(_ activity: LiveViewingActivity) {
        guard self.activity !== activity else { return }
        self.activity?.retired(self)
        self.activity = activity
        if window?.windowScene != nil { activity.mounted(self) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let scene = window?.windowScene else { retire(); return }
        applicationActive = UIApplication.shared.applicationState == .active
        sceneActive = scene.activationState == .foregroundActive
        for name in [UIApplication.willResignActiveNotification, UIApplication.didBecomeActiveNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(applicationChanged(_:)), name: name, object: UIApplication.shared)
        }
        for name in [UIScene.willDeactivateNotification, UIScene.didActivateNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(sceneChanged(_:)), name: name, object: scene)
        }
        activity?.mounted(self)
    }

    fileprivate func retire() {
        NotificationCenter.default.removeObserver(self)
        applicationActive = false
        sceneActive = false
        activity?.retired(self)
    }

    @objc private func applicationChanged(_ notification: Notification) {
        let active = notification.name == UIApplication.didBecomeActiveNotification
        guard active != applicationActive else { return }
        applicationActive = active
        activity?.changed(self)
    }

    @objc private func sceneChanged(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, scene === window?.windowScene else { return }
        let active = notification.name == UIScene.didActivateNotification
        guard active != sceneActive else { return }
        sceneActive = active
        activity?.changed(self)
    }
}
