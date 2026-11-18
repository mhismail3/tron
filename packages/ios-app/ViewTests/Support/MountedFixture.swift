import SwiftUI
import UIKit
import XCTest
@testable import TronMobile

struct FixtureNotReady: Error, CustomStringConvertible {
    let description: String
}

@MainActor
final class MountedFixture {
    static let hangFrames = 600

    let window: UIWindow
    private let host: UIHostingController<AnyView>
    private let savedArguments: [String]
    private let savedTheme: ThemeColor
    private let savedFilter: DashboardServerFilterState

    init(_ arguments: [String], theme: ThemeColor = .emerald,
         contentSize: UIContentSizeCategory = .large) throws {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw FixtureNotReady(description: "the hosted app has no window scene")
        }
        Self.enableAccessibility()
        UIView.setAnimationsEnabled(false)
        savedArguments = HostedLaunch.arguments
        savedTheme = AppearanceSettings.shared.themeColor
        HostedLaunch.arguments = ["TronMobile"] + arguments
        AppearanceSettings.shared.themeColor = theme
        savedFilter = AppLocalBehaviorSettings.shared.dashboardFilter
        HostedFixtureRoot.prepareLaunch()
        AppLocalBehaviorSettings.shared.dashboardFilter = DashboardServerFilterPreferences.load()
        host = UIHostingController(rootView: AnyView(HostedFixtureRoot(hostedModel: AppModel())
            .environment(\.scenePhase, .active)
            .transaction { $0.animation = nil; $0.disablesAnimations = true }))
        host.traitOverrides.preferredContentSizeCategory = contentSize
        window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.windowLevel = .normal + 1
        window.rootViewController = host
        window.makeKeyAndVisible()
    }

    func close() {
        host.dismiss(animated: false)
        window.isHidden = true
        window.rootViewController = nil
        HostedLaunch.arguments = savedArguments
        AppearanceSettings.shared.themeColor = savedTheme
        AppLocalBehaviorSettings.shared.dashboardFilter = savedFilter
        UIView.setAnimationsEnabled(true)
    }

    var top: UIView {
        var controller: UIViewController = host
        while let next = controller.presentedViewController, !next.isBeingDismissed { controller = next }
        return controller.view
    }

    var settled: Bool {
        var controller: UIViewController? = host
        while let current = controller {
            if current.isBeingPresented || current.isBeingDismissed || current.transitionCoordinator != nil { return false }
            controller = current.presentedViewController
        }
        return !Self.animating(window.layer)
    }

    private static func animating(_ layer: CALayer) -> Bool {
        if layer.animationKeys()?.contains(where: { key in
            layer.animation(forKey: key).map { $0.duration.isFinite && $0.repeatCount < .greatestFiniteMagnitude } == true
        }) == true { return true }
        return layer.sublayers?.contains(where: animating) ?? false
    }

    func until(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<Self.hangFrames {
            if settled, condition() { return }
            await Self.nextFrame()
        }
        throw FixtureNotReady(description: "\(what)\n\(tree())")
    }

    func element(_ key: String, in root: UIView? = nil) -> NSObject? {
        Self.elements(in: root ?? top).last { node in
            Self.identifier(node) == key || node.accessibilityLabel == key
        }
    }

    func activate(_ key: String) async throws {
        var target: NSObject?
        try await until("\(key) is on screen") {
            target = element(key)
            return target.map { !$0.accessibilityTraits.contains(.notEnabled) } ?? false
        }
        guard target?.accessibilityActivate() == true else { throw FixtureNotReady(description: "\(key) refused activation") }
    }

    func reveal(_ node: NSObject) async throws {
        let frame = node.accessibilityFrame
        let scrolls = Self.views(UIScrollView.self, in: top).filter {
            $0.convert($0.bounds, to: nil).contains(CGPoint(x: frame.midX, y: $0.convert($0.bounds, to: nil).midY))
                && $0.contentSize.height > $0.bounds.height
        }
        guard let scroll = scrolls.max(by: { $0.bounds.height < $1.bounds.height }) else { return }
        let visible = scroll.convert(scroll.bounds, to: nil).inset(by: scroll.adjustedContentInset)
        guard !visible.contains(frame) else { return }
        let maximum = scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height
        let offset = scroll.contentOffset.y + frame.midY - visible.midY
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: min(max(offset, -scroll.adjustedContentInset.top), maximum)),
                                animated: false)
        await Self.nextFrame()
        await Self.nextFrame()
    }

    func expandTopSheet() async throws {
        var controller: UIViewController = host
        while let next = controller.presentedViewController { controller = next }
        guard let sheet = controller.sheetPresentationController, sheet.selectedDetentIdentifier != .large,
              sheet.detents.contains(where: { $0.identifier == .large }) else { return }
        sheet.selectedDetentIdentifier = .large
        try await until("the sheet reaches its large detent") { controller.view.convert(controller.view.bounds, to: nil).minY < 120 }
    }

    func navigationTitle(_ title: String) -> NSObject? {
        let bars = Self.views(UINavigationBar.self, in: top).filter { !$0.isHidden && $0.alpha > 0 && $0.window != nil }
            .map { $0.convert($0.bounds, to: nil) }
        return Self.elements(in: top).last { node in
            node.accessibilityLabel == title
                && bars.contains { $0.contains(CGPoint(x: node.accessibilityFrame.midX, y: node.accessibilityFrame.midY)) }
        }
    }

    func toolbarActions(around title: NSObject) -> [NSObject] {
        let point = CGPoint(x: title.accessibilityFrame.midX, y: title.accessibilityFrame.midY)
        guard let bar = Self.views(UINavigationBar.self, in: top).last(where: {
            !$0.isHidden && $0.convert($0.bounds, to: nil).contains(point)
        }) else { return [] }
        let area = bar.convert(bar.bounds, to: nil)
        return Self.elements(in: top).filter { node in
            let frame = node.accessibilityFrame
            return node.isAccessibilityElement && node.accessibilityTraits.contains(.button)
                && !node.accessibilityTraits.contains(.notEnabled) && frame.width > 0
                && area.contains(CGPoint(x: frame.midX, y: frame.midY)) && window.bounds.intersects(frame)
        }
    }

    func render(_ area: CGRect? = nil) -> UIImage {
        let format = UIGraphicsImageRendererFormat(for: window.traitCollection)
        return UIGraphicsImageRenderer(bounds: area ?? window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
    }

    func pixels(_ area: CGRect, image: UIImage? = nil) -> [[Double]]? {
        let bounds = area.integral
        let image = image ?? render(bounds)
        let local = image.size == window.bounds.size ? area : area.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
        guard let source = image.cgImage else { return nil }
        let scale = CGFloat(source.width) / image.size.width
        guard let crop = source.cropping(to: local.applying(CGAffineTransform(scaleX: scale, y: scale))) else { return nil }
        let width = crop.width, height = crop.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 0, to: bytes.count, by: 4).map { [Double(bytes[$0]), Double(bytes[$0 + 1]), Double(bytes[$0 + 2])] }
    }

    func ink(_ area: CGRect, image: UIImage? = nil) -> [Double]? {
        guard let pixels = pixels(area, image: image) else { return nil }
        var sum = [0.0, 0.0, 0.0], count = 0.0
        for rgb in pixels where rgb.max()! - rgb.min()! > 60 {
            for channel in 0..<3 { sum[channel] += rgb[channel] / 255 }
            count += 1
        }
        return count > 10 ? sum.map { $0 / count } : nil
    }

    func chroma(_ area: CGRect, range minimum: Double, image: UIImage? = nil) -> (ink: [Double], count: Int)? {
        guard let pixels = pixels(area, image: image) else { return nil }
        var sum = [0.0, 0.0, 0.0], count = 0
        for rgb in pixels {
            let low = rgb.min()!, range = rgb.max()! - low
            guard range >= minimum else { continue }
            for channel in 0..<3 { sum[channel] += (rgb[channel] - low) / range }
            count += 1
        }
        return count > 0 ? (sum.map { $0 / Double(count) }, count) : nil
    }

    func labelled(_ prefix: String) -> NSObject? {
        Self.elements(in: top).last {
            $0.isAccessibilityElement && $0.accessibilityTraits.contains(.button) && $0.accessibilityLabel?.hasPrefix(prefix) == true
        }
    }

    func animations() -> [String] {
        var found: [String] = []
        func visit(_ layer: CALayer) {
            if let keys = layer.animationKeys(), !keys.isEmpty {
                found.append("\(type(of: layer)) \(layer.delegate.map { String(describing: type(of: $0)) } ?? "-") \(keys) \(keys.compactMap { layer.animation(forKey: $0).map { "\($0.duration)/\($0.repeatCount)" } })")
            }
            layer.sublayers?.forEach(visit)
        }
        visit(window.layer)
        return found
    }

    func inked(_ what: String, _ area: () -> CGRect?) async throws -> [Double] {
        try await still(what) { area().flatMap { ink($0) } }
    }

    func still(_ what: String, _ sample: () -> [Double]?) async throws -> [Double] {
        var previous: [Double]?
        var found: [Double]?
        try await until("\(what) is drawn and still") {
            previous = found
            found = sample()
            guard let found, let previous else { return false }
            return zip(found, previous).allSatisfy { abs($0 - $1) < 0.002 }
        }
        return found!
    }

    func tree() -> String {
        "ANIMATIONS\n" + animations().joined(separator: "\n") + "\n" +
        Self.views(UINavigationBar.self, in: top).map { "bar \($0.convert($0.bounds, to: nil)) hidden=\($0.isHidden) alpha=\($0.alpha)" }
            .joined(separator: "\n") + "\n" + Self.elements(in: top).compactMap { node in
            let id = Self.identifier(node) ?? ""
            let label = node.accessibilityLabel ?? ""
            return id.isEmpty && label.isEmpty ? nil : "\(type(of: node)) id=\(id) label=\(label) traits=\(node.accessibilityTraits.rawValue) element=\(node.isAccessibilityElement) frame=\(node.accessibilityFrame)"
        }.joined(separator: "\n")
    }

    static func elements(in root: NSObject) -> [NSObject] {
        var found: [NSObject] = []
        var stack: [NSObject] = [root]
        var seen = Set<ObjectIdentifier>()
        while let node = stack.popLast(), found.count < 50_000 {
            guard seen.insert(ObjectIdentifier(node)).inserted else { continue }
            if let view = node as? UIView, view.isHidden || view.alpha == 0 { continue }
            found.append(node)
            if let view = node as? UIView { stack.append(contentsOf: view.subviews.reversed()) }
            if let children = node.accessibilityElements as? [NSObject] { stack.append(contentsOf: children.reversed()) }
            let count = node.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                stack.append(contentsOf: (0..<count).reversed().compactMap { node.accessibilityElement(at: $0) as? NSObject })
            }
        }
        return found
    }

    static func identifier(_ node: NSObject) -> String? {
        let getter = NSSelectorFromString("accessibilityIdentifier")
        return node.responds(to: getter) ? node.perform(getter)?.takeUnretainedValue() as? String : nil
    }

    static func views<T: UIView>(_ type: T.Type, in root: UIView) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { views(type, in: $0) }
    }

    static func nextFrame() async {
        await withCheckedContinuation { continuation in
            FrameWaiter.shared.add(continuation)
        }
    }

    private static func enableAccessibility() {
        guard let library = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let symbol = dlsym(library, "_AXSSetAutomationEnabled") else { return }
        typealias Setter = @convention(c) (Int32) -> Void
        unsafeBitCast(symbol, to: Setter.self)(1)
    }
}

@MainActor
private final class FrameWaiter: NSObject {
    static let shared = FrameWaiter()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var link: CADisplayLink?

    func add(_ continuation: CheckedContinuation<Void, Never>) {
        waiters.append(continuation)
        if link == nil {
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    @objc private func tick() {
        let ready = waiters
        waiters.removeAll()
        link?.invalidate()
        link = nil
        ready.forEach { $0.resume() }
    }
}

extension XCTestCase {
    @MainActor
    func mounted(_ arguments: [String], theme: ThemeColor = .emerald, contentSize: UIContentSizeCategory = .large,
                 _ body: (MountedFixture) async throws -> Void) async throws {
        let fixture = try MountedFixture(arguments, theme: theme, contentSize: contentSize)
        defer { fixture.close() }
        do { try await body(fixture) } catch let error as FixtureNotReady {
            XCTFail(error.description)
        }
    }
}
