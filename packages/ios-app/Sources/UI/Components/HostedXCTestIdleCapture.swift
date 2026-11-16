#if HOSTED_TEST
import Darwin
import ObjectiveC
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
        HostedViewAnimationLedger.install()
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
                        "key": key,
                        "keyPath": (animation as? CAPropertyAnimation)?.keyPath ?? "",
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
                    "owners": owners(of: layer),
                ])
                truncated = truncated || keys.count > animations.count
            }
            let children = layer.sublayers ?? []
            let remaining = max(0, 4096 - visited - pending.count)
            if depth < 64 {
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
            "unstoppedViewAnimations": HostedViewAnimationLedger.unstopped(owners: owners(of:)),
        ], name: "snapshot.json")
    }

    static func owners(of layer: CALayer) -> [String] {
        var view = layer.delegate as? UIView
        var chain: [String] = []
        while let current = view, chain.count < 12 {
            chain.append(NSStringFromClass(type(of: current)))
            view = current.superview
        }
        return chain
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
private enum HostedViewAnimationLedger {
    private struct Added {
        weak var layer: CALayer?
        let key: String
        let frames: [NSNumber]
    }

    private struct Outstanding {
        let animation: CAAnimation
        let added: Added?
        let order: Int
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var added: [ObjectIdentifier: (CAAnimation, Added)] = [:]
    nonisolated(unsafe) private static var addedOrder: [ObjectIdentifier] = []
    nonisolated(unsafe) private static var outstanding: [ObjectIdentifier: Outstanding] = [:]
    nonisolated(unsafe) private static var starts = 0
    nonisolated(unsafe) private static var stops = 0

    static func install() {
        guard let state = NSClassFromString("UIViewAnimationState") else { return }
        typealias Add = @convention(c) (CALayer, Selector, CAAnimation, NSString?) -> Void
        let addSelector = #selector(CALayer.add(_:forKey:))
        guard let addMethod = class_getInstanceMethod(CALayer.self, addSelector) else { return }
        let add = unsafeBitCast(method_getImplementation(addMethod), to: Add.self)
        let addBlock: @convention(block) (CALayer, CAAnimation, NSString?) -> Void = { layer, animation, key in
            add(layer, addSelector, animation, key)
            guard let delegate = animation.delegate, type(of: delegate) == state,
                  let stored = layer.animation(forKey: key as String? ?? "") else { return }
            let record = Added(layer: layer, key: key as String? ?? "", frames: Array(Thread.callStackReturnAddresses.prefix(48)))
            lock.withLock {
                let id = ObjectIdentifier(stored)
                added[id] = (stored, record)
                addedOrder.append(id)
                if addedOrder.count > 2048 { added.removeValue(forKey: addedOrder.removeFirst()) }
            }
        }
        method_setImplementation(addMethod, imp_implementationWithBlock(addBlock))
        typealias Start = @convention(c) (AnyObject, Selector, CAAnimation) -> Void
        let startSelector = #selector(CAAnimationDelegate.animationDidStart(_:))
        guard let startMethod = class_getInstanceMethod(state, startSelector) else { return }
        let start = unsafeBitCast(method_getImplementation(startMethod), to: Start.self)
        let startBlock: @convention(block) (AnyObject, CAAnimation) -> Void = { receiver, animation in
            lock.withLock {
                starts += 1
                let id = ObjectIdentifier(animation)
                if outstanding.count < 256 { outstanding[id] = Outstanding(animation: animation, added: added[id]?.1, order: starts) }
            }
            start(receiver, startSelector, animation)
        }
        method_setImplementation(startMethod, imp_implementationWithBlock(startBlock))
        typealias Stop = @convention(c) (AnyObject, Selector, CAAnimation, Bool) -> Void
        let stopSelector = #selector(CAAnimationDelegate.animationDidStop(_:finished:))
        guard let stopMethod = class_getInstanceMethod(state, stopSelector) else { return }
        let stop = unsafeBitCast(method_getImplementation(stopMethod), to: Stop.self)
        let stopBlock: @convention(block) (AnyObject, CAAnimation, Bool) -> Void = { receiver, animation, finished in
            lock.withLock {
                stops += 1
                outstanding.removeValue(forKey: ObjectIdentifier(animation))
            }
            stop(receiver, stopSelector, animation, finished)
        }
        method_setImplementation(stopMethod, imp_implementationWithBlock(stopBlock))
    }

    @MainActor static func unstopped(owners: (CALayer) -> [String]) -> [String: Any] {
        let (open, started, stopped) = lock.withLock { (outstanding.values.sorted { $0.order < $1.order }, starts, stops) }
        return [
            "starts": started, "stops": stopped, "outstandingCount": open.count,
            "animations": open.suffix(16).map { entry -> [String: Any] in
                let layer = entry.added?.layer
                return [
                    "order": entry.order, "type": NSStringFromClass(type(of: entry.animation)),
                    "key": entry.added?.key ?? "", "keyPath": (entry.animation as? CAPropertyAnimation)?.keyPath ?? "",
                    "duration": entry.animation.duration,
                    "repeatCount": entry.animation.repeatCount.isFinite ? Double(entry.animation.repeatCount) : -1,
                    "layerAlive": layer != nil,
                    "stillAttached": entry.added.map { layer?.animationKeys()?.contains($0.key) ?? false } ?? false,
                    "inWindow": (layer?.delegate as? UIView)?.window != nil,
                    "owners": layer.map(owners) ?? [],
                    "addedFrom": entry.added?.frames.compactMap(symbol) ?? [],
                ]
            },
        ]
    }

    private static func symbol(_ address: NSNumber) -> String? {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: address.uintValue), &info) != 0 else { return nil }
        let image = info.dli_fname.map { URL(fileURLWithPath: String(cString: $0)).lastPathComponent } ?? "?"
        let name = info.dli_sname.map { String(cString: $0) } ?? "?"
        return "\(image) \(name)"
    }
}
#endif
