import Foundation
import Testing
@testable import TronMac

/// Pins the canonical step ordering so a silent reorder triggers a
/// failing test instead of a confused user.
@Suite("WizardStep ordering")
struct WizardStepOrderingTests {
    @Test("allCases is in canonical order (install precedes permissions)")
    func canonicalOrder() {
        // Install runs BEFORE permissions on purpose: macOS TCC grants
        // are tied to the process running when the user granted them,
        // so we need the agent to exist on disk and be running under
        // launchd before asking the user to grant permissions to it.
        // The permissions step then `launchctl kickstart -k`s the
        // agent after each grant so the new extension takes effect
        // without a visible restart prompt. Swapping these two steps
        // back would silently break the seamless-grant flow.
        #expect(WizardStep.allCases == [
            .welcome,
            .tailscale,
            .existingInstall,
            .install,
            .permissions,
            .pairingInfo,
            .done,
        ])
    }

    @Test("rawValues are stable strings (used as UserDefaults keys)")
    func rawValuesStable() {
        #expect(WizardStep.welcome.rawValue == "welcome")
        #expect(WizardStep.tailscale.rawValue == "tailscale")
        #expect(WizardStep.existingInstall.rawValue == "existingInstall")
        #expect(WizardStep.permissions.rawValue == "permissions")
        #expect(WizardStep.install.rawValue == "install")
        #expect(WizardStep.pairingInfo.rawValue == "pairingInfo")
        #expect(WizardStep.done.rawValue == "done")
    }

    @Test("WizardStep round-trips through Codable")
    func codableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for step in WizardStep.allCases {
            let data = try encoder.encode(step)
            let decoded = try decoder.decode(WizardStep.self, from: data)
            #expect(decoded == step)
        }
    }
}

@Suite("InstallPipelineStage ordering")
struct InstallPipelineStageOrderingTests {
    @Test("stages run prepare app → plist → load → ping")
    func canonicalOrder() {
        #expect(InstallPipelineStage.allCases == [
            .copyBinary,
            .writePlist,
            .loadAgent,
            .awaitPing,
        ])
    }

    @Test("each install stage has visible labels and deliberate pacing")
    func installStageCopyAndPacing() {
        #expect(InstallStepContent.intro.contains("Nothing is written until you press Install"))
        #expect(InstallStepContent.stagePaceDelayNanoseconds >= 300_000_000)
        #expect(InstallStepContent.stagePaceDelayNanoseconds <= 600_000_000)
        #expect(InstallStepLayout.stageIconColumnWidth == 24)
        #expect(InstallStepLayout.stageRowMinHeight >= 28)
        for stage in InstallPipelineStage.allCases {
            #expect(!InstallStepContent.label(for: stage).isEmpty)
        }
    }

    @Test("install stage rows restore terminal status synchronously on remount")
    func installStageRowsRestoreTerminalStatusSynchronously() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let step = packageRoot.appending(path: "Sources/Wizard/Steps/InstallStep.swift")
        let source = try String(contentsOf: step, encoding: .utf8)

        #expect(source.contains("private func stageState(for stage"))
        #expect(source.contains("stageState(for: stage)"))
        #expect(source.contains("case .success, .alreadyInstalled:"))
        #expect(source.contains("private func stageIcon"))
    }
}

@Suite("Permission ordering")
struct PermissionOrderingTests {
    @Test("FDA, screen recording, accessibility")
    func canonicalOrder() {
        #expect(Permission.allCases == [
            .fullDiskAccess,
            .screenRecording,
            .accessibility,
        ])
    }
}

@Suite("WizardStep preferred heights")
struct WizardStepPreferredHeightTests {
    @Test("every step has a plausible height in [280, 560]")
    func heightsAreInRange() {
        // Guards against accidental 0/negative heights and against
        // runaway numbers that would break the 480×H canvas.
        for step in WizardStep.allCases {
            let h = step.preferredHeight
            #expect(h >= 280, "\(step) height \(h) is below the 280pt floor")
            #expect(h <= 560, "\(step) height \(h) is above the 560pt ceiling")
        }
    }

    @Test("Permissions is the tallest step (three cards)")
    func permissionsIsTallest() {
        let heights = WizardStep.allCases.map { $0.preferredHeight }
        let max = heights.max() ?? 0
        #expect(WizardStep.permissions.preferredHeight == max,
                "Permissions must be tallest so all three cards fit without scrolling")
    }

    @Test("opening gate steps share one no-resize band")
    func openingStepsShareNoResizeBand() {
        let gateHeight = WizardStep.welcome.preferredHeight
        #expect(WizardStep.tailscale.preferredHeight == gateHeight)
        #expect(WizardStep.existingInstall.preferredHeight == gateHeight)
        #expect(WizardLayout.shouldResizeWindow(from: .welcome, to: .tailscale) == false)
        #expect(WizardLayout.shouldResizeWindow(from: .tailscale, to: .existingInstall) == false)
    }

    @Test("install step leaves room for explicit confirmation without becoming tallest")
    func installStepConfirmationBand() {
        #expect(WizardStep.install.preferredHeight > WizardStep.existingInstall.preferredHeight)
        #expect(WizardStep.install.preferredHeight < WizardStep.permissions.preferredHeight)
    }

    @Test("window resize math is content-delta based")
    func contentDeltaDrivesResize() {
        #expect(WizardLayout.contentHeightDelta(from: .welcome, to: .tailscale) == 0)
        #expect(WizardLayout.contentHeightDelta(from: .existingInstall, to: .install) == 80)
        #expect(WizardLayout.contentHeightDelta(from: .install, to: .permissions) == 40)
    }
}

@Suite("Wizard visual layout tokens")
struct WizardVisualLayoutTests {
    @Test("welcome page centers its middle content as one unit")
    func welcomeCentersMiddleContentAsOneUnit() throws {
        #expect(WelcomeStepLayout.middleGroupSpacing > 0)
        #expect(WelcomeStepLayout.middleGroupSpacing < 64)

        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let step = packageRoot.appending(path: "Sources/Wizard/Steps/WelcomeStep.swift")
        let source = try String(contentsOf: step, encoding: .utf8)

        #expect(source.contains("VStack(spacing: WelcomeStepLayout.middleGroupSpacing)"))
        #expect(source.contains("alignment: .center"))
        #expect(!source.contains(".offset(y:"))
    }

    @Test("progress bar has tactile track dimensions")
    func progressBarIsThickEnoughForBevels() {
        #expect(WizardLayout.progressBarHeight >= 8)
        #expect(WizardLayout.progressBarWidth >= 80)
        #expect(WizardLayout.progressBarMinFillWidth == WizardLayout.progressBarHeight)
    }

    @Test("progress count renders as bare text without a nested pill")
    func progressCountHasNoNestedCapsule() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let wizardView = packageRoot.appending(path: "Sources/Wizard/WizardView.swift")
        let source = try String(contentsOf: wizardView, encoding: .utf8)
        let start = try #require(source.range(of: "private func progressCount"))
        let end = try #require(source.range(of: "private func progressTrack"))
        let progressCountSource = source[start.lowerBound..<end.lowerBound]

        #expect(!progressCountSource.contains(".background("))
        #expect(!progressCountSource.contains("Capsule(style: .continuous)"))
    }

    @Test("progress fill animates inside one rendered track")
    func progressFillAnimatesInsideSingleTrack() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let wizardView = packageRoot.appending(path: "Sources/Wizard/WizardView.swift")
        let source = try String(contentsOf: wizardView, encoding: .utf8)
        let start = try #require(source.range(of: "private func progressTrack"))
        let end = try #require(source.range(of: "// MARK: - Animated window resize"))
        let progressTrackSource = source[start.lowerBound..<end.lowerBound]

        #expect(source.contains("private struct WizardProgressTrack: View"))
        #expect(source.contains("Animatable"))
        #expect(source.contains("Canvas { context, size in"))
        #expect(source.contains("private var headerBar"))
        #expect(progressTrackSource.contains("WizardProgressTrack(fraction: fraction)"))
        #expect(progressTrackSource.contains(".animation(WizardLayout.progressAnimation"))
        #expect(!progressTrackSource.contains(".scaleEffect("))
    }

    @Test("header owns icon title and progress alignment in one row")
    func headerOwnsProgressAlignment() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let wizardView = packageRoot.appending(path: "Sources/Wizard/WizardView.swift")
        let source = try String(contentsOf: wizardView, encoding: .utf8)

        #expect(source.contains("HStack(alignment: .center, spacing: 12)"))
        #expect(source.contains("progressPill"))
        #expect(source.contains("height: WizardLayout.headerHeight, alignment: .center"))
        #expect(!source.contains("progressPillReservedWidth"))
    }

    @Test("wizard uses the bundled Exo 2 sans-serif face")
    func bundledSansFontIsAvailable() {
        #expect(TronFontLoader.bundledSansFamilyName == "Exo 2")
        #expect(TronFontLoader.bundledSansFontResource == "Exo2-Variable")
        #expect(TronFontLoader.bundledSansFontURL(in: .main) != nil)
        #expect(TronFontLoader.registerFonts(bundle: .main))
    }

    @Test("Exo 2 content and button sizes stay compact")
    func typographySizesStayCompact() {
        #expect(TronTypography.titleSize > TronTypography.bodySize)
        #expect(TronTypography.bodySize <= 15)
        #expect(TronTypography.buttonSize <= 14)
        #expect(TronTypography.subheadlineSize < TronTypography.bodySize)
        #expect(TronTypography.captionSize < TronTypography.subheadlineSize)
    }

    @Test("secondary buttons use the primary button corner radius")
    func secondaryButtonShapeMatchesPrimary() {
        #expect(WizardLayout.buttonCornerRadius == 11)
    }

    @Test("existing-install cleanup action is a separate compact card")
    func existingInstallCleanupUsesSeparateIconCard() throws {
        #expect(ExistingInstallStepLayout.contentSpacing <= 12)
        #expect(ExistingInstallStepLayout.cardVerticalPadding <= 4)
        #expect(ExistingInstallStepLayout.cleanupCardLeadingPadding >= 14)

        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let step = packageRoot.appending(path: "Sources/Wizard/Steps/ExistingInstallStep.swift")
        let source = try String(contentsOf: step, encoding: .utf8)

        #expect(source.contains("private var cleanupCard"))
        #expect(source.contains("Need a fresh start?"))
        #expect(source.contains("Keep auth and settings; remove app and LaunchAgent."))
        #expect(source.contains(".lineLimit(1)"))
        #expect(source.contains(".buttonStyle(.wizardTertiary)"))
        #expect(source.contains("trash.fill"))
        #expect(!source.contains("Divider()"))
    }

    @Test("permissions page has no Required badges and aligns the re-check link")
    func permissionsPageRemovesBadgesAndAlignsRecheck() throws {
        #expect(PermissionsStepLayout.recheckLeadingPadding > 0)

        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let step = packageRoot.appending(path: "Sources/Wizard/Steps/PermissionsStep.swift")
        let source = try String(contentsOf: step, encoding: .utf8)

        #expect(!source.contains("Required"))
        #expect(source.contains(".padding(.leading, PermissionsStepLayout.recheckLeadingPadding)"))
    }

    @Test("primary button has a distinct disabled visual state")
    func primaryButtonDisabledStateIsDistinct() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let style = packageRoot.appending(path: "Sources/Wizard/WizardButtonStyle.swift")
        let source = try String(contentsOf: style, encoding: .utf8)

        #expect(source.contains("@Environment(\\.isEnabled)"))
        #expect(source.contains("if !isEnabled"))
    }

    @Test("wizard step content uses TronTypography instead of ad-hoc system text fonts")
    func wizardStepContentFontsUseTypographyTokens() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let stepsDir = packageRoot.appending(path: "Sources/Wizard/Steps")
        let files = try FileManager.default.contentsOfDirectory(
            at: stepsDir,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "swift" }

        let disallowedTextFonts = [
            ".font(.body)",
            ".font(.headline)",
            ".font(.subheadline)",
            ".font(.caption)",
            ".font(.caption2",
            ".font(.system(.body",
        ]
        var violations: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8)
                .components(separatedBy: .newlines)
            for (index, line) in lines.enumerated()
                where disallowedTextFonts.contains(where: line.contains) {
                // SF Symbol sizing still uses system fonts; this guard
                // is about textual copy, not icon glyph dimensions.
                if line.contains("Image(") { continue }
                violations.append("\(file.lastPathComponent):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }

        #expect(violations.isEmpty, "Use TronTypography for wizard copy: \(violations.joined(separator: "; "))")
    }
}
