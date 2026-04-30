import Foundation
import Testing
@testable import TronMac

/// Pins the canonical step ordering so a silent reorder triggers a
/// failing test instead of a confused user.
@Suite("WizardStep ordering")
struct WizardStepOrderingTests {
    @Test("allCases is in canonical order (iOS beta precedes pairing)")
    func canonicalOrder() {
        // Install runs BEFORE permissions on purpose: the wrapper first
        // registers the LaunchAgent with its associated bundle IDs, then
        // probes/prompts the wrapper-owned TCC rows that macOS shows in
        // System Settings. Transcription comes after permissions so its
        // optional helper restart is the final first-run server restart.
        // The iOS beta handoff must then run before the pairing QR.
        #expect(WizardStep.allCases == [
            .welcome,
            .tailscale,
            .install,
            .permissions,
            .transcription,
            .iosBeta,
            .pairingInfo,
            .done,
        ])
    }

    @Test("rawValues are stable strings (used as UserDefaults keys)")
    func rawValuesStable() {
        #expect(WizardStep.welcome.rawValue == "welcome")
        #expect(WizardStep.tailscale.rawValue == "tailscale")
        #expect(WizardStep.permissions.rawValue == "permissions")
        #expect(WizardStep.transcription.rawValue == "transcription")
        #expect(WizardStep.install.rawValue == "install")
        #expect(WizardStep.iosBeta.rawValue == "iosBeta")
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
    @Test("stages run validate app, validate helper, sync skills, register, ping")
    func canonicalOrder() {
        #expect(InstallPipelineStage.allCases == [
            .validateApplication,
            .validateHelper,
            .syncSkills,
            .registerAgent,
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
        #expect(InstallStepContent.label(for: .validateApplication) == "Confirm app location")
        #expect(InstallStepContent.label(for: .syncSkills) == "Sync managed skills")
        #expect(InstallStepContent.label(for: .registerAgent) == "Register Login Item")
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
        #expect(source.contains("guard !stages.isEmpty else { return false }"))
        #expect(!source.contains("case .alreadyInstalled:"))
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
        #expect(source.contains("stages[.validateApplication] = .running"))
        #expect(source.contains("completedStageSpacing"))
        #expect(source.contains("if shouldShowRegisteredServiceLayout"))
        #expect(source.contains("private var registeredServiceSummary"))
        #expect(source.contains("Open the logs window from the Tron menu bar"))
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

        #expect(source.contains("private var serverReadyBanner"))
        #expect(source.contains("Tron Server is ready"))
        #expect(source.contains("Current status:"))
        #expect(source.contains("refreshInstallStatus"))
        #expect(source.contains("private var currentInstallRunSucceeded"))
        #expect(source.contains("InstallPipelineStage.allCases.allSatisfy"))
        #expect(source.contains("readySummaryCards"))
        #expect(source.contains("readySummaryTransition"))
        #expect(source.contains(".animation(WizardLayout.transitionAnimation, value: installIsComplete)"))
        #expect(source.contains("withAnimation(WizardLayout.transitionAnimation)"))
        #expect(source.contains("stages[.awaitPing] = .succeeded"))
        #expect(!source.contains("cleanupMessage"))
        #expect(!source.contains("Need a fresh start?"))
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

    @Test("registered-state summary keeps the banner aligned")
    func registeredSummaryKeepsBannerAligned() throws {
        #expect(InstallStepLayout.detectedSummaryTopPadding > InstallStepLayout.readySummaryTopPadding)
        #expect(InstallStepLayout.readySummaryTopPadding == 0)

        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let step = packageRoot.appending(path: "Sources/Wizard/Steps/InstallStep.swift")
        let source = try String(contentsOf: step, encoding: .utf8)

        #expect(source.contains("private var readySummaryCards"))
        #expect(source.contains("private var registeredServiceCard"))
        #expect(source.contains("serverReadyBanner"))
        #expect(!source.contains("private var installCleanupCard"))
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
            "Sources/Wizard/Steps/TranscriptionStep.swift",
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

    @Test("transcription step owns local model opt-in")
    func transcriptionStepOwnsLocalModelOptIn() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let step = packageRoot.appending(path: "Sources/Wizard/Steps/TranscriptionStep.swift")
        let source = try String(contentsOf: step, encoding: .utf8)
        let shell = try String(contentsOf: packageRoot.appending(path: "Sources/Wizard/WizardView.swift"), encoding: .utf8)

        #expect(TranscriptionStepContent.toggleTitle == "Enable local transcription")
        #expect(source.contains("state.transcriptionEnabledSelection"))
        #expect(source.contains("~/.tron/system/transcription/models/hf"))
        #expect(shell.contains("setup.applyTranscriptionPreference"))
        #expect(shell.contains("case .transcription:"))
        #expect(shell.contains("transcriptionPrimaryLabel"))
    }

    @Test("iOS beta page owns the public TestFlight QR handoff")
    func iosBetaPageOwnsPublicTestFlightQRHandoff() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let step = packageRoot.appending(path: "Sources/Wizard/Steps/IOSBetaStep.swift")
        let source = try String(contentsOf: step, encoding: .utf8)
        let shell = try String(contentsOf: packageRoot.appending(path: "Sources/Wizard/WizardView.swift"), encoding: .utf8)

        #expect(IOSBetaStepContent.testFlightURL.absoluteString == "https://testflight.apple.com/join/xbuX1Grx")
        #expect(IOSBetaStepContent.testFlightURL.host == "testflight.apple.com")
        #expect(IOSBetaStepContent.testFlightURL.path == "/join/xbuX1Grx")
        #expect(IOSBetaStepContent.displayLink == "testflight.apple.com/join/xbuX1Grx")
        #expect(source.contains("QRCodeGenerator.makeImage("))
        #expect(source.contains("IOSBetaStepContent.testFlightURL.absoluteString"))
        #expect(source.contains("Link(destination: IOSBetaStepContent.testFlightURL)"))
        #expect(source.contains("NSPasteboard.general"))
        #expect(source.contains("WizardInfoCard"))
        #expect(source.contains("private var scanCard"))
        #expect(source.contains("HStack(alignment: .center, spacing: IOSBetaStepLayout.headerSpacing)"))
        #expect(source.contains("horizontalPadding: IOSBetaStepLayout.cardHorizontalPadding"))
        #expect(source.contains("verticalPadding: 0"))
        #expect(source.contains(".padding(.top, IOSBetaStepLayout.linkTextTopPadding)"))
        #expect(source.contains(".padding(.bottom, IOSBetaStepLayout.linkTextBottomPadding)"))
        #expect(source.contains("width: IOSBetaStepLayout.iconFrameSize"))
        #expect(!source.contains("scanIconReservedWidth"))
        #expect(!source.contains("linkCardHorizontalPadding"))
        #expect(!source.contains("linkCardVerticalPadding"))
        #expect(!source.contains("Label(\"Open TestFlight page\""))
        #expect(!source.contains("NSWorkspace.shared.open(IOSBetaStepContent.testFlightURL)"))
        #expect(source.contains("TestFlight finishes installing Tron"))
        #expect(shell.contains("case .iosBeta:"))
        #expect(shell.contains("IOSBetaStep()"))
        #expect(shell.contains("I installed Tron"))
    }

    @Test("low-density install and Tailscale pages use top-biased breathing room")
    func lowDensityPagesUseTopBiasedBreathingRoom() throws {
        #expect(TailscaleStepLayout.contentTopPadding > 64)
        #expect(TailscaleStepLayout.contentSpacing > WizardCardLayout.verticalInset)
        #expect(TailscaleStepLayout.statusCardVerticalPadding > WizardCardLayout.verticalInset)
        #expect(InstallStepLayout.detectedSummaryTopPadding > 48)
        #expect(InstallStepLayout.readySummarySpacing > WizardCardLayout.verticalInset)

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
        #expect(PermissionsStepContent.intro == "Enable the Tron app named on each row in System Settings.")
        #expect(PermissionsStepContent.initialProbeDelayNanoseconds >= 500_000_000)
        #expect(PermissionsStepContent.initialProbeDelayNanoseconds < 1_000_000_000)

        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let step = packageRoot.appending(path: "Sources/Wizard/Steps/PermissionsStep.swift")
        let source = try String(contentsOf: step, encoding: .utf8)

        #expect(!source.contains("Required"))
        #expect(source.contains("Lets Tron Server read and edit files."))
        #expect(source.contains("Lets Tron Server see your screen."))
        #expect(source.contains("Lets Tron Server click and type for you."))
        #expect(source.contains("permissionAppDisplayName"))
        #expect(!source.contains("setup.serverHelperBundle"))
        #expect(!source.contains("system.probePermissions"))
        #expect(!source.contains("setup.probeAgentPermissions"))
        #expect(!source.contains("setup.requestWrapperPermission"))
        #expect(source.contains("setup.probePermissions()"))
        #expect(source.contains("Enable \\\"\\(appName)\\\" in Full Disk Access."))
        #expect(source.contains("Drag the icon into the list if \\\"\\(appName)\\\" is missing."))
        #expect(source.contains("Enable \\\"\\(appName)\\\" in Accessibility."))
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
        #expect(source.contains("Task { await refreshAll(showActivity: true) }"))
        #expect(source.contains("startSettingsGrantWatch(for: permission)"))
        #expect(source.contains("settingsGrantWatchTask?.cancel()"))
        #expect(source.contains("await refreshAll(showActivity: false)"))
        #expect(source.contains("state.permissionStatuses[permission] == .granted"))
        #expect(PermissionsStepContent.settingsGrantWatchAttempts >= 10)
        #expect(PermissionsStepContent.settingsGrantWatchAttempts <= 30)
        #expect(PermissionsStepContent.settingsGrantWatchIntervalNanoseconds <= 750_000_000)
        #expect(PermissionsStepContent.appDisplayName(
            for: URL(fileURLWithPath: "/Users/dev/DerivedData/Debug/TronMac.app", isDirectory: true)
        ) == "TronMac.app")
        #expect(PermissionsStepContent.appDisplayName(
            for: URL(fileURLWithPath: "/Applications/Tron.app", isDirectory: true)
        ) == "Tron.app")
        #expect(source.contains("Checking permissions…"))
        #expect(source.contains("applyPermissionSnapshot"))
        #expect(source.contains("status == .probeUnavailable"))
        #expect(!source.contains("refreshAll(kickstart"))
        #expect(!source.contains("Restarting Tron Server"))
        #expect(source.contains("if permission == .screenRecording"))
        #expect(source.contains("ScreenRecordingAppShortcut"))
        #expect(source.contains("NSDraggingItem"))
        #expect(source.contains("NSFilenamesPboardType"))
        #expect(!source.contains("CGRequestScreenCaptureAccess"))
        #expect(!source.contains("AXIsProcessTrustedWithOptions"))
        #expect(!source.contains("MacPermissionRequester"))
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
        #expect(source.contains("@State private var resolvedQRCode: NSImage?"))
        #expect(source.contains("private var shouldShowLoading"))
        #expect(source.contains("private var shouldShowResolvedPairing"))
        #expect(source.contains("private var loadingPanel"))
        #expect(source.contains("PairingResolvingSpinner()"))
        #expect(source.contains("private struct PairingResolvingSpinner"))
        #expect(source.contains("Color.tronEmerald"))
        #expect(source.contains("revealAnimation = Animation.timingCurve"))
        #expect(source.contains("static var revealTransition: AnyTransition"))
        #expect(source.contains("AnyTransition.opacity"))
        #expect(source.contains("withAnimation(PairingInfoStepLayout.revealAnimation)"))
        #expect(source.contains("resolvedQRCode = qrImage"))
        #expect(source.contains("if let qrImage = resolvedQRCode"))
        #expect(!source.contains("private var currentQRCode"))
        #expect(source.contains("PairingInfoStepLayout.clusterWidth"))
        #expect(source.contains("PairingInfoStepLayout.clusterHeight"))
        let loadingPanelStart = try #require(source.range(of: "private var loadingPanel"))
        let loadingPanelEnd = try #require(source.range(of: "@ViewBuilder\n    private var qrPanel"))
        let loadingPanelSource = source[loadingPanelStart.lowerBound..<loadingPanelEnd.lowerBound]
        #expect(!loadingPanelSource.contains(".wizardGlassCard()"))
        #expect(!loadingPanelSource.contains("ProgressView()"))
        #expect(source.contains("Pairing info unavailable"))
        #expect(!source.contains("Pairing info loading"))
        #expect(!source.contains("Resolving Tron Server, Tailscale, and the local pairing token."))
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
        #expect(source.contains("clusterWidth"))
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

    @Test("permission settings buttons only open System Settings")
    func permissionSettingsButtonsOnlyOpenSettings() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let step = packageRoot.appending(path: "Sources/Wizard/Steps/PermissionsStep.swift")
        let source = try String(contentsOf: step, encoding: .utf8)

        #expect(source.contains("openPermissionSettings"))
        #expect(source.contains("NSWorkspace.shared.open(PermissionDeepLink.url(for: permission))"))
        #expect(!source.contains("setup.requestWrapperPermission"))
        #expect(!source.contains("CGRequestScreenCaptureAccess"))
        #expect(!source.contains("AXIsProcessTrustedWithOptions"))
    }

    @Test("only Screen Recording exposes a draggable app shortcut")
    func onlyScreenRecordingExposesDraggableAppShortcut() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let step = packageRoot.appending(path: "Sources/Wizard/Steps/PermissionsStep.swift")
        let source = try String(contentsOf: step, encoding: .utf8)

        #expect(!source.contains("PermissionAppShortcut"))
        #expect(source.contains("if permission == .screenRecording"))
        #expect(source.contains("ScreenRecordingAppShortcut"))
        #expect(source.contains("NSViewRepresentable"))
        #expect(!source.contains("DraggableAppShortcutView"))
        #expect(source.contains("appShortcutHitSize"))
        #expect(source.contains("mouseDownCanMoveWindow"))
        #expect(source.contains("NSDraggingItem"))
        #expect(source.contains("NSPasteboardItem"))
        #expect(source.contains("NSFilenamesPboardType"))
        #expect(!source.contains("activateFileViewerSelecting"))
    }

    @Test("wizard keeps background window dragging enabled on permissions")
    func wizardKeepsBackgroundWindowDraggingEnabledOnPermissions() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let wizardView = packageRoot.appending(path: "Sources/Wizard/WizardView.swift")
        let source = try String(contentsOf: wizardView, encoding: .utf8)

        #expect(source.contains(".configureHostingWindow"))
        #expect(source.contains("window.isMovableByWindowBackground = true"))
        #expect(!source.contains("applyWindowBackgroundDragPolicy"))
        #expect(!source.contains("step != .permissions"))

        let app = try String(
            contentsOf: packageRoot.appending(path: "Sources/TronMacApp.swift"),
            encoding: .utf8
        )
        #expect(!app.contains("window.isMovableByWindowBackground = true"))
    }

    @Test("permissions continue restarts helper once before pairing")
    func permissionsContinueRestartsHelperOnceBeforePairing() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let wizardView = try String(
            contentsOf: packageRoot.appending(path: "Sources/Wizard/WizardView.swift"),
            encoding: .utf8
        )
        let wizardState = try String(
            contentsOf: packageRoot.appending(path: "Sources/Wizard/WizardState.swift"),
            encoding: .utf8
        )

        #expect(wizardView.contains("permissionsServerRestarted"))
        #expect(wizardView.contains("permissionsRestartInProgress"))
        #expect(wizardView.contains("launchAgentManager.restart(label: setup.launchAgentLabel)"))
        #expect(wizardView.contains("Finalizing…"))
        #expect(wizardState.contains("var permissionsServerRestarted = false"))
        #expect(wizardState.contains("var permissionsRestartInProgress = false"))
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

    @Test("Tailscale primary action rechecks before advancing")
    func tailscalePrimaryActionRechecksBeforeAdvancing() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let wizardView = packageRoot.appending(path: "Sources/Wizard/WizardView.swift")
        let source = try String(contentsOf: wizardView, encoding: .utf8)

        #expect(source.contains("case .tailscale:"))
        #expect(source.contains("let status = await setup.probeTailscale()"))
        #expect(source.contains("state.tailscaleStatus = status"))
        #expect(source.contains("if status.isReady"))
        #expect(source.contains("state.tailscaleStatus?.isReady == true ? \"Continue\" : \"I have Tailscale\""))
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
