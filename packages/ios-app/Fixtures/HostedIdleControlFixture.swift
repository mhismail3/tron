#if HOSTED_TEST
import SwiftUI
import UIKit

struct HostedIdleControlFixture: View {
    @State private var active = false
    @State private var rotation = false
    @State private var probes = 0
    @State private var coordinator = PresentationActivityCoordinator()

    private var kind: String {
        let arguments = ProcessInfo.processInfo.arguments
        let index = arguments.firstIndex(of: "-tron-idle-control")!
        return arguments[index + 1]
    }

    var body: some View {
        TronPresentationSurface(id: "fixture.idle-control") {
            VStack(spacing: 24) {
                Text("idle-control:\(kind) active:\(active) probes:\(probes)")
                    .accessibilityIdentifier("fixture.idle-state")
                Button("Start") {
                    active = true
                    if kind == "blocked-main" {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            Thread.sleep(forTimeInterval: 20)
                        }
                    }
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(20))
                        active = false
                    }
                }
                Button("Probe") { probes += 1 }
                if kind == "orb" || kind == "covered-orb" {
                    ProcessActivityOrb(mode: .solving, size: 60, isVisible: active)
                        .environment(\.tronPresentationActivity, kind == "covered-orb" ? .covered : .active)
                } else if kind == "swiftui", active {
                    Rectangle().fill(.blue).frame(width: 60, height: 60)
                        .rotationEffect(.degrees(rotation ? 360 : 0))
                        .onAppear {
                            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { rotation = true }
                        }
                } else if kind == "uikit" {
                    HostedIdleUIViewAnimation(active: active).frame(width: 60, height: 60)
                }
            }
        }
        .environment(\.tronPresentationActivityCoordinator, coordinator)
    }
}

private struct HostedIdleUIViewAnimation: UIViewRepresentable {
    let active: Bool
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .systemBlue
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {
        if active, view.layer.animationKeys()?.isEmpty != false {
            UIView.animate(withDuration: 0.8, delay: 0, options: [.repeat, .autoreverse, .allowUserInteraction]) {
                view.transform = CGAffineTransform(translationX: 30, y: 0)
            }
        } else if !active {
            view.layer.removeAllAnimations()
            view.transform = .identity
        }
    }
    static func dismantleUIView(_ view: UIView, coordinator: ()) { view.layer.removeAllAnimations() }
}
#endif
