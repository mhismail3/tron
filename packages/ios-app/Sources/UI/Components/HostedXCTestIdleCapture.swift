#if HOSTED_TEST
import Darwin
import SwiftUI
import UIKit

@MainActor
extension HostedPresentationProbe {
    private static var source: (any DispatchSourceSignal)?
    private static let launch = UUID().uuidString
    private static let coordinators = NSHashTable<PresentationActivityCoordinator>.weakObjects()
    private static var directory: URL {
        URL.cachesDirectory.appending(path: "tron-xctest-idle", directoryHint: .isDirectory)
    }

    static func installIdleCapture() {
        guard source == nil, let birth = processBirth() else { return }
        signal(SIGUSR2, SIG_IGN)
        let signalSource = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        signalSource.setEventHandler {
            MainActor.assumeIsolated {
                capture()
            }
        }
        source = signalSource
        signalSource.resume()
        write(["pid": getpid(), "launch": launch, "process_birth": birth], name: "ready.json")
    }

    private static func processBirth() -> [String: Int]? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var query = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&query, u_int(query.count), &info, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.size else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return ["seconds": Int(start.tv_sec), "microseconds": Int(start.tv_usec)]
    }

    static func observeForIdleCapture(_ coordinator: PresentationActivityCoordinator) {
        guard coordinators.allObjects.count < 16 else { return }
        coordinators.add(coordinator)
    }

    private static func capture() {
        guard let input = try? FileHandle(forReadingFrom: directory.appending(path: "request.json")) else { return }
        defer { try? input.close() }
        guard let requestData = try? input.read(upToCount: 1025), requestData.count <= 1024,
              let request = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any],
              request["pid"] as? Int32 == getpid(), request["launch"] as? String == launch,
              let requestID = request["request"] as? String, requestID.count == 32,
              let birth = processBirth() else { return }
        var layers: [[String: Any]] = []
        var animationBudget = 128
        var visited = 0
        var truncated = false
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        var pending = Array(windows.prefix(16).enumerated().map { ($0.element.layer, $0.offset, 0) })
        while let (layer, window, depth) = pending.popLast() {
            visited += 1
            let keys = layer.animationKeys() ?? []
            if !keys.isEmpty {
                let animations: [[String: Any]] = keys.prefix(min(16, animationBudget)).compactMap { key in
                    guard let animation = layer.animation(forKey: key) else { return nil }
                    return [
                        "type": NSStringFromClass(type(of: animation)),
                        "duration": finite(animation.duration),
                        "speed": finite(Double(animation.speed)),
                        "timeOffset": finite(animation.timeOffset),
                        "beginTime": finite(animation.beginTime),
                        "repeatCount": animation.repeatCount.isFinite ? Double(animation.repeatCount) : -1,
                        "repeatDuration": animation.repeatDuration.isFinite ? animation.repeatDuration : -1,
                        "autoreverses": animation.autoreverses,
                        "removedOnCompletion": animation.isRemovedOnCompletion,
                    ]
                }
                animationBudget -= animations.count
                layers.append([
                    "index": visited, "window": window, "depth": depth,
                    "type": NSStringFromClass(type(of: layer)), "hidden": layer.isHidden,
                    "speed": finite(Double(layer.speed)), "timeOffset": finite(layer.timeOffset),
                    "hasPresentationLayer": layer.presentation() != nil,
                    "animationCount": keys.count, "animations": animations,
                ])
                truncated = truncated || keys.count > animations.count
            }
            let children = layer.sublayers ?? []
            let remaining = max(0, 512 - visited - pending.count)
            if depth < 24 {
                pending.append(contentsOf: children.prefix(remaining).map { ($0, window, depth + 1) })
                truncated = truncated || children.count > remaining
            } else {
                truncated = truncated || !children.isEmpty
            }
        }
        write([
            "schema": "tron.hosted-xctest-idle.v1", "pid": getpid(), "launch": launch, "request": requestID, "process_birth": birth,
            "mainThread": Thread.isMainThread, "mediaTime": CACurrentMediaTime(),
            "animationsEnabled": UIView.areAnimationsEnabled,
            "inheritedAnimationDuration": UIView.inheritedAnimationDuration,
            "transactionAnimationDuration": CATransaction.animationDuration(),
            "transactionDisablesActions": CATransaction.disableActions(),
            "windowCount": windows.count, "visitedLayerCount": visited,
            "truncated": truncated || windows.count > 16, "animatedLayers": layers,
            "surfaceCoordinators": coordinators.allObjects.map(\.hostedIdleSnapshot),
            "surfaceCoordinatorLimit": 16,
        ], name: "snapshot.json")
    }

    private static func finite(_ value: Double) -> Double {
        value.isFinite ? value : -1
    }

    private static func write(_ value: [String: Any], name: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              data.count <= 256_000 else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appending(path: name), options: .atomic)
    }
}
#endif
