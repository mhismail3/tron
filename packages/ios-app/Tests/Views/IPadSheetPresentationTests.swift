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
                ["Sources", "Views", "Session", "CloneRepoSheet.swift"],
                ".adaptivePresentationDetents([.medium], ipadSizing: .compactForm, phoneSizing: .unchanged, phoneBackground: .unchanged)"
            ),
            (
                ["Sources", "Views", "Capabilities", "Display", "StreamSheetView.swift"],
                ".adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm, phoneSizing: .unchanged, phoneBackground: .unchanged)"
            ),
            (
                ["Sources", "Views", "Subagents", "SubagentDetailSheet.swift"],
                ".adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)"
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
                ["Sources", "Views", "EngineApproval", "EngineApprovalSheet.swift"],
                ".adaptivePresentationDetents([.medium, .large], ipadSizing: .compactForm)"
            ),
            (
                ["Sources", "Views", "UserInteraction", "UserInteractionSheet.swift"],
                ".adaptivePresentationDetents([.medium, .large], ipadSizing: .compactForm)"
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
