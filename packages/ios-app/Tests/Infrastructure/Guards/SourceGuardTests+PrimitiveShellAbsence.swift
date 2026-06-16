import Testing
import Foundation

extension SourceGuardTests {

    @Test("Draft persistence has no skills residue")
    func testDraftPersistenceHasNoSkillsResidue() throws {
        let iosRoot = iosAppRoot()
        let checkedPaths = [
            "Sources/Engine/Persistence",
            "Sources/Support/Storage/DraftStore.swift",
            "Tests/Infrastructure",
            "Tests/Services/DraftStoreTests.swift",
        ]
        let forbidden = [
            "skills" + "_json",
            "spells" + "_json",
            "selected" + "Skills",
            "Selected" + "Skill",
        ]

        for relativePath in checkedPaths {
            let url = iosRoot.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let files: [URL]
            if (try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                files = try swiftFiles(in: url)
            } else {
                files = [url]
            }
            for file in files where !isSourceGuardFile(file) {
                let source = try String(contentsOf: file, encoding: .utf8)
                for token in forbidden {
                    #expect(!source.contains(token), "\(token) must stay deleted from draft persistence path: \(file.path)")
                }
            }
        }
    }


    @Test("Primitive shell has no user-interaction pause plane")
    func testPrimitiveShellHasNoUserInteractionPausePlane() throws {
        let iosRoot = iosAppRoot()
        let checkedPaths = [
            "Sources",
            "Tests",
            "project.yml",
        ]
        let forbidden = [
            "User" + "Interaction" + "Invocation",
            "User" + "Interaction" + "Capability",
            "User" + "Interaction" + "Coordinator",
            "User" + "Interaction" + "State",
            "User" + "Interaction" + "Sheet",
            "User" + "Interaction" + "Viewer",
            "case " + "user" + "Interaction",
            "." + "user" + "Interaction",
            "answered" + "Questions",
            "submit" + "Answers",
            "Submit" + "Answers",
            "agent::" + "submit_answers",
            "capability.pause.",
            "Capability" + "Pause",
            "pause" + "Id",
            "prompt" + "Payload",
            "answer" + "Authority",
            "interaction" + "Status",
            "parsed" + "Answers",
            "ask" + "_user",
            "is" + "User" + "Interaction" + "Capability",
        ]

        for relativePath in checkedPaths {
            let url = iosRoot.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let files: [URL]
            if (try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                files = try swiftFiles(in: url)
            } else {
                files = [url]
            }
            for file in files where !isSourceGuardFile(file) {
                let source = try String(contentsOf: file, encoding: .utf8)
                for token in forbidden {
                    #expect(!source.contains(token), "\(token) must stay deleted from primitive shell: \(file.path)")
                }
            }
        }
    }


    @Test("Primitive shell has no fixed process session list plane")
    func testPrimitiveShellHasNoFixedProcessSessionActivityPlane() throws {
        let iosRoot = iosAppRoot()
        let deletedPaths = [
            "Sources/Engine/Events/Core/Plugins/Process",
            "Sources/Session/Chat/ViewModel/ChatViewModel+ProcessEvents.swift",
            "Sources/Session/Chat/State/ProcessState.swift",
            "Sources/UI/Capabilities/Process",
            "Sources/UI/Process",
            "Tests/ViewModels/State/ProcessStateTests.swift",
        ]
        for relativePath in deletedPaths {
            #expect(
                !FileManager.default.fileExists(atPath: iosRoot.appendingPathComponent(relativePath).path),
                "\(relativePath) belongs to the deleted fixed process session list plane"
            )
        }

        let checkedPaths = [
            "Sources",
            "Tests",
            "project.yml",
        ]
        let forbidden = [
            "Process" + "List" + "Sheet",
            "Process" + "State",
            "Process" + "Event" + "Handler",
            "Process" + "Spawned" + "Plugin",
            "Process" + "Completed" + "Plugin",
            "Process" + "Status" + "Update" + "Plugin",
            "Job" + "Backgrounded" + "Plugin",
            "Manage" + "Process" + "Result" + "Viewer",
            "show" + "Process" + "Sheet",
            "clear" + "Process" + "State",
            "handle" + "Process" + "Spawned",
            "handle" + "Process" + "Completed",
            "handle" + "Process" + "Status" + "Update",
            "handle" + "Job" + "Backgrounded",
            "process" + "." + "spawned",
            "process" + "." + "completed",
            "process" + "." + "status_update",
            "job" + "." + "backgrounded",
            "case " + "processes",
        ]

        for relativePath in checkedPaths {
            let url = iosRoot.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let files: [URL]
            if (try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                files = try swiftFiles(in: url)
            } else {
                files = [url]
            }
            for file in files where !isSourceGuardFile(file) {
                let source = try String(contentsOf: file, encoding: .utf8)
                for token in forbidden {
                    #expect(!source.contains(token), "\(token) must stay deleted from primitive shell: \(file.path)")
                }
            }
        }
    }


    @Test("Primitive shell has no prompt suggestion hook plane")
    func testPrimitiveShellHasNoPromptSuggestionHookPlane() throws {
        let iosRoot = iosAppRoot()
        let deletedPaths = [
            "Sources/Engine/Events/Core/Plugins/Hook",
            "Sources/Session/Chat/ViewModel/ChatViewModel+" + "Hook" + "Events.swift",
            "Sources/Session/Chat/State/Pull" + "Up" + "Panel" + "State.swift",
            "Sources/UI/Chat/Composer/Input" + "Area" + "Drag" + "Modifier.swift",
            "Sources/UI/Chat/Composer/Pull" + "Up" + "Panel" + "View.swift",
        ]
        for relativePath in deletedPaths {
            #expect(
                !FileManager.default.fileExists(atPath: iosRoot.appendingPathComponent(relativePath).path),
                "\(relativePath) belongs to the deleted prompt suggestion hook plane"
            )
        }

        let sourceRoots = [
            iosRoot.appendingPathComponent("Sources"),
            iosRoot.appendingPathComponent("Tests"),
        ]
        let forbiddenNeedles: [(String, String)] = [
            ("hook" + "." + "llm_result", "hook-result event type"),
            ("Llm" + "Hook" + "Result", "hook-result plugin"),
            ("handle" + "Llm" + "Hook" + "Result", "hook-result event handler"),
            ("Pull" + "Up" + "Panel", "prompt suggestion panel"),
            ("awaiting" + "Suggestions", "prompt suggestion latch"),
            ("suggest" + "-" + "prompts", "prompt suggestion worker"),
            ("post" + "Processing", "third lifecycle phase"),
            ("is" + "Post" + "Processing", "third lifecycle convenience state"),
            ("background " + "hooks", "hook lifecycle state"),
        ]

        for root in sourceRoots {
            for url in try swiftFiles(in: root) {
                if isSourceGuardFile(url) { continue }
                let content = try String(contentsOf: url, encoding: .utf8)
                for (needle, reason) in forbiddenNeedles {
                    #expect(
                        !content.contains(needle),
                        "\(url.path) contains deleted \(reason): `\(needle)`"
                    )
                }
            }
        }
    }


    @Test("iOS runtime contract is iOS 26 only")
    func testIOSRuntimeContractIsIOS26Only() throws {
        let iosRoot = iosAppRoot()

        let projectYML = try String(
            contentsOf: iosRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        let baseConfig = try String(
            contentsOf: iosRoot.appendingPathComponent("Configuration/Base.xcconfig"),
            encoding: .utf8
        )
        let appEntry = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/App/Lifecycle/TronMobileApp.swift"),
            encoding: .utf8
        )
        let architectureDoc = try String(
            contentsOf: iosRoot.appendingPathComponent("docs/architecture.md"),
            encoding: .utf8
        )
        let rootReadme = try String(
            contentsOf: iosRoot
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("README.md"),
            encoding: .utf8
        )

        #expect(projectYML.contains(#"iOS: "26.0""#))
        #expect(baseConfig.contains("IPHONEOS_DEPLOYMENT_TARGET = 26.0"))
        #expect(architectureDoc.contains("**Minimum iOS**: 26.0"))
        #expect(!architectureDoc.contains("**Minimum iOS**: 18.0"))
        #expect(rootReadme.contains("**Minimum iOS:** 26.0"))
        #expect(!rootReadme.contains("**Minimum iOS:** 18.0"))
        #expect(!appEntry.contains("This app requires iOS 26 or later"))
        #expect(!appEntry.contains("if #available(iOS 26.0, *)"))
    }


    @Test("Primitive shell has no fixed prompt picker plane")
    func testPrimitiveShellHasNoFixedPromptPickerPlane() throws {
        let iosRoot = iosAppRoot()
        let promptRoot = iosRoot.appendingPathComponent("Sources/UI/Prompt" + "Library")

        #expect(!FileManager.default.fileExists(atPath: promptRoot.path))
        #expect(!FileManager.default.fileExists(
            atPath: iosRoot.appendingPathComponent("Sources/Session/Chat/State/Prompt" + "LibraryState.swift").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: iosRoot.appendingPathComponent("Sources/Engine/Protocol/DTOs/EngineProtocolTypes+Prompt" + "Library.swift").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: iosRoot.appendingPathComponent("Sources/Engine/Network/Clients/Prompt" + "LibraryClient.swift").path
        ))
    }


    @Test("Composer attachment menu stays functional-only")
    func testComposerAttachmentMenuStaysFunctionalOnly() throws {
        let iosRoot = iosAppRoot()
        let checkedPaths = [
            "Sources/UI/Chat/Composer/AttachmentMenuSheet.swift",
            "Sources/UI/Chat/Composer/ActionButtons.swift",
            "Sources/UI/Chat/Composer/InputBar.swift",
        ]
        let requiredCommands = [
            "Take Photo",
            "Photo Library",
            "Choose File",
        ]
        let requiredLayoutFragments = [
            "LazyVGrid",
            "CompactActionSheetButton",
            "compactHeightSheetPresentation",
            ".sheet(isPresented: $showCamera)",
            ".sheet(isPresented: $showFilePicker)",
            ".photosPicker(",
            "selectedImages: $state.selectedImages",
        ]
        let forbiddenFragments = [
            "Add " + "Skill",
            "Prompt " + "Library",
            "Draft a " + "Plan",
            "draft" + "Plan" + "Requested",
            "Queued" + "Message",
            "Pending" + "Queue" + "Item",
            "show" + "Skill",
            "skill" + "Mention",
            "prompt" + "Library",
            "attachment" + "Menu" + "Action",
            "pending" + "Attachment" + "Menu" + "Action",
            "present" + "Pending" + "Attachment" + "Menu" + "Action",
            "onDismiss: present" + "Pending" + "Attachment" + "Menu" + "Action",
        ]

        let combined = try checkedPaths.map { relativePath in
            try String(
                contentsOf: iosRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
        }.joined(separator: "\n")

        for command in requiredCommands {
            #expect(combined.contains(command), "composer attachment menu must expose \(command)")
        }

        for fragment in requiredLayoutFragments {
            #expect(combined.contains(fragment), "composer attachment menu must keep compact grid sheet layout `\(fragment)`")
        }

        for fragment in forbiddenFragments {
            #expect(
                !combined.contains(fragment),
                "composer attachment menu must not restore Phase 2/review-only affordance `\(fragment)`"
            )
        }

        let inputBarSource = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/UI/Chat/Composer/InputBar.swift"),
            encoding: .utf8
        )
        let parentSheetCloseAssignments = inputBarSource
            .components(separatedBy: .newlines)
            .filter { line in
                line.contains("showAttachmentMenu = false") && !line.contains("@State")
            }
        #expect(
            parentSheetCloseAssignments.isEmpty,
            "attachment menu actions must not close the parent sheet before presenting child pickers"
        )
    }


    @Test("Camera capture setup stays off the presentation path")
    func testCameraCaptureSetupStaysOffPresentationPath() throws {
        let iosRoot = iosAppRoot()
        let source = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/UI/Chat/Composer/CameraCaptureSheet.swift"),
            encoding: .utf8
        )

        #expect(
            source.contains("var session: AVCaptureSession?"),
            "camera sheet should defer AVCaptureSession creation until after presentation starts"
        )
        #expect(
            source.contains("let captureSession = existingSession ?? AVCaptureSession()"),
            "camera sheet should create capture sessions inside the asynchronous setup path"
        )
        #expect(
            source.contains("sessionQueue.async"),
            "camera sheet should perform capture-session setup on its session queue"
        )
        #expect(
            source.contains("private nonisolated static func configure"),
            "camera setup should use a nonisolated helper so AVFoundation work is not forced onto MainActor"
        )
        #expect(
            source.contains("private nonisolated static func cameraDevice(for position: AVCaptureDevice.Position)"),
            "camera setup should discover front/back camera variants instead of assuming only the wide-angle device type"
        )
        #expect(
            source.contains(".builtInTrueDepthCamera"),
            "camera switching should support TrueDepth/front-camera devices"
        )
        #expect(
            source.contains("ZStack(alignment: .bottom)"),
            "camera controls should layer inside the full-bleed viewport instead of living below a framed preview"
        )
        #expect(
            source.contains("GeometryReader { proxy in"),
            "camera foreground controls should expand to the detent height before bottom alignment is applied"
        )
        #expect(
            source.contains("CameraControlMetrics.bottomPadding + proxy.safeAreaInsets.bottom"),
            "camera controls should stay low while remaining above the sheet bottom safe-area edge"
        )
        #expect(
            source.contains(".immersiveCameraSheetPresentation"),
            "camera viewport should be the sheet presentation background so sheet safe-area material cannot show below it"
        )
        #expect(
            source.contains(".ignoresSafeArea(.container, edges: .all)"),
            "camera viewport should fill the rounded sheet container instead of leaving bottom inset space"
        )
        #expect(
            !source.contains(".clipped()"),
            "camera viewport must not clip itself at the sheet content safe-area boundary"
        )
        #expect(
            source.contains("private var cameraSurface: some View"),
            "camera sheet should keep the live preview/captured image in a reusable full-presentation surface"
        )
        #expect(
            source.contains("private enum CameraControlMetrics"),
            "camera control sizing should be centralized so the immersive viewport stays visually disciplined"
        )
        #expect(
            source.contains("static let bottomPadding: CGFloat = 48"),
            "camera controls should sit close to the bottom of the viewport instead of floating high in the sheet"
        )
        #expect(
            source.contains("static let iconHitTargetSize: CGFloat = 60"),
            "camera side controls should keep a larger tappable area than their compact visual glass button"
        )
        #expect(
            source.contains("private func cameraGlassSurface"),
            "camera controls should share one liquid-glass surface helper"
        )
        #expect(
            source.contains("static let captureGlassSize: CGFloat = 76"),
            "camera shutter should stay a compact single liquid-glass surface"
        )
        #expect(
            !source.contains("captureRingWidth"),
            "camera shutter should not reintroduce the older ring treatment"
        )
        #expect(
            !source.contains("captureInnerSize"),
            "camera shutter should remain a minimal frosted glass circle instead of an inner/outer target"
        )
        #expect(
            source.contains(".glassEffect(.regular.tint(tint).interactive(isEnabled), in: .circle)"),
            "camera glass controls should use SwiftUI's native interactive liquid-glass circle"
        )
        #expect(
            source.contains("cameraGlassSurface("),
            "camera flashlight, shutter, and switch controls should render as liquid-glass buttons"
        )
        #expect(
            source.contains("accessibilityLabel: \"Flashlight\""),
            "camera flashlight control should expose a stable label after moving glass styling inside the button label"
        )
        #expect(
            source.contains("accessibilityLabel: \"Switch Camera\""),
            "camera switch control should expose a stable label after moving glass styling inside the button label"
        )
        #expect(
            source.contains(".contentShape(Circle())"),
            "camera icon controls should use the full circular hit target instead of only the rendered symbol"
        )
        #expect(
            source.contains("private nonisolated static func turnOffTorchIfNeeded"),
            "camera switching should turn off the active torch before replacing the video input"
        )
        #expect(
            source.contains("previousInputs.compactMap { ($0 as? AVCaptureDeviceInput)?.device }"),
            "camera switching should inspect existing video devices before input replacement"
        )
        #expect(
            source.contains("guard !isConfiguringSession, let captureSession = session else { return }"),
            "torch toggles should not race camera input replacement"
        )
        #expect(
            source.contains("defer { device.unlockForConfiguration() }"),
            "torch configuration should always unlock the AVCaptureDevice after a successful lock"
        )
        #expect(
            !source.contains(".black.opacity(0.68)"),
            "camera sheet should not reintroduce a foreground bottom fade over the live viewport"
        )
        #expect(
            !source.contains(".frame(height: 240)"),
            "camera sheet should not reserve a tall foreground gradient region above the controls"
        )
        #expect(
            !source.contains(#"Text("Take Photo")"#),
            "camera sheet should not reserve a title/header above the immersive viewport"
        )
        #expect(
            !source.contains("let session = AVCaptureSession()"),
            "camera sheet must not eagerly allocate AVCaptureSession before the child sheet is visible"
        )
        #expect(
            !source.contains("private var photoOutput = AVCapturePhotoOutput()"),
            "camera sheet must not eagerly allocate AVCapturePhotoOutput before the child sheet is visible"
        )

        let removeInputRange = try #require(
            source.range(of: "previousInputs.forEach { session.removeInput($0) }"),
            "camera switch should remove the old video input before checking the replacement input"
        )
        let canAddInputRange = try #require(
            source.range(of: "guard session.canAddInput(input) else"),
            "camera switch should validate the replacement input after removing the old one"
        )
        #expect(
            removeInputRange.upperBound < canAddInputRange.lowerBound,
            "camera switch must not call canAddInput while the old camera input is still attached"
        )
    }


    @Test("Primitive shell has no interactive approval plane")
    func testPrimitiveShellHasNoInteractiveApprovalPlane() throws {
        let iosRoot = iosAppRoot()
        let deletedPaths = [
            "Sources/Engine/Events/Core/Plugins/Approval",
            "Sources/Engine/Network/Clients/ApprovalClient.swift",
            "Sources/Session/Chat/Coordinators/EngineApprovalCoordinator.swift",
            "Sources/Session/Chat/State/EngineApprovalState.swift",
            "Sources/UI/EngineApproval",
            "Sources/Session/Timeline/Messages/EngineApprovalTypes.swift",
            "Sources/Engine/Protocol/DTOs/EngineProtocolTypes+Approval.swift",
        ]
        for relativePath in deletedPaths {
            #expect(
                !FileManager.default.fileExists(atPath: iosRoot.appendingPathComponent(relativePath).path),
                "\(relativePath) belongs to the deleted interactive approval plane"
            )
        }

        let forbiddenFragments = [
            "approval::resolve",
            "approval.pending",
            "approval.resolved",
            "approvalPromptMode",
            "AutonomyApprovalPromptMode",
            "EngineApproval",
            "engineApproval",
            "ApprovalClient",
            "approvalPolicy",
            "approvalContract",
            "approvalState",
            "APPROVAL_REQUIRED"
        ]
        let sourcesRoot = iosRoot.appendingPathComponent("Sources")
        guard let enumerator = FileManager.default.enumerator(
            at: sourcesRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            Issue.record("Unable to enumerate iOS sources")
            return
        }
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let content = try String(contentsOf: url, encoding: .utf8)
            for fragment in forbiddenFragments {
                #expect(
                    !content.contains(fragment),
                    "\(url.lastPathComponent) retains deleted approval fragment \(fragment)"
                )
            }
        }
    }


    @Test("Retired audit console stays removed")
    func testRetiredAuditOverviewAndInspectionBoundary() throws {
        let iosRoot = iosAppRoot()
        let deletedPaths = [
            "Sources/UI/" + "Audit" + "Details",
            "Sources/Session/Chat/State/" + "Audit" + "Details" + "State.swift",
            "Sources/Session/Chat/State/" + "Audit" + "Details" + "WorkerPackProjection.swift",
            "Sources/Session/Chat/State/" + "Audit" + "Details" + "WorkerArtifactProjection.swift",
            "Sources/Engine/Network/Clients/CapabilityClient.swift",
        ]
        for relativePath in deletedPaths {
            #expect(
                !FileManager.default.fileExists(atPath: iosRoot.appendingPathComponent(relativePath).path),
                "\(relativePath) belongs to the deleted fixed audit console"
            )
        }

        let forbiddenProductionModulePolicy = [
            "module::act",
            "module::package_action",
            "module::mutate_package",
            "module::configure",
            "module::activate",
            "module::approve_source",
            "module::run_conformance",
            "modulePolicy",
            "packagePolicy",
            "ModulePolicy",
            "PackagePolicy"
        ]
        let sourcesRoot = iosRoot.appendingPathComponent("Sources")
        guard let enumerator = FileManager.default.enumerator(
            at: sourcesRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            Issue.record("Could not enumerate \(sourcesRoot.path)")
            return
        }
        while let any = enumerator.nextObject() {
            guard let url = any as? URL else { continue }
            guard url.pathExtension == "swift" else { continue }
            let content = try String(contentsOf: url, encoding: .utf8)
            for forbidden in forbiddenProductionModulePolicy {
                #expect(
                    !content.contains(forbidden),
                    "\(url.lastPathComponent) must not own module action/policy target `\(forbidden)`"
                )
            }
        }
    }
}
