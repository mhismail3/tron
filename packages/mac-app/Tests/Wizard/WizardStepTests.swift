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
        #expect(InstallStepContent.intro == "Install Tron Server on this Mac. It runs quietly in the background so your iPhone can connect.")
        #expect(InstallStepContent.notStartedPlaceholder == "Installation not started")
        #expect(InstallStepContent.stagePaceDelayNanoseconds >= 300_000_000)
        #expect(InstallStepContent.stagePaceDelayNanoseconds <= 600_000_000)
        #expect(InstallStepLayout.sectionSpacing >= 16)
        #expect(InstallStepLayout.completedStageSpacing <= InstallStepLayout.runningStageSpacing)
        #expect(InstallStepLayout.stageIconColumnWidth == 24)
        #expect(InstallStepLayout.stageRowMinHeight >= 22)
        #expect(InstallStepLayout.stageIconGlyphSize <= 13)
        #expect(InstallStepContent.label(for: .writePlist) == "Add startup item")
        #expect(InstallStepContent.label(for: .loadAgent) == "Start server")
        for stage in InstallPipelineStage.allCases {
            #expect(!InstallStepContent.label(for: stage).isEmpty)
        }
    }

    @Test("successful install stage rows restore synchronously on remount")
    func successfulInstallStageRowsRestoreSynchronously() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let step = packageRoot.appending(path: "Sources/Wizard/Steps/InstallStep.swift")
        let source = try String(contentsOf: step, encoding: .utf8)

        #expect(source.contains("private func stageState(for stage"))
        #expect(source.contains("stageState(for: stage)"))
        #expect(source.contains("case .success:"))
        #expect(source.contains("case .alreadyInstalled:"))
        #expect(source.contains("stages.removeAll()"))
        #expect(source.contains("private func stageIcon"))
    }

    @Test("install progress is hidden until stages actually start")
    func installProgressRevealsOnlyActiveStages() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let step = packageRoot.appending(path: "Sources/Wizard/Steps/InstallStep.swift")
        let source = try String(contentsOf: step, encoding: .utf8)

        #expect(source.contains("private var visibleStages"))
        #expect(source.contains("stageState(for: stage) != .pending"))
        #expect(source.contains("private var stageProgressArea"))
        #expect(source.contains("Text(InstallStepContent.notStartedPlaceholder)"))
        #expect(source.contains("ForEach(visibleStages"))
        #expect(source.contains("stages[.copyBinary] = .running"))
        #expect(source.contains("completedStageSpacing"))
        #expect(source.contains("if shouldUseDetectedInstallLayout"))
        #expect(source.contains("private var detectedInstallSummary"))
        #expect(source.contains("Run `tron logs` to inspect recent server output."))
        #expect(!source.contains("Check Console.app"))
    }

    @Test("completed install page shows a status banner")
    func completedInstallPageShowsStatusBanner() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let step = packageRoot.appending(path: "Sources/Wizard/Steps/InstallStep.swift")
        let source = try String(contentsOf: step, encoding: .utf8)

        #expect(source.contains("private var installCompleteBanner"))
        #expect(source.contains("Tron is installed"))
        #expect(source.contains("Current status:"))
        #expect(source.contains("refreshInstallStatus"))
        #expect(source.contains("private var currentInstallRunSucceeded"))
        #expect(source.contains("InstallPipelineStage.allCases.allSatisfy"))
        #expect(source.contains("installCleanupCard"))
        #expect(source.contains("installedSummaryCards"))
        #expect(source.contains("installedSummaryTransition"))
        #expect(source.contains(".animation(WizardLayout.transitionAnimation, value: installIsComplete)"))
        #expect(source.contains("withAnimation(WizardLayout.transitionAnimation)"))
        #expect(source.contains("stages[.awaitPing] = .succeeded"))
        #expect(!source.contains("cleanupMessage"))
        #expect(source.contains("Need a fresh start?"))
        #expect(source.contains(".buttonStyle(.wizardTertiary)"))
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

    @Test("opening gate steps share one lower-height band")
    func openingStepsShareLowerHeightBand() {
        let gateHeight = WizardStep.welcome.preferredHeight
        #expect(WizardStep.tailscale.preferredHeight == gateHeight)
        #expect(gateHeight < WizardLayout.height)
    }

    @Test("install step leaves room for explicit confirmation without becoming tallest")
    func installStepConfirmationBand() {
        #expect(WizardStep.install.preferredHeight > WizardStep.tailscale.preferredHeight)
        #expect(WizardStep.install.preferredHeight < WizardStep.permissions.preferredHeight)
    }

    @Test("wizard canvas is fixed to the tallest step height")
    func wizardCanvasUsesTallestStepHeight() throws {
        let tallestStepHeight = try #require(WizardStep.allCases.map { $0.preferredHeight }.max())
        #expect(WizardLayout.height == tallestStepHeight)
        #expect(WizardLayout.height == WizardStep.permissions.preferredHeight)

        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let wizardView = packageRoot.appending(path: "Sources/Wizard/WizardView.swift")
        let source = try String(contentsOf: wizardView, encoding: .utf8)

        #expect(source.contains(".frame(width: WizardLayout.width, height: WizardLayout.height)"))
        #expect(!source.contains("animateHostingWindow"))
        #expect(!source.contains("displayStep.preferredHeight"))
    }
}

@Suite("Wizard visual layout tokens")
struct WizardVisualLayoutTests {
    @Test("welcome page shows only centered intro copy")
    func welcomePageShowsOnlyCenteredIntroCopy() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let step = packageRoot.appending(path: "Sources/Wizard/Steps/WelcomeStep.swift")
        let source = try String(contentsOf: step, encoding: .utf8)

        #expect(source.contains("Text(copy)"))
        #expect(source.contains(".multilineTextAlignment(.center)"))
        #expect(source.contains("alignment: .center"))
        #expect(!source.contains("existingInstallBanner"))
        #expect(!source.contains("Existing Tron install detected"))
        #expect(!source.contains("WizardInfoCard"))
        #expect(!source.contains("WizardIconTextRow"))
        #expect(!source.contains("existingInstallStatus"))
        #expect(!source.contains("WelcomeStepLayout"))
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
        let end = try #require(source.range(of: "// MARK: - Direction-aware slide transition"))
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

    @Test("installed-state cleanup action is a separate compact icon card")
    func installCleanupUsesSeparateIconCard() throws {
        #expect(InstallStepLayout.cleanupCardVerticalPadding > WizardCardLayout.verticalInset)
        #expect(InstallStepLayout.detectedSummaryTopPadding > InstallStepLayout.installedSummaryTopPadding)
        #expect(InstallStepLayout.installedSummaryTopPadding == 0)

        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let step = packageRoot.appending(path: "Sources/Wizard/Steps/InstallStep.swift")
        let source = try String(contentsOf: step, encoding: .utf8)

        #expect(source.contains("private var installCleanupCard"))
        #expect(source.contains("Need a fresh start?"))
        #expect(source.contains("Keep auth and settings; remove app and LaunchAgent."))
        #expect(source.contains(".fixedSize(horizontal: false, vertical: true)"))
        #expect(source.contains(".buttonStyle(.wizardTertiary)"))
        #expect(source.contains("trash.fill"))
    }

    @Test("icon-led cards use balanced icon padding")
    func iconLedCardsUseBalancedPadding() throws {
        #expect(WizardCardLayout.horizontalInset == WizardCardLayout.iconTextSpacing)
        #expect(WizardCardLayout.iconColumnWidth >= 28)
        #expect(WizardCardLayout.cornerRadius == 10)

        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let layout = try String(
            contentsOf: packageRoot.appending(path: "Sources/Wizard/WizardLayout.swift"),
            encoding: .utf8
        )
        #expect(layout.contains("WizardGlassCardBackground"))
        #expect(layout.contains(".ultraThinMaterial"))
        #expect(layout.contains("Color.tronEmerald.opacity(0.055)"))
        #expect(layout.contains("wizardGlassCard"))
        #expect(layout.contains(".fixedSize(horizontal: false, vertical: true)"))
        #expect(layout.contains(".layoutPriority(1)"))
        let cardBackgroundStart = try #require(layout.range(of: "struct WizardGlassCardBackground"))
        let cardBackgroundEnd = try #require(layout.range(of: "extension View"))
        let cardBackgroundSource = layout[cardBackgroundStart.lowerBound..<cardBackgroundEnd.lowerBound]
        #expect(!cardBackgroundSource.contains("LinearGradient"))

        for path in [
            "Sources/Wizard/Steps/TailscaleStep.swift",
            "Sources/Wizard/Steps/PermissionsStep.swift",
            "Sources/Wizard/Steps/PairingInfoStep.swift",
        ] {
            let source = try String(contentsOf: packageRoot.appending(path: path), encoding: .utf8)
            #expect(source.contains("WizardInfoCard"))
            #expect(source.contains("WizardIconTextRow"))
        }

        let install = try String(
            contentsOf: packageRoot.appending(path: "Sources/Wizard/Steps/InstallStep.swift"),
            encoding: .utf8
        )
        #expect(install.contains("WizardCardLayout.iconTextSpacing"))
        #expect(install.contains("WizardCardLayout.horizontalInset"))
        #expect(install.contains("WizardCardLayout.iconColumnWidth"))
    }

    @Test("low-density install and Tailscale pages use top-biased breathing room")
    func lowDensityPagesUseTopBiasedBreathingRoom() throws {
        #expect(TailscaleStepLayout.contentTopPadding > 64)
        #expect(TailscaleStepLayout.contentSpacing > WizardCardLayout.verticalInset)
        #expect(TailscaleStepLayout.statusCardVerticalPadding > WizardCardLayout.verticalInset)
        #expect(InstallStepLayout.detectedSummaryTopPadding > 48)
        #expect(InstallStepLayout.installedSummarySpacing > WizardCardLayout.verticalInset)

        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let tailscale = try String(
            contentsOf: packageRoot.appending(path: "Sources/Wizard/Steps/TailscaleStep.swift"),
            encoding: .utf8
        )
        #expect(tailscale.contains(".padding(.top, TailscaleStepLayout.contentTopPadding)"))
        #expect(tailscale.contains("WizardInfoCard(verticalPadding: TailscaleStepLayout.statusCardVerticalPadding)"))

        let install = try String(
            contentsOf: packageRoot.appending(path: "Sources/Wizard/Steps/InstallStep.swift"),
            encoding: .utf8
        )
        #expect(install.contains(".padding(.top, InstallStepLayout.detectedSummaryTopPadding)"))
        #expect(install.contains("alignment: .topLeading"))
    }

    @Test("permissions page has no Required badges and aligns the re-check link")
    func permissionsPageRemovesBadgesAndAlignsRecheck() throws {
        #expect(PermissionsStepLayout.recheckLeadingPadding > 0)
        #expect(PermissionsStepLayout.cardHorizontalPadding < WizardCardLayout.horizontalInset)
        #expect(PermissionsStepLayout.iconTextSpacing < WizardCardLayout.iconTextSpacing)
        #expect(PermissionsStepLayout.statusIconColumnWidth < WizardCardLayout.iconColumnWidth)
        #expect(PermissionsStepLayout.cardHorizontalPadding > 9)
        #expect(PermissionsStepLayout.cardHorizontalPadding < WizardCardLayout.horizontalInset)
        #expect(PermissionsStepLayout.appShortcutHitSize >= 40)
        #expect(PermissionsStepLayout.appShortcutHitSize > PermissionsStepLayout.appShortcutIconSize)
        #expect(PermissionsStepLayout.trailingControlSpacing <= 5)
        #expect(PermissionsStepContent.intro == "Tron needs these permissions to use your computer for you.")
        #expect(PermissionsStepContent.defaultInstruction == "Click gear and enable Tron.")
        #expect(PermissionsStepContent.screenRecordingInstruction == "Click gear, then drag this icon into the first app list.")
        #expect(PermissionsStepContent.initialProbeDelayNanoseconds >= 500_000_000)
        #expect(PermissionsStepContent.initialProbeDelayNanoseconds < 1_000_000_000)

        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let step = packageRoot.appending(path: "Sources/Wizard/Steps/PermissionsStep.swift")
        let source = try String(contentsOf: step, encoding: .utf8)

        #expect(!source.contains("Required"))
        #expect(source.contains("Lets Tron read and edit files."))
        #expect(source.contains("Lets Tron see your screen."))
        #expect(source.contains("Lets Tron click and type for you."))
        #expect(source.contains("instruction: PermissionsStepContent.defaultInstruction"))
        #expect(source.contains("instruction: PermissionsStepContent.screenRecordingInstruction"))
        #expect(source.contains("horizontalPadding: PermissionsStepLayout.cardHorizontalPadding"))
        #expect(source.contains("iconColumnWidth: PermissionsStepLayout.statusIconColumnWidth"))
        #expect(source.contains("iconTextSpacing: PermissionsStepLayout.iconTextSpacing"))
        #expect(source.contains(".minimumScaleFactor(0.92)"))
        #expect(source.contains(".minimumScaleFactor(0.88)"))
        #expect(source.contains(".allowsTightening(true)"))
        #expect(source.contains("if state.permissionStatuses.isEmpty"))
        #expect(source.contains("PermissionsStepContent.initialProbeDelayNanoseconds"))
        #expect(source.contains("if Task.isCancelled { return }"))
        #expect(source.contains("Button {"))
        #expect(source.contains("Task { await refreshAll(kickstart: true, showActivity: true) }"))
        #expect(source.contains("startSettingsGrantWatch(for: permission)"))
        #expect(source.contains("settingsGrantWatchTask?.cancel()"))
        #expect(source.contains("await refreshAll(kickstart: true, showActivity: false)"))
        #expect(source.contains("state.permissionStatuses[permission] == .granted"))
        #expect(PermissionsStepContent.settingsGrantWatchAttempts >= 30)
        #expect(PermissionsStepContent.settingsGrantWatchIntervalNanoseconds <= 1_000_000_000)
        #expect(source.contains("Checking permissions…"))
        #expect(!source.contains("Restarting Tron Server"))
        #expect(source.contains(".padding(.leading, PermissionsStepLayout.recheckLeadingPadding)"))
        #expect(source.contains(".fixedSize(horizontal: false, vertical: true)"))
    }

    @Test("pairing page resolves Tailscale live and treats settings as cache")
    func pairingPageResolvesTailscaleLiveAndCachesSettings() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let step = packageRoot.appending(path: "Sources/Wizard/Steps/PairingInfoStep.swift")
        let source = try String(contentsOf: step, encoding: .utf8)

        #expect(source.contains("Fresh installs do not have settings.json yet"))
        #expect(source.contains("setup.probeTailscale()"))
        #expect(source.contains("state.tailscaleStatus = liveTailscale"))
        #expect(source.contains("state.tailscaleStatus?.displayIP"))
        #expect(source.contains("setup.cacheTailscaleIP(host)"))
        #expect(source.contains("setup.readTailscaleIPFromSettings()"))
        #expect(source.contains("Pairing info unavailable"))
        #expect(source.contains("same account"))
        #expect(source.contains("enter the values manually"))
        #expect(source.contains("Fresh installs do not need a pre-existing settings.json."))
        #expect(source.contains("PairingInfoStepLayout.initialResolveDelayNanoseconds"))
        #expect(source.contains("PairingInfoStepLayout.copyCheckInAnimationSeconds"))
        #expect(source.contains("PairingInfoStepLayout.copyCheckOutAnimationSeconds"))
        #expect(source.contains("PairingInfoStepLayout.copyCheckHoldNanoseconds"))
        #expect(PairingInfoStepLayout.copyCheckInAnimationSeconds <= 0.08)
        #expect(PairingInfoStepLayout.copyCheckHoldNanoseconds >= 2_000_000_000)
        #expect(source.contains("WizardInfoCard("))
        #expect(source.contains("valueCardVerticalPadding"))
        #expect(source.contains("valueColumnWidth"))
        #expect(source.contains("private var pairingCluster"))
        #expect(source.contains("private enum PairingCopyField"))
        #expect(source.contains("copiedField == field ? \"checkmark\" : \"doc.on.doc\""))
        #expect(source.contains(".contentTransition(.symbolEffect(.replace))"))
        #expect(source.contains(".frame(maxWidth: .infinity, alignment: .center)"))
        #expect(source.contains(".wizardGlassCard()"))
        #expect(!source.contains("Refresh pairing info"))
        #expect(!source.contains("refreshSucceeded"))
        #expect(!source.contains("showRefreshSucceeded"))
        #expect(!source.contains("qrPayloadString"))
    }

    @Test("screen recording settings click asks agent to create the TCC row")
    func screenRecordingSettingsClickRequestsAgentPermission() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let step = packageRoot.appending(path: "Sources/Wizard/Steps/PermissionsStep.swift")
        let source = try String(contentsOf: step, encoding: .utf8)

        #expect(source.contains("openPermissionSettings"))
        #expect(source.contains("permission == .screenRecording"))
        #expect(source.contains("setup.requestAgentPermission(permission)"))
    }

    @Test("screen recording row exposes draggable installed app shortcut")
    func screenRecordingRowExposesDraggableAppShortcut() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let step = packageRoot.appending(path: "Sources/Wizard/Steps/PermissionsStep.swift")
        let source = try String(contentsOf: step, encoding: .utf8)

        #expect(source.contains("ScreenRecordingAppShortcut(appURL: setup.installedBundle)"))
        #expect(source.contains("NSViewRepresentable"))
        #expect(source.contains("DraggableAppShortcutView: NSView"))
        #expect(source.contains("appShortcutHitSize"))
        #expect(source.contains("mouseDownCanMoveWindow"))
        #expect(source.contains("shouldDelayWindowOrdering"))
        #expect(source.contains("dragStartedInMouseSequence"))
        #expect(source.contains("beginDraggingSession"))
        #expect(source.contains("endedAt screenPoint"))
        #expect(source.contains("!dragStartedInMouseSequence"))
        #expect(source.contains("NSDraggingItem(pasteboardWriter:"))
        #expect(source.contains("NSPasteboardItem()"))
        #expect(source.contains("NSFilenamesPboardType"))
        #expect(source.contains("forType: .fileURL"))
        #expect(source.contains("NSWorkspace.shared.activateFileViewerSelecting([appURL])"))
        #expect(source.contains("Drag Tron.app into the Screen Recording list"))
        #expect(source.contains("appIconLiftShadow"))
        #expect(!source.contains("emeraldShortcutShadow"))
    }

    @Test("permissions step disables background window dragging for shortcut drags")
    func permissionsStepDisablesBackgroundWindowDraggingForShortcutDrags() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let wizardView = packageRoot.appending(path: "Sources/Wizard/WizardView.swift")
        let source = try String(contentsOf: wizardView, encoding: .utf8)

        #expect(source.contains("applyWindowBackgroundDragPolicy"))
        #expect(source.contains(".configureHostingWindow"))
        #expect(source.contains("window.isMovableByWindowBackground = step != .permissions"))
        #expect(source.contains("applyWindowBackgroundDragPolicy(for: newStep)"))
        #expect(source.contains("hostingWindow?.isMovableByWindowBackground = true"))
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
