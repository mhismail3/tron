#if HOSTED_TEST
import Foundation
import SwiftUI
import UIKit

/// Opt-in investigation instrumentation, never compiled into the shipping app.
@MainActor enum ForegroundSheetProbe {
    private static var count = 0
    private static var stack: [String] = []
    private static var stackChanges = 0
    private static var frames = 0
    private static var liveAnchors = Set<String>()
    private static var rpcCounts: [String: Int] = [:]
    static let enabled = ProcessInfo.processInfo.arguments.contains("-foreground-sheet-probe")
    private static let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("foreground-sheet-probe.jsonl")

    static func recordHomeRead(_ state: HomeSheetReadOwner.State, owner: HomeSheetReadOwner) {
        let description: String
        switch state {
        case .idle: description = "idle " + Thread.callStackSymbols.prefix(12).joined(separator: " | ")
        case .loading(let read, let content): description = "loading retained=\(content != nil) request=\(read.requestID) token=\(read.identity.surfaceToken)"
        case .loaded(let read, _): description = "loaded request=\(read.requestID) token=\(read.identity.surfaceToken)"
        case .failed: description = "failed"
        }
        record("home-read-state", "\(ObjectIdentifier(owner)) \(description)")
    }

    static func record(_ event: String, _ identity: String) {
        guard enabled, count < 20_000 else { return }
        count += 1
        if event == "rpc" { rpcCounts[identity, default: 0] += 1 }
        if event == "anchor-create" { liveAnchors.insert(identity) }
        if event == "anchor-deinit" { liveAnchors.remove(identity) }
        let value: [String: Any] = ["at": Date().timeIntervalSince1970, "pid": ProcessInfo.processInfo.processIdentifier,
                                    "event": event, "identity": identity]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let file = try? FileHandle(forWritingTo: url) else { return }
        defer { try? file.close() }
        try? file.seekToEnd()
        try? file.write(contentsOf: data + Data([10]))
    }

    static func nativeSummary(foreground: Int) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [
            "stack": stack, "changes": stackChanges, "liveAnchors": liveAnchors.count,
            "rpc": rpcCounts, "frames": frames, "foreground": foreground,
        ], options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func sampleNativeStack(in window: UIWindow) {
        guard enabled, window.windowScene?.activationState == .foregroundActive else { return }
        frames += 1
        var current = window.rootViewController
        var next: [String] = []
        while let controller = current, next.count < 16 {
            next.append(String(describing: ObjectIdentifier(controller)))
            current = controller.presentedViewController
        }
        guard next != stack else { return }
        stack = next
        stackChanges += 1
        record("native-stack", next.joined(separator: ">"))
    }
}

/// Keep the opt-in observation wiring with its fixture owner.
struct ForegroundSheetProbeOverlay: View {
    let model: AppModel
    var body: some View {
        if ForegroundSheetProbe.enabled {
            ForegroundNativeStackProbe(foreground: { [weak model] in
                model?.foregroundReconciliationGeneration ?? -1
            }).frame(width: 1, height: 1).allowsHitTesting(false)
        }
    }
}

/// Passive, test-only observation of the actual UIKit presentation chain on
/// rendered frames. AX reads the live value without causing SwiftUI renders.
struct ForegroundNativeStackProbe: UIViewRepresentable {
    let foreground: @MainActor () -> Int
    func makeUIView(context: Context) -> Probe { Probe(foreground: foreground) }
    func updateUIView(_ view: Probe, context: Context) { view.foreground = foreground }
    static func dismantleUIView(_ view: Probe, coordinator: ()) { view.stop() }

    final class Probe: UIView {
        private var link: CADisplayLink?
        var foreground: @MainActor () -> Int
        init(foreground: @escaping @MainActor () -> Int) {
            self.foreground = foreground
            super.init(frame: .zero)
            isAccessibilityElement = true
            accessibilityIdentifier = "fixture.foreground-native"
            accessibilityLabel = "Foreground native presentation observation"
        }
        required init?(coder: NSCoder) { fatalError("not used") }
        override var accessibilityValue: String? {
            get { ForegroundSheetProbe.nativeSummary(foreground: foreground()) }
            set { }
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            stop()
            guard window != nil else { return }
            let link = CADisplayLink(target: WeakTarget(self), selector: #selector(WeakTarget.tick(_:)))
            self.link = link
            link.add(to: .main, forMode: .common)
        }
        func stop() { link?.invalidate(); link = nil }
        func sample() { if let window { ForegroundSheetProbe.sampleNativeStack(in: window) } }
    }

    @MainActor private final class WeakTarget: NSObject {
        weak var view: Probe?
        init(_ view: Probe) { self.view = view }
        @objc func tick(_ link: CADisplayLink) {
            guard let view else { link.invalidate(); return }
            view.sample()
        }
    }
}

struct ForegroundSheetNativeProbe: UIViewRepresentable {
    let identity: String
    func makeUIView(context: Context) -> Probe { Probe(identity: identity) }
    func updateUIView(_ uiView: Probe, context: Context) { }

    final class Probe: UIView {
        let identity: String
        init(identity: String) { self.identity = identity; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("not used") }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard ForegroundSheetProbe.enabled else { return }
            guard window != nil else {
                ForegroundSheetProbe.record("native-detach", "\(identity) probe=\(ObjectIdentifier(self))"); return
            }
            sample()
            Task { @MainActor [weak self] in self?.sample() }
        }
        private func sample() {
            guard let window else { return }
            var chain: [String] = []
            var controller = window.rootViewController
            while let current = controller, chain.count < 16 {
                chain.append("\(type(of: current))@\(ObjectIdentifier(current)) frame=\(current.view.frame)")
                controller = current.presentedViewController
            }
            ForegroundSheetProbe.record("native-attach", "\(identity) probe=\(ObjectIdentifier(self)) " + chain.joined(separator: " > "))
        }
    }
}
#endif
