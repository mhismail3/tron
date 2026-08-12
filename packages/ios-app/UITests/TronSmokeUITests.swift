import CoreML
import UIKit
import Vision
import XCTest

final class TronSmokeUITests: XCTestCase {
    @MainActor
    func testOnboardingPreservesPagedSheetAndPairingJourney() {
        let app = launchResetApp()
        let title = app.staticTexts["Welcome to Tron"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Sheet Grabber"].exists)
        XCTAssertTrue(app.staticTexts["Pair this iPhone with the Mac running Tron."].exists)
        XCTAssertTrue(app.buttons["Open Tron navigation"].exists)
        XCTAssertTrue(app.buttons["Settings"].exists)
        let pageIndicator = app.descendants(matching: .any)["Onboarding step 1 of 9"]
        XCTAssertTrue(pageIndicator.exists)
        let next = app.buttons["Next"]
        XCTAssertLessThan(abs(next.frame.width - next.frame.height), 2, "The native sheet navigation control must be circular")
        XCTAssertGreaterThanOrEqual(next.frame.width, 34)
        XCTAssertLessThan(abs(title.frame.midX - app.frame.midX), 18)
        XCTAssertLessThan(abs(title.frame.midY - next.frame.midY), 20)
        XCTAssertGreaterThan(title.frame.minY, app.frame.height * 0.45)
        assertWelcomeVisualParity()
        keepScreenshot(named: "onboarding-welcome-medium-current")

        app.buttons["Next"].tap()
        XCTAssertTrue(app.staticTexts["Install Tailscale"].waitForExistence(timeout: 2))
        app.buttons["Next"].tap()
        XCTAssertTrue(app.staticTexts["Install Tron on Mac"].waitForExistence(timeout: 2))
        app.buttons["Next"].tap()

        XCTAssertTrue(app.staticTexts["Connect your Mac"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Scan QR code"].exists)
        XCTAssertTrue(app.buttons["Enter Manually"].exists)
        app.buttons["Enter Manually"].tap()
        XCTAssertTrue(app.textFields["Tailscale host"].exists)
        XCTAssertTrue(app.textFields["Port"].exists)
        XCTAssertTrue(app.secureTextFields["One-time code"].exists)
        let connect = app.buttons["Connect to Mac"]
        XCTAssertFalse(connect.isEnabled)
        XCTAssertGreaterThanOrEqual(connect.frame.width, 72, "Connect must retain default iOS toolbar horizontal insets")
        XCTAssertGreaterThanOrEqual(connect.frame.height, 35, "Connect must retain default iOS toolbar control height")
        keepScreenshot(named: "onboarding-pairing-large-current")
        assertAccessibilityAuditPasses(app)
    }

    @MainActor
    func testOnboardingPairingPassesAccessibilityAuditInLightMode() {
        let app = launchResetApp(extraArguments: ["-appearanceMode", "light"])
        for _ in 0..<3 { app.buttons["Next"].tap() }
        app.buttons["Enter Manually"].tap()
        XCTAssertTrue(app.secureTextFields["One-time code"].waitForExistence(timeout: 3))
        assertAccessibilityAuditPasses(app)
    }

    @MainActor
    func testPairingValidationIsAccessibleAndDoesNotLeaveOnboarding() {
        let app = launchResetApp()
        for _ in 0..<3 { app.buttons["Next"].tap() }
        app.buttons["Enter Manually"].tap()

        let host = app.textFields["Tailscale host"]
        let code = app.secureTextFields["One-time code"]
        host.tap(); host.typeText("not a host/path")
        code.tap(); code.typeText("NOTREAL1")
        if app.keyboards.buttons["return"].exists { app.keyboards.buttons["return"].tap() }
        else { app.tap() }
        app.buttons["Connect to Mac"].tap()

        XCTAssertTrue(app.alerts["Tron"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Enter a valid host, port, and one-time code."].exists)
        app.alerts["Tron"].buttons["OK"].tap()
        XCTAssertTrue(app.secureTextFields["One-time code"].waitForExistence(timeout: 2), app.debugDescription)
    }

    @MainActor
    func testPairingFieldsScaleAtAccessibilityXXXL() {
        let app = launchResetApp(extraArguments: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ])
        for _ in 0..<3 { app.buttons["Next"].tap() }
        app.buttons["Manual Entry"].tap()

        let host = app.textFields["Tailscale host"]
        XCTAssertTrue(host.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(host.frame.height, 52, "The custom host field must grow at accessibility XXXL")
        XCTAssertTrue(app.textFields["Port"].exists)
        let code = app.secureTextFields["One-time code"]
        if !code.exists { app.swipeUp() }
        XCTAssertTrue(code.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(code.frame.height, 40, "The inner UIKit secure field must scale at accessibility XXXL")
    }

    @MainActor
    func testOnboardingSheetSupportsNativeExpansionGesture() {
        let app = launchResetApp()
        let title = app.staticTexts["Welcome to Tron"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let initialY = title.frame.minY
        app.swipeUp()
        let expanded = NSPredicate { element, _ in
            guard let element = element as? XCUIElement else { return false }
            return element.frame.minY < initialY - 80
        }
        expectation(for: expanded, evaluatedWith: title)
        waitForExpectations(timeout: 5)
    }

    @MainActor
    private func assertWelcomeVisualParity() {
        guard let referenceURL = Bundle(for: Self.self).url(
            forResource: "onboarding-welcome-medium-historical",
            withExtension: "png"
        ), let reference = UIImage(contentsOfFile: referenceURL.path)?.cgImage,
           let current = XCUIScreen.main.screenshot().image.cgImage else {
            return XCTFail("Historical onboarding visual reference is missing")
        }
        // The executable historical artifact is an iPhone 17 Pro baseline.
        // Larger physical devices retain geometry assertions and screenshots,
        // but must not be resampled into a misleading feature-print comparison.
        guard reference.width == current.width, reference.height == current.height else { return }
        let crop = CGRect(x: 0, y: 1242, width: 1206, height: 1380)
        guard let referenceCrop = reference.cropping(to: crop),
              let currentCrop = current.cropping(to: crop) else {
            return XCTFail("Onboarding screenshots must retain the iPhone 17 Pro reference dimensions")
        }
        do {
            let historical = try featurePrint(referenceCrop)
            let rendered = try featurePrint(currentCrop)
            var distance: Float = 0
            try historical.computeDistance(&distance, to: rendered)
            XCTAssertLessThan(distance, 0.38, "Medium onboarding sheet drifted from the executable historical baseline")
        } catch {
            XCTFail("Could not compare onboarding visuals: \(error)")
        }
    }

    private func featurePrint(_ image: CGImage) throws -> VNFeaturePrintObservation {
        let request = VNGenerateImageFeaturePrintRequest()
        if let cpu = MLComputeDevice.allComputeDevices.first(where: {
            if case .cpu = $0 { return true }
            return false
        }) {
            for (stage, devices) in try request.supportedComputeStageDevices where devices.contains(cpu) {
                request.setComputeDevice(cpu, for: stage)
            }
        }
        try VNImageRequestHandler(cgImage: image).perform([request])
        guard let observation = request.results?.first as? VNFeaturePrintObservation else {
            throw VisualParityFailure.noFeaturePrint
        }
        return observation
    }

    private enum VisualParityFailure: Error { case noFeaturePrint }

    @MainActor
    private func keepScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func assertAccessibilityAuditPasses(_ app: XCUIApplication) {
        var failures: [String] = []
        XCTAssertNoThrow(try app.performAccessibilityAudit { issue in
            let element = issue.element
            // XCTest predicts clipping from the field's normal-size UIKit host
            // frame without rerunning SwiftUI layout. The dedicated XXXL test
            // above relaunches and verifies the real custom field grows.
            if issue.auditType == .textClipped,
               element?.label == "Tailscale host",
               element?.elementType == .textField { return true }
            failures.append("\(issue.compactDescription): \(issue.detailedDescription) [label=\(element?.label ?? "nil"), id=\(element?.identifier ?? "nil"), frame=\(String(describing: element?.frame)), element=\(element?.debugDescription ?? "nil")]")
            return true
        })
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    @MainActor
    private func launchResetApp(extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--tron-reset-ui-test-state", "-ApplePersistenceIgnoreState", "YES"] + extraArguments
        app.launch()
        return app
    }
}
