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


    @Test("Audit Details product console stays removed")
    func testAuditDetailsOverviewAndInspectionBoundary() throws {
        let iosRoot = iosAppRoot()
        let deletedPaths = [
            "Sources/UI/AuditDetails",
            "Sources/Session/Chat/State/AuditDetailsState.swift",
            "Sources/Session/Chat/State/AuditDetailsWorkerPackProjection.swift",
            "Sources/Session/Chat/State/AuditDetailsWorkerArtifactProjection.swift",
            "Sources/Engine/Network/Clients/CapabilityClient.swift",
        ]
        for relativePath in deletedPaths {
            #expect(
                !FileManager.default.fileExists(atPath: iosRoot.appendingPathComponent(relativePath).path),
                "\(relativePath) belongs to the deleted fixed Audit Details console"
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
