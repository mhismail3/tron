import UIKit
import XCTest

/// Restructure UI locks (docs/restructure/plan.md §6.6). A lock pins one
/// hosted-fixture screen state with two goldens beside this file in `Goldens/`:
///
/// - `<name>.a11y.txt`: the app's accessibility hierarchy as normalized text
///   (type, identifier, label, value, traits, frame in whole points), compared
///   exactly;
/// - `<name>.png`: a screenshot on the pinned simulator (`config/ci-toolchain.env`),
///   status bar masked, compared within `UILock.channelTolerance` per channel and
///   at most `UILock.maxDifferingPixels` differing pixels. PNG goldens are
///   gitignored local baselines, recorded on the base commit, until their
///   storage is decided (#1464); the text goldens are committed.
///
/// `scripts/tron-ios-test run --update-locks` rewrites the goldens instead of
/// comparing; a missing golden fails. A failure writes the actual capture and a
/// diff under `test-results/ui-locks/` and puts the text diff in the message.
enum UILock {
    /// A pixel differs when any RGBA channel moves by more than this (of 255).
    static let channelTolerance = 8
    /// A screenshot lock fails above this many differing pixels.
    static let maxDifferingPixels = 0
    /// The status bar carries the clock and battery: it is painted out of every
    /// screenshot. iPhone 17 Pro's status bar is 62 pt tall.
    static let statusBarPoints = 62
    /// How long a state may keep changing before the lock gives up on it.
    static let settleTimeout: TimeInterval = 10

    static let recordHint = "record it on your base commit with "
        + "`scripts/tron-ios-test run --update-locks --only-testing TronMobileUITests/TronUILockTests`"
    static let updating = ProcessInfo.processInfo.environment["TRON_UPDATE_LOCKS"] == "1"
    static let goldens = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Goldens")
    static let results = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Locks
        .deletingLastPathComponent() // UITests
        .deletingLastPathComponent() // ios-app
        .deletingLastPathComponent() // packages
        .deletingLastPathComponent() // repository root
        .appending(path: "test-results/ui-locks")
}

extension XCTestCase {
    /// Locks the app's current state as `name`: waits until its accessibility
    /// hierarchy and pixels stop changing, then compares or records both goldens.
    @MainActor
    func assertUILock(_ app: XCUIApplication, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let tree = settledTree(app, name, file: file, line: line),
              let shot = settledScreenshot(name, file: file, line: line) else { return }
        checkTree(tree, name, file: file, line: line)
        checkScreenshot(shot, name, file: file, line: line)
    }

    // MARK: Settling

    @MainActor
    private func settledTree(_ app: XCUIApplication, _ name: String, file: StaticString, line: UInt) -> String? {
        var previous: String?
        let deadline = Date().addingTimeInterval(UILock.settleTimeout)
        repeat {
            let current: String
            do { current = try UILockTree.render(app.snapshot()) } catch {
                XCTFail("\(name): accessibility snapshot failed: \(error)", file: file, line: line)
                return nil
            }
            if current == previous { return current }
            if Date() > deadline {
                XCTFail("\(name): the accessibility hierarchy kept changing for \(Int(UILock.settleTimeout)) s:\n"
                        + UILockDiff.lines(previous ?? "", current), file: file, line: line)
                return nil
            }
            previous = current
            Thread.sleep(forTimeInterval: 0.3)
        } while true
    }

    @MainActor
    private func settledScreenshot(_ name: String, file: StaticString, line: UInt) -> UILockImage? {
        var previous: UILockImage?
        let deadline = Date().addingTimeInterval(UILock.settleTimeout)
        repeat {
            guard let current = UILockImage(screenshot: XCUIScreen.main.screenshot()) else {
                XCTFail("\(name): the screenshot could not be decoded", file: file, line: line)
                return nil
            }
            if let previous, current.differingPixels(from: previous).count == 0 { return current }
            if Date() > deadline {
                let count = previous.map { current.differingPixels(from: $0).count } ?? -1
                XCTFail("\(name): the screen kept changing for \(Int(UILock.settleTimeout)) s (\(count) pixels between the last two frames)",
                        file: file, line: line)
                return nil
            }
            previous = current
            Thread.sleep(forTimeInterval: 0.3)
        } while true
    }

    // MARK: Comparison

    /// Every run leaves its captures under `test-results/ui-locks/`, so two runs
    /// can be compared byte for byte and a failure has its actual beside the golden.
    private func checkTree(_ tree: String, _ name: String, file: StaticString, line: UInt) {
        let golden = UILock.goldens.appending(path: "\(name).a11y.txt")
        let actual = UILock.results.appending(path: "\(name).a11y.txt")
        write(Data(tree.utf8), to: actual, name, file: file, line: line)
        if UILock.updating { return write(Data(tree.utf8), to: golden, name, file: file, line: line) }
        guard let expected = try? String(contentsOf: golden, encoding: .utf8) else {
            return XCTFail("\(name): no accessibility golden at \(golden.path); \(UILock.recordHint)", file: file, line: line)
        }
        guard expected != tree else { return }
        attach(Data(tree.utf8), "\(name).a11y.txt", "public.plain-text")
        XCTFail("\(name): the accessibility hierarchy changed (- golden, + actual). Full diff: "
                + "git diff --no-index \(golden.path) \(actual.path)\n" + UILockDiff.lines(expected, tree),
                file: file, line: line)
    }

    private func checkScreenshot(_ shot: UILockImage, _ name: String, file: StaticString, line: UInt) {
        let golden = UILock.goldens.appending(path: "\(name).png")
        let actual = UILock.results.appending(path: "\(name).png")
        let diffURL = UILock.results.appending(path: "\(name).diff.png")
        try? FileManager.default.removeItem(at: diffURL)
        guard let png = shot.png() else { return XCTFail("\(name): the screenshot could not be encoded", file: file, line: line) }
        write(png, to: actual, name, file: file, line: line)
        if UILock.updating { return write(png, to: golden, name, file: file, line: line) }
        guard let data = try? Data(contentsOf: golden), let expected = UILockImage(png: data) else {
            return XCTFail("\(name): no screenshot golden at \(golden.path); PNG goldens are local baselines "
                           + "(not committed): \(UILock.recordHint)", file: file, line: line)
        }
        guard expected.width == shot.width, expected.height == shot.height else {
            return XCTFail("\(name): screenshot is \(shot.width)×\(shot.height) px but the golden is \(expected.width)×\(expected.height) px; "
                           + "locks are pinned to the simulator in config/ci-toolchain.env", file: file, line: line)
        }
        let differing = shot.differingPixels(from: expected)
        guard differing.count > UILock.maxDifferingPixels else { return }
        if let diff = expected.highlighting(differing) { write(diff, to: diffURL, name, file: file, line: line) }
        attach(png, "\(name).png", "public.png")
        XCTFail("\(name): \(differing.count) pixels differ by more than \(UILock.channelTolerance)/255 "
                + "(allowed \(UILock.maxDifferingPixels)) in \(differing.bounds) px; golden \(golden.path), "
                + "actual \(actual.path), diff (differences in red) \(diffURL.path)", file: file, line: line)
    }

    private func write(_ data: Data, to url: URL, _ name: String, file: StaticString, line: UInt) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            XCTFail("\(name): could not write \(url.path): \(error)", file: file, line: line)
        }
    }

    private func attach(_ data: Data, _ name: String, _ type: String) {
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: type)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// The normalized accessibility text. Structural `other` containers with no
/// identifier, label, value or traits are elided and their children hoisted:
/// they are SwiftUI hosting detail, not what VoiceOver or a test can address.
enum UILockTree {
    static func render(_ root: XCUIElementSnapshot) -> String {
        var lines: [String] = []
        visit(root, depth: 0, into: &lines)
        return lines.joined(separator: "\n") + "\n"
    }

    private static func visit(_ node: XCUIElementSnapshot, depth: Int, into lines: inout [String]) {
        // Hosted fixtures publish `fixture.*` probes (request counters, routes)
        // for behavioral journeys; they are test instrumentation, not UI.
        if node.identifier.hasPrefix("fixture.") { return }
        let traits = traitNames(node)
        let value = node.value.map { "\($0)" } ?? ""
        let elided = node.elementType == .other && node.identifier.isEmpty && node.label.isEmpty
            && value.isEmpty && traits.isEmpty
        if !elided {
            var parts = [typeName(node.elementType)]
            if !node.identifier.isEmpty { parts.append("id=\(quoted(node.identifier))") }
            if !node.label.isEmpty { parts.append("label=\(quoted(node.label))") }
            if !value.isEmpty { parts.append("value=\(quoted(value))") }
            if let placeholder = node.placeholderValue, !placeholder.isEmpty { parts.append("placeholder=\(quoted(placeholder))") }
            if !traits.isEmpty { parts.append("traits=\(traits.joined(separator: ","))") }
            if !node.isEnabled { parts.append("disabled") }
            if node.hasFocus { parts.append("focused") }
            let f = node.frame
            parts.append("(\(Int(f.minX.rounded())),\(Int(f.minY.rounded())) \(Int(f.width.rounded()))×\(Int(f.height.rounded())))")
            lines.append(String(repeating: "  ", count: depth) + parts.joined(separator: " "))
        }
        for child in node.children { visit(child, depth: elided ? depth : depth + 1, into: &lines) }
    }

    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    /// XCTest exposes UIAccessibility traits only on its snapshot object; the
    /// selected and enabled states are traits too, so this is the one source.
    private static func traitNames(_ node: XCUIElementSnapshot) -> [String] {
        guard let object = node as? NSObject, object.responds(to: NSSelectorFromString("traits")),
              let raw = (object.value(forKey: "traits") as? NSNumber)?.uint64Value else { return [] }
        // Bit 33 is set on every element XCTest reports: carrying it says nothing.
        var remaining = raw & ~(UInt64(1) << 33)
        var names: [String] = []
        for (trait, name) in knownTraits where remaining & trait.rawValue != 0 {
            names.append(name)
            remaining &= ~trait.rawValue
        }
        if remaining != 0 { names.append(String(format: "0x%llx", remaining)) }
        return names
    }

    private static let knownTraits: [(UIAccessibilityTraits, String)] = [
        (.button, "button"), (.link, "link"), (.header, "header"), (.searchField, "searchField"),
        (.image, "image"), (.selected, "selected"), (.playsSound, "playsSound"), (.keyboardKey, "keyboardKey"),
        (.staticText, "staticText"), (.summaryElement, "summaryElement"), (.notEnabled, "notEnabled"),
        (.updatesFrequently, "updatesFrequently"), (.startsMediaSession, "startsMediaSession"),
        (.adjustable, "adjustable"), (.allowsDirectInteraction, "allowsDirectInteraction"),
        (.causesPageTurn, "causesPageTurn"), (.tabBar, "tabBar"), (.toggleButton, "toggleButton"),
        (.supportsZoom, "supportsZoom"),
    ]

    /// `XCUIElement.ElementType` raw values in declaration order.
    private static func typeName(_ type: XCUIElement.ElementType) -> String {
        let names = ["any", "other", "application", "group", "window", "sheet", "drawer", "alert", "dialog", "button",
                     "radioButton", "radioGroup", "checkBox", "disclosureTriangle", "popUpButton", "comboBox", "menuButton",
                     "toolbarButton", "popover", "keyboard", "key", "navigationBar", "tabBar", "tabGroup", "toolbar",
                     "statusBar", "table", "tableRow", "tableColumn", "outline", "outlineRow", "browser", "collectionView",
                     "slider", "pageIndicator", "progressIndicator", "activityIndicator", "segmentedControl", "picker",
                     "pickerWheel", "switch", "toggle", "link", "image", "icon", "searchField", "scrollView", "scrollBar",
                     "staticText", "textField", "secureTextField", "datePicker", "textView", "menu", "menuItem", "menuBar",
                     "menuBarItem", "map", "webView", "incrementArrow", "decrementArrow", "timeline", "ratingIndicator",
                     "valueIndicator", "splitGroup", "splitter", "relevanceIndicator", "colorWell", "helpTag", "matte",
                     "dockItem", "ruler", "rulerMarker", "grid", "levelIndicator", "cell", "layoutArea", "layoutItem",
                     "handle", "stepper", "tab", "touchBar", "statusItem"]
        let raw = Int(type.rawValue)
        return names.indices.contains(raw) ? names[raw] : "type\(raw)"
    }
}

/// A line diff for failure messages: changed lines with two lines of context.
enum UILockDiff {
    static func lines(_ old: String, _ new: String, limit: Int = 80) -> String {
        let a = old.split(separator: "\n", omittingEmptySubsequences: false)
        let b = new.split(separator: "\n", omittingEmptySubsequences: false)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in b.difference(from: a) {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }
        // Merge both sides into one ordered edit script.
        var ops: [String] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) { ops.append("- \(a[i])"); i += 1 }
            else if j < b.count, inserted.contains(j) { ops.append("+ \(b[j])"); j += 1 }
            else { ops.append("  \(a[i])"); i += 1; j += 1 }
        }
        let changed = ops.indices.filter { !ops[$0].hasPrefix("  ") }
        var out: [String] = []
        var last = -1
        for k in ops.indices where changed.contains(where: { abs($0 - k) <= 2 }) {
            if last >= 0, k > last + 1 { out.append("  …") }
            out.append(ops[k]); last = k
        }
        if out.count > limit { return out.prefix(limit).joined(separator: "\n") + "\n  … \(out.count - limit) more lines" }
        return out.joined(separator: "\n")
    }
}
