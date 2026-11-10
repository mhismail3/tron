import UIKit
import XCTest

enum UILock {
    static let settleTimeout: TimeInterval = 10
    static let results = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "test-results/ui-locks")
}

extension XCTestCase {
    @MainActor
    func assertUILock(_ app: XCUIApplication, _ name: String, accessibility expectedTree: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let tree = settledTree(app, name, file: file, line: line) else { return }
        checkTree(tree, expected: expectedTree, name, file: file, line: line)
    }

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

    private func checkTree(_ tree: String, expected: String, _ name: String, file: StaticString, line: UInt) {
        let actual = UILock.results.appending(path: "\(name).a11y.txt")
        write(Data(tree.utf8), to: actual, name, file: file, line: line)
        guard expected != tree else { return }
        attach(Data(tree.utf8), "\(name).a11y.txt", "public.plain-text")
        XCTFail("\(name): the accessibility hierarchy changed (- expected, + actual; actual at \(actual.path)):\n"
                + UILockDiff.lines(expected, tree), file: file, line: line)
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

enum UILockTree {
    static func render(_ root: XCUIElementSnapshot) -> String {
        var lines: [String] = []
        visit(root, depth: 0, into: &lines)
        return lines.joined(separator: "\n") + "\n"
    }

    private static func visit(_ node: XCUIElementSnapshot, depth: Int, into lines: inout [String]) {
        if node.identifier.hasPrefix("fixture.") { return }
        let traits = traitNames(node)
        let value = node.value.map { "\($0)" } ?? ""
        let elided = node.elementType == .other && node.identifier.isEmpty && node.label.isEmpty
            && value.isEmpty && traits.isEmpty && node.isEnabled && !node.hasFocus
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

    private static func traitNames(_ node: XCUIElementSnapshot) -> [String] {
        guard let object = node as? NSObject, object.responds(to: NSSelectorFromString("traits")),
              let raw = (object.value(forKey: "traits") as? NSNumber)?.uint64Value else { return [] }
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
