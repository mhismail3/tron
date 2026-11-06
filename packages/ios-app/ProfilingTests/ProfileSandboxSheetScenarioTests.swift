import QuartzCore
import SwiftUI
import UIKit
import XCTest
@testable import TronMobile

/// Settings → Sandbox's custom sheet for `scripts/tron-profile ios` (#2302):
/// the real `SandboxCustomSheetStage`, presenting its sheet through the stage's
/// own control and closing it through Done, repeatedly. The ledger records the
/// display frames the main thread missed while presenting and while dismissing,
/// and the worst frame interval. `sandbox-stock-sheet` drives the same content
/// in the stock sheet as the baseline.
@MainActor
final class ProfileSandboxSheetScenarioTests: XCTestCase {
    func testSandboxCustomSheet() throws {
        try profileScenario("sandbox-sheet", defaultWindow: .seconds(14)) { _ in
            try ProfileSandboxSheetRun(open: "Custom sheet", stock: false)
        }
    }

    func testSandboxStockSheet() throws {
        try profileScenario("sandbox-stock-sheet", defaultWindow: .seconds(14)) { _ in
            try ProfileSandboxSheetRun(open: "Stock sheet", stock: true)
        }
    }
}

@MainActor
final class ProfileSandboxSheetRun: ProfileScenarioRun {
    /// Long enough for the spring to settle and the meter to stay quiet.
    static let settle: Duration = .milliseconds(900)
    private let open: String
    private let stock: Bool
    private var window: UIWindow?
    private var host: UIHostingController<AnyView>?
    private var cycles = 0

    init(open: String, stock: Bool) throws {
        self.open = open
        self.stock = stock
        ProfileScenarioLedger.shared.reset()
        for name in ["sheet.presents", "sheet.present_missed_frames", "sheet.present_worst_ms",
                     "sheet.dismiss_missed_frames", "sheet.dismiss_worst_ms"] {
            ProfileScenarioLedger.shared.add(name, 0)
        }
        ProfileAccessibility.enableAutomation()
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw ProfileScenarioError.notReady("the hosted test app has no window scene")
        }
        let host = UIHostingController(rootView: AnyView(SandboxCustomSheetStage().tronPresentation()))
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        self.window = window
        self.host = host
    }

    func ready() async throws {
        guard let view = host?.view else { throw ProfileScenarioError.notReady("the stage is not mounted") }
        try await profileWaitUntil("the stage shows its sheet control") {
            ProfileAccessibility.element(in: view, labels: [self.open]) != nil
        }
        try await Task.sleep(for: .seconds(1))
    }

    func workload(window: Duration) async throws {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < window - .seconds(2) {
            try await cycle()
            cycles += 1
        }
        try await profileSleep(until: window, from: start)
    }

    private func cycle() async throws {
        guard let view = host?.view, let control = ProfileAccessibility.element(in: view, labels: [open]) else {
            throw ProfileScenarioError.workloadDiverged("the sheet control is not on screen")
        }
        let frames = ProfileSheetFrameClock()
        frames.start()
        defer { frames.stop() }
        guard control.accessibilityActivate() else { throw ProfileScenarioError.workloadDiverged("the control refused activation") }
        try await Task.sleep(for: Self.settle)
        guard let done = doneControl() else { throw ProfileScenarioError.workloadDiverged("the sheet has no Done control") }
        let presented = frames.take()
        ProfileScenarioLedger.shared.add("sheet.presents")
        ProfileScenarioLedger.shared.add("sheet.present_missed_frames", presented.missed)
        ProfileScenarioLedger.shared.add("sheet.present_worst_ms", presented.worstMilliseconds)
        guard done.accessibilityActivate() else { throw ProfileScenarioError.workloadDiverged("Done refused activation") }
        try await Task.sleep(for: Self.settle)
        let dismissed = frames.take()
        ProfileScenarioLedger.shared.add("sheet.dismiss_missed_frames", dismissed.missed)
        ProfileScenarioLedger.shared.add("sheet.dismiss_worst_ms", dismissed.worstMilliseconds)
        if doneControl() != nil { throw ProfileScenarioError.workloadDiverged("the sheet did not close") }
        try await Task.sleep(for: .milliseconds(200))
    }

    /// The sheet's Done: in the stage itself for the custom sheet, in the
    /// presented controller for the stock one.
    private func doneControl() -> NSObject? {
        let root = stock ? host?.presentedViewController?.view : host?.view
        return root.flatMap { ProfileAccessibility.element(in: $0, labels: ["Done"]) }
    }

    func renderCheck() -> ProfileRenderCheck {
        ProfileRenderCheck(counters: ["sheet_cycles": cycles], divergence: cycles >= 1 ? nil : "no sheet cycle completed")
    }

    var surface: UIView? { host?.view }

    func teardown() async {
        host?.dismiss(animated: false)
        window?.isHidden = true
        window = nil
        host = nil
    }
}

/// Display frames the main thread delivered late, and the worst interval, per
/// phase. A frame interval longer than 1.5 nominal frames counts the frames it skipped.
@MainActor
private final class ProfileSheetFrameClock: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval?
    private var missed = 0
    private var worst: CFTimeInterval = 0

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    func take() -> (missed: Int, worstMilliseconds: Int) {
        defer { missed = 0; worst = 0 }
        return (missed, Int((worst * 1_000).rounded()))
    }

    @objc private func tick(_ link: CADisplayLink) {
        let nominal = max(link.targetTimestamp - link.timestamp, 1.0 / 120)
        if let last {
            let interval = link.timestamp - last
            worst = max(worst, interval)
            if interval > nominal * 1.5 { missed += Int((interval / nominal).rounded()) - 1 }
        }
        last = link.timestamp
    }
}
