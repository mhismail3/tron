import XCTest
@testable import TronMobile

/// Source-level guards for app-wide iPad sheet sizing.
///
/// iPad floating sheets should use one canonical sizing helper, while call
/// sites that previously used raw iPhone detents must preserve their non-iPad
/// sizing and background behavior.
final class IPadSheetPresentationTests: XCTestCase {

    func testStandardPhoneSheetsKeepDarkMediumContentReadable() {
        XCTAssertEqual(
            AdaptivePhonePresentationPolicy.automaticBackgroundOpacity(
                isDark: true,
                isLargeDetent: false
            ),
            0.62
        )
        XCTAssertEqual(
            AdaptivePhonePresentationPolicy.automaticBackgroundOpacity(
                isDark: false,
                isLargeDetent: false
            ),
            0
        )
        XCTAssertEqual(
            AdaptivePhonePresentationPolicy.automaticBackgroundOpacity(
                isDark: true,
                isLargeDetent: true
            ),
            1
        )
        XCTAssertEqual(
            AdaptivePhonePresentationPolicy.automaticBackgroundOpacity(
                isDark: false,
                isLargeDetent: true
            ),
            1
        )
    }

    func testAdaptivePresentationHelperCentralizesIPadSizingAndPhonePreservation() throws {
        let content = try source(pathComponents: ["Sources", "Support", "Foundation", "SwiftUI", "View+Extensions.swift"])

        XCTAssertTrue(
            content.contains("func targetSize(referenceWidth: CGFloat, referenceHeight: CGFloat, intrinsicSize: CGSize? = nil) -> CGSize"),
            "iPad sheet dimensions should be owned by AdaptivePresentationSizing rather than repeated per view"
        )
        XCTAssertTrue(
            content.contains("private static func clampedHeight"),
            "Short iPad detail sheets should shrink to content within canonical min/max bounds instead of forcing empty fixed height"
        )
        XCTAssertTrue(
            content.contains("selection: Binding<PresentationDetent>? = nil"),
            "The helper must support callers such as onboarding that already own the selected iPhone detent"
        )
        XCTAssertTrue(
            content.contains("enum AdaptivePhonePresentationSizing"),
            "Newly converted raw-detent sheets need a way to keep their existing non-iPad sizing"
        )
        XCTAssertTrue(
            content.contains("enum AdaptivePhonePresentationBackground"),
            "Newly converted raw-detent sheets need a way to keep their existing non-iPad background behavior"
        )
        XCTAssertTrue(
            content.contains("phoneSizing: AdaptivePhonePresentationSizing = .largeForm"),
            "Existing adaptive callers should keep their established iPhone large-form branch by default"
        )
        XCTAssertTrue(
            content.contains("phoneBackground: AdaptivePhonePresentationBackground = .automaticLargeDetent"),
            "Existing adaptive callers should keep their established iPhone background branch by default"
        )
        XCTAssertTrue(
            content.contains("phoneSelectedDetent == .large"),
            "Detented iPhone sheets should use their opaque app surface whenever they reach the large detent"
        )
        XCTAssertTrue(
            content.contains("AdaptivePhonePresentationPolicy.automaticBackgroundOpacity"),
            "Standard phone sheets should share one dark-medium readability policy"
        )
        XCTAssertFalse(
            content.contains("phoneSelectedDetent == .large && colorScheme == .light"),
            "Large detent opacity must not disappear in dark mode"
        )
        XCTAssertTrue(
            content.contains("enum AdaptiveIPadPresentationBackground"),
            "The helper needs an iPad background policy so full-bleed sheets can opt out of material backing"
        )
        XCTAssertTrue(
            content.contains("ipadBackground: AdaptiveIPadPresentationBackground = .material"),
            "Existing adaptive callers should keep the established iPad material background by default"
        )
        XCTAssertTrue(
            content.contains("case .unchanged"),
            "The helper needs an unchanged phone branch for app sheets converted from raw detents"
        )
        XCTAssertTrue(
            content.contains("func glassPopoverPresentationBackground() -> some View"),
            "Glass popover background styling should live beside the canonical sheet presentation helpers"
        )
        XCTAssertTrue(
            content.contains("func popoverCompactAdaptation() -> some View"),
            "Compact-width popover adaptation should live beside the canonical presentation helpers"
        )
        XCTAssertTrue(
            content.contains("func compactHeightSheetPresentation("),
            "Short custom-height sheets should have a canonical helper instead of repeating height detent policy"
        )
        XCTAssertTrue(
            content.contains("func immersiveCameraSheetPresentation<Background: View>"),
            "Full-bleed camera sheets should have a canonical presentation-background helper"
        )
        XCTAssertTrue(
            content.contains("ipadFillsHeight: Bool = false"),
            "Immersive sheets need an opt-in path to fill the canonical iPad form height without changing compact custom-height sheets"
        )
        XCTAssertTrue(
            content.contains(".frame(height: targetSize.height)"),
            "The iPad fill-height branch should force content to occupy the full floating container"
        )
        XCTAssertTrue(
            content.contains("[.height(height)]"),
            "The compact height helper should own custom-height detent construction"
        )
        XCTAssertTrue(
            content.contains(".presentationBackground(alignment: .center)"),
            "The immersive camera helper should fill the whole modal presentation background, including sheet safe-area reservations"
        )
        XCTAssertTrue(
            content.contains("dragIndicator: Visibility = .hidden"),
            "The adaptive presentation helper should own the app sheet drag-indicator policy"
        )
        XCTAssertTrue(
            content.contains(".presentationDragIndicator(dragIndicator)"),
            "The adaptive presentation helper should apply the centralized drag-indicator policy"
        )
    }

    func testRepresentativeAppSheetsUseCanonicalIPadSizing() throws {
        let expected: [(path: [String], fragment: String)] = [
            (
                ["Sources", "App", "Lifecycle", "ProductionAppRoot.swift"],
                ".adaptivePresentationDetents(OnboardingSheetPresentation.detents, selection: $onboardingDetent, ipadSizing: .compactForm, phoneBackground: .clear)"
            ),
            (
                ["Sources", "UI", "Chat", "Composer", "CameraCaptureSheet.swift"],
                ".immersiveCameraSheetPresentation"
            ),
            (
                ["Sources", "UI", "Onboarding", "QRCodeScannerSheet.swift"],
                ".adaptivePresentationDetents([.medium], ipadSizing: .compactForm, phoneSizing: .unchanged, phoneBackground: .unchanged)"
            ),
            (
                ["Sources", "UI", "System", "CompactionDetailSheet.swift"],
                ".adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)"
            ),
            (
                ["Sources", "UI", "System", "ProviderErrorDetailSheet.swift"],
                ".adaptivePresentationDetents([.medium], ipadSizing: .compactForm)"
            ),
            (
                ["Sources", "UI", "Chat", "Sheets", "LocalErrorDetailSheet.swift"],
                ".adaptivePresentationDetents([.medium], ipadSizing: .compactForm)"
            )
        ]

        for entry in expected {
            let content = try source(pathComponents: entry.path)
            XCTAssertTrue(
                content.contains(entry.fragment),
                "\(entry.path.joined(separator: "/")) should use canonical adaptive iPad sheet sizing"
            )
        }
    }

    func testReusableSheetViewsOwnCanonicalIPadSizing() throws {
        let expected: [(path: [String], anchor: String, fragment: String)] = [
            (
                ["Sources", "UI", "System", "LogViewer.swift"],
                "struct LogViewer: View",
                ".adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)"
            )
        ]

        for entry in expected {
            let content = try source(pathComponents: entry.path)
            let anchorRange = try XCTUnwrap(
                content.range(of: entry.anchor),
                "\(entry.path.joined(separator: "/")) is missing \(entry.anchor)"
            )
            let scopedContent = String(content[anchorRange.lowerBound...])
            XCTAssertTrue(
                scopedContent.contains(entry.fragment),
                "\(entry.anchor) should own canonical adaptive iPad sheet sizing"
            )
        }
    }

    func testSettingsDoesNotWrapLogViewerWithDuplicateSizing() throws {
        let content = try source(pathComponents: ["Sources", "UI", "Settings", "Shell", "SettingsView.swift"])
        let sheetRange = try XCTUnwrap(
            content.range(of: ".sheet(isPresented: $showLogViewer)"),
            "SettingsView should still present LogViewer through its logs sheet"
        )
        let nextSheetRange = try XCTUnwrap(
            content.range(of: ".sheet(item: $activePage", range: sheetRange.upperBound..<content.endIndex),
            "SettingsView should still present settings pages after LogViewer"
        )
        let logViewerSheetBlock = String(content[sheetRange.lowerBound..<nextSheetRange.lowerBound])

        XCTAssertFalse(
            logViewerSheetBlock.contains(".adaptivePresentationDetents("),
            "LogViewer should own canonical sizing instead of being wrapped by SettingsView"
        )
    }

    func testEveryAdaptivePresentationCallSiteDeclaresIPadSizingPreset() throws {
        let sourceRoot = try projectRoot()
            .appendingPathComponent("Sources")
        let files = try swiftFiles(under: sourceRoot)
        let offenders = try files.flatMap { file -> [String] in
            guard file.lastPathComponent != "View+Extensions.swift" else { return [] }
            let content = try String(contentsOf: file, encoding: .utf8)
            return adaptivePresentationCalls(in: content).compactMap { call in
                call.text.contains("ipadSizing:")
                    ? nil
                    : "\(relativePath(file, under: sourceRoot)):\(call.line)"
            }
        }

        XCTAssertTrue(
            offenders.isEmpty,
            "Every adaptive iPad sheet should declare its size preset explicitly: \(offenders.joined(separator: ", "))"
        )
    }

    func testNoRawPresentationDetentsOutsideAdaptiveHelper() throws {
        let sourceRoot = try projectRoot()
            .appendingPathComponent("Sources")
        let files = try swiftFiles(under: sourceRoot)
        let offenders = try files.compactMap { file -> String? in
            guard file.lastPathComponent != "View+Extensions.swift" else { return nil }
            let content = try String(contentsOf: file, encoding: .utf8)
            return content.contains(".presentationDetents(")
                ? file.path.replacingOccurrences(of: sourceRoot.path + "/", with: "")
                : nil
        }

        XCTAssertTrue(
            offenders.isEmpty,
            "Raw presentationDetents bypass the iPad sizing helper: \(offenders.joined(separator: ", "))"
        )
    }

    func testWorkerConsoleSheetsAlwaysOfferMediumFirst() throws {
        let sourceRoot = try projectRoot()
            .appendingPathComponent("Sources/UI/WorkerConsole")
        let files = try swiftFiles(under: sourceRoot)
        let offenders = try files.flatMap { file -> [String] in
            let content = try String(contentsOf: file, encoding: .utf8)
            return adaptivePresentationCalls(in: content).compactMap { call in
                call.text.contains("[.medium, .large]")
                    ? nil
                    : "\(relativePath(file, under: sourceRoot)):\(call.line)"
            }
        }

        XCTAssertTrue(
            offenders.isEmpty,
            "Worker sheets must open at medium and remain expandable: \(offenders.joined(separator: ", "))"
        )
    }

    func testPresentationBackgroundStylingStaysCentralized() throws {
        let sourceRoot = try projectRoot()
            .appendingPathComponent("Sources")
        let files = try swiftFiles(under: sourceRoot)
        let offenders = try files.compactMap { file -> String? in
            guard file.lastPathComponent != "View+Extensions.swift" else { return nil }
            let content = try String(contentsOf: file, encoding: .utf8)
            return content.contains(".presentationBackground(")
                ? relativePath(file, under: sourceRoot)
                : nil
        }

        XCTAssertTrue(
            offenders.isEmpty,
            "Raw presentationBackground styling bypasses canonical sheet/popover helpers: \(offenders.joined(separator: ", "))"
        )
    }

    func testPresentationDragIndicatorStylingStaysCentralized() throws {
        let sourceRoot = try projectRoot()
            .appendingPathComponent("Sources")
        let files = try swiftFiles(under: sourceRoot)
        let offenders = try files.compactMap { file -> String? in
            guard file.lastPathComponent != "View+Extensions.swift" else { return nil }
            let content = try String(contentsOf: file, encoding: .utf8)
            return content.contains(".presentationDragIndicator(")
                ? relativePath(file, under: sourceRoot)
                : nil
        }

        XCTAssertTrue(
            offenders.isEmpty,
            "Raw presentationDragIndicator styling bypasses the adaptive sheet helper: \(offenders.joined(separator: ", "))"
        )
    }

    func testNoSheetOptsIntoVisibleDragIndicator() throws {
        let sourceRoot = try projectRoot()
            .appendingPathComponent("Sources")
        let files = try swiftFiles(under: sourceRoot)
        let offenders = try files.compactMap { file -> String? in
            let content = try String(contentsOf: file, encoding: .utf8)
            return content.contains("dragIndicator: .visible")
                ? relativePath(file, under: sourceRoot)
                : nil
        }

        XCTAssertTrue(
            offenders.isEmpty,
            "Sheets should not opt into visible drag handles: \(offenders.joined(separator: ", "))"
        )
    }

    func testCompactPopoverAdaptationStaysCentralized() throws {
        let sourceRoot = try projectRoot()
            .appendingPathComponent("Sources")
        let files = try swiftFiles(under: sourceRoot)
        let offenders = try files.compactMap { file -> String? in
            guard file.lastPathComponent != "View+Extensions.swift" else { return nil }
            let content = try String(contentsOf: file, encoding: .utf8)
            return content.contains(".presentationCompactAdaptation(")
                ? relativePath(file, under: sourceRoot)
                : nil
        }

        XCTAssertTrue(
            offenders.isEmpty,
            "Raw presentationCompactAdaptation styling bypasses the canonical popover helper: \(offenders.joined(separator: ", "))"
        )
    }

    private func swiftFiles(under root: URL) throws -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return enumerator?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
    }

    private func adaptivePresentationCalls(in content: String) -> [(line: Int, text: String)] {
        var calls: [(line: Int, text: String)] = []
        var searchRange = content.startIndex..<content.endIndex
        while let callStart = content.range(of: ".adaptivePresentationDetents(", range: searchRange) {
            var depth = 0
            var cursor = callStart.lowerBound
            var callEnd = callStart.upperBound
            while cursor < content.endIndex {
                let character = content[cursor]
                if character == "(" {
                    depth += 1
                } else if character == ")" {
                    depth -= 1
                    if depth == 0 {
                        callEnd = content.index(after: cursor)
                        break
                    }
                }
                cursor = content.index(after: cursor)
            }
            let line = content[..<callStart.lowerBound].filter { $0 == "\n" }.count + 1
            calls.append((line: line, text: String(content[callStart.lowerBound..<callEnd])))
            searchRange = callEnd..<content.endIndex
        }
        return calls
    }

    private func relativePath(_ file: URL, under root: URL) -> String {
        file.path.replacingOccurrences(of: root.path + "/", with: "")
    }

    private func source(pathComponents: [String]) throws -> String {
        var url = try projectRoot()
        for component in pathComponents {
            url.appendPathComponent(component)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func projectRoot() throws -> URL {
        let fileURL = URL(fileURLWithPath: #filePath)
        return fileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
