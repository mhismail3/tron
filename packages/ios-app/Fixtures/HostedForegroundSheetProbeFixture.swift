#if HOSTED_TEST
import Foundation
import SwiftUI
import UIKit

/// Opt-in investigation instrumentation, never compiled into the shipping app.
@MainActor enum ForegroundSheetProbe {
    private static var count = 0
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
        let value: [String: Any] = ["at": Date().timeIntervalSince1970, "pid": ProcessInfo.processInfo.processIdentifier,
                                    "event": event, "identity": identity]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let file = try? FileHandle(forWritingTo: url) else { return }
        defer { try? file.close() }
        try? file.seekToEnd()
        try? file.write(contentsOf: data + Data([10]))
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
