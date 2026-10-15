import XCTest

/// A sheet's toolbar icons are drawn in its title's tint (#963): `TronSheetTitle`
/// and `tronToolbarAction` resolve through one rule, `TronSheetTint`. This reads
/// the rendered pixels, so any sheet that paints its own toolbar colour fails.
extension XCTestCase {
    /// Every enabled, hittable button in the navigation bar that shows `title`
    /// must be inked within tolerance of the title. Disabled actions are grey by
    /// design; `excluding` names destructive actions, which stay red.
    @MainActor
    func assertToolbarTint(_ app: XCUIApplication, title: String, excluding: Set<String> = [],
                           file: StaticString = #filePath, line: UInt = #line) {
        let titleText = app.navigationBars.staticTexts[title].firstMatch
        XCTAssertTrue(titleText.waitForExistence(timeout: 5), "No sheet titled \(title): \(app.debugDescription)", file: file, line: line)
        // Let the presentation settle so the screenshot shows final colours.
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: titleText)], timeout: 3)
        let bar = app.navigationBars.containing(.staticText, identifier: title).allElementsBoundByIndex
            .last { $0.frame.contains(CGPoint(x: titleText.frame.midX, y: titleText.frame.midY)) }
        let actions = (bar?.buttons.allElementsBoundByIndex ?? [])
            .filter { $0.isHittable && $0.isEnabled && !excluding.contains($0.label) && $0.frame.width > 0 }
        XCTAssertFalse(actions.isEmpty, "\(title) has no enabled toolbar action", file: file, line: line)
        let screenshot = XCUIScreen.main.screenshot().image
        let window = app.windows.firstMatch.frame.width
        guard let tint = sheetInk(screenshot, titleText.frame, window: window) else {
            XCTFail("No inked pixels in \(title)'s title", file: file, line: line); return
        }
        for action in actions {
            guard let ink = sheetInk(screenshot, action.frame, window: window) else {
                XCTFail("\(title): no inked pixels in toolbar action '\(action.label)'", file: file, line: line); continue
            }
            let distance = zip(ink, tint).map { abs($0 - $1) }.max() ?? 1
            XCTAssertLessThan(distance, 0.12,
                              "\(title): toolbar action '\(action.label)' \(ink) is not the title's tint \(tint)",
                              file: file, line: line)
        }
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "sheet-tint-\(title)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The average colour of the saturated (inked) pixels in `area`: glyphs, never
    /// the neutral glass or sheet material behind them.
    private func sheetInk(_ image: UIImage, _ area: CGRect, window: CGFloat) -> [Double]? {
        guard let source = image.cgImage else { return nil }
        let scale = CGFloat(source.width) / window
        guard let crop = source.cropping(to: area.applying(CGAffineTransform(scaleX: scale, y: scale))) else { return nil }
        let width = crop.width, height = crop.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        var sum = [0.0, 0.0, 0.0], count = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let rgb = [Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2])]
            guard rgb.max()! - rgb.min()! > 60 else { continue }
            for c in 0..<3 { sum[c] += Double(rgb[c]) / 255 }
            count += 1
        }
        return count > 10 ? sum.map { $0 / count } : nil
    }
}
