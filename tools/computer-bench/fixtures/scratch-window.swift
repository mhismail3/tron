import AppKit

final class Bench: NSObject, NSApplicationDelegate {
  let statePath: String
  let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 420, height: 260), styleMask: [.titled], backing: .buffered, defer: false)
  let name = NSTextField(string: "")
  let prefilled = NSTextField(string: "old value")
  let counter = NSTextField(labelWithString: "0")
  let flavor = NSPopUpButton(frame: .zero, pullsDown: false)
  var count = 0
  var approved = false

  init(statePath: String) { self.statePath = statePath }

  func applicationDidFinishLaunching(_ notification: Notification) {
    window.title = "Tron Bench Scratch"
    name.placeholderString = "Name"
    name.setAccessibilityLabel("Name")
    prefilled.setAccessibilityLabel("Prefilled")
    counter.setAccessibilityLabel("Count")
    flavor.addItems(withTitles: ["Vanilla", "Chocolate", "Strawberry"])
    flavor.setAccessibilityLabel("Flavor")
    let increment = NSButton(title: "Increment", target: self, action: #selector(incrementCount))
    let alert = NSButton(title: "Show Alert", target: self, action: #selector(showAlert))
    let stack = NSStackView(views: [name, prefilled, flavor, increment, counter, alert])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
    for field in [name, prefilled] { field.widthAnchor.constraint(equalToConstant: 360).isActive = true }
    window.contentView = stack
    window.orderFrontRegardless()
    Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.write() }
  }

  @objc func incrementCount() { count += 1; counter.stringValue = String(count) }

  @objc func showAlert() {
    let alert = NSAlert()
    alert.messageText = "Bench consent"
    alert.informativeText = "Allow the bench to continue?"
    alert.addButton(withTitle: "Approve")
    alert.addButton(withTitle: "Deny")
    alert.beginSheetModal(for: window) { [weak self] response in self?.approved = response == .alertFirstButtonReturn }
  }

  func write() {
    let state: [String: Any] = ["name": name.stringValue, "prefilled": prefilled.stringValue, "count": count,
                                "flavor": flavor.titleOfSelectedItem ?? "", "approved": approved, "alertOpen": window.attachedSheet != nil,
                                "active": NSApp.isActive]
    guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) else { return }
    try? data.write(to: URL(fileURLWithPath: statePath), options: .atomic)
  }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = Bench(statePath: CommandLine.arguments[1])
app.delegate = delegate
app.run()
