import XCTest

/// Source-level guards for app-wide iPad sheet sizing.
///
/// iPad floating sheets should use one canonical sizing helper, while call
/// sites that previously used raw iPhone detents must preserve their non-iPad
/// sizing and background behavior.
final class IPadSheetPresentationTests: XCTestCase {

    func testAdaptivePresentationHelperCentralizesIPadSizingAndPhonePreservation() throws {
        let content = try source(pathComponents: ["Sources", "Extensions", "View+Extensions.swift"])

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
                ["Sources", "App", "TronMobileApp.swift"],
                ".adaptivePresentationDetents([.medium, .large], selection: $onboardingDetent, ipadSizing: .largeForm, phoneBackground: .clear)"
            ),
            (
                ["Sources", "Views", "Attachments", "CameraCaptureSheet.swift"],
                ".adaptivePresentationDetents([.medium], ipadSizing: .compactForm, phoneSizing: .unchanged, phoneBackground: .unchanged)"
            ),
            (
                ["Sources", "Views", "Onboarding", "QRCodeScannerSheet.swift"],
                ".adaptivePresentationDetents([.medium], ipadSizing: .compactForm, phoneSizing: .unchanged, phoneBackground: .unchanged)"
            ),
            (
                ["Sources", "Views", "Capabilities", "Display", "StreamSheetView.swift"],
                ".adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm, phoneSizing: .unchanged, phoneBackground: .unchanged)"
            ),
            (
                ["Sources", "Views", "System", "CompactionDetailSheet.swift"],
                ".adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)"
            ),
            (
                ["Sources", "Views", "System", "MemoryRetainDetailSheet.swift"],
                ".adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)"
            ),
            (
                ["Sources", "Views", "System", "ProviderErrorDetailSheet.swift"],
                ".adaptivePresentationDetents([.medium], ipadSizing: .compactForm)"
            ),
            (
                ["Sources", "Views", "UserInteraction", "UserInteractionSheet.swift"],
                ".adaptivePresentationDetents([.medium, .large], ipadSizing: .compactForm)"
            ),
            (
                ["Sources", "Views", "Process", "ProcessListSheet.swift"],
                ".adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm, phoneSizing: .unchanged, phoneBackground: .unchanged)"
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
                ["Sources", "Views", "Process", "ProcessListSheet.swift"],
                "struct ProcessListSheet: View",
                ".adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm, phoneSizing: .unchanged, phoneBackground: .unchanged)"
            ),
            (
                ["Sources", "Views", "Settings", "Pages", "PluginSourcesPage.swift"],
                "private struct AddPluginSourceSheet: View",
                ".adaptivePresentationDetents([.medium], ipadSizing: .largeForm)"
            ),
            (
                ["Sources", "Views", "System", "LogViewer.swift"],
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
        let content = try source(pathComponents: ["Sources", "Views", "Settings", "SettingsView.swift"])
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
    }
}
