import Testing
import Foundation

extension SourceGuardTests {

    @Test("Thin client retains generic shell anchors")
    func testThinClientRetainsGenericShellAnchors() throws {
        let iosRoot = iosAppRoot()
        let required: [String: [String]] = [
            "Sources/App/Lifecycle/TronMobileApp.swift": [
                "ContentView(",
                "OnboardingFlowView",
            ],
            "Sources/Support/Pairing/PairingURLParser.swift": [
                "PairingURLParser",
                "PairingHostValidator",
                "canonicalHost",
            ],
            "Sources/Support/Pairing/Onboarding/PairingPersistor.swift": [
                "RollbackPlan",
                "RollbackTokenAction",
                "previousToken",
            ],
            "Sources/Support/Storage/PairedServerTokenStore.swift": [
                "KeychainItem(",
                "keychainServicePrefix",
            ],
            "Sources/Session/Chat/State/SettingsState.swift": [
                "lastLoadedSettings",
                "rollbackToLastLoadedSettings",
                "resetToDefaults",
            ],
            "Sources/Session/Timeline/Reconstruction/UnifiedEventTransformer.swift": [
                "transformPersistedEvents",
                "CapabilityInvocationMapResult",
            ],
            "Sources/UI/RuntimeSurfaces/GeneratedRuntimeSurfaceView.swift": [
                "GeneratedRuntimeSurfaceView",
                "submit(actionId:",
            ],
            "Sources/Engine/Protocol/Core/FailurePayload.swift": [
                "CanonicalFailurePayload",
                "fromDetails",
            ],
            "Sources/Engine/Transport/Retry/NetworkDiagnosticsFormatter.swift": [
                "redactedURLSummary",
                "requestSummary",
            ],
            "Sources/Engine/Transport/Clients/LogsClient.swift": [
                "logs::ingest",
                "ingestLogs",
            ],
        ]

        for (relativePath, needles) in required {
            let content = try String(
                contentsOf: iosRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            for needle in needles {
                #expect(
                    content.contains(needle),
                    "\(relativePath) must retain generic thin-shell anchor `\(needle)`"
                )
            }
        }
    }

    @Test("Deleted product shell boundaries stay absent from ordinary iOS source")
    func testDeletedProductShellBoundariesStayAbsent() throws {
        let iosRoot = iosAppRoot()
        let deletedRoots = [
            "Sources/UI/RepositoryPanels",
            "Sources/UI/AssistantManagement",
            "Sources/UI/ExtensionSources",
            "Sources/UI/MediaWorkflows",
            "Sources/UI/PromptQueue",
            "Sources/UI/HookSuggestions",
            "Sources/UI/Memory",
            "Sources/UI/Rules",
            "Sources/UI/Skills",
            "Sources/Engine/Transport/Clients/ProductClients",
            "Sources/Session/ProductState",
            "Tests/UI/RepositoryPanels",
            "Tests/UI/AssistantManagement",
            "Tests/UI/PromptQueue",
            "Tests/UI/HookSuggestions",
        ]

        for relativePath in deletedRoots {
            #expect(
                !FileManager.default.fileExists(atPath: iosRoot.appendingPathComponent(relativePath).path),
                "\(relativePath) is a deleted product-specific shell boundary"
            )
        }

        let forbiddenNeedles: [(String, String)] = [
            ("Repository" + "Panel", "repository-specific panel"),
            ("Repository" + "Workflow", "repository workflow model"),
            ("Assistant" + "Management", "assistant-management panel"),
            ("Assistant" + "Panel", "assistant product panel"),
            ("Extension" + "Source", "extension-source surface"),
            ("Audio" + "Transcription", "audio transcription product surface"),
            ("Media" + "Workflow", "media workflow surface"),
            ("Memory" + "Retain", "memory-retain panel"),
            ("Rules" + "Panel", "rules panel"),
            ("Skills" + "Panel", "skills panel"),
            ("Prompt" + "Queue", "prompt queue root"),
            ("Hook" + "Suggestion", "hook suggestion root"),
            ("Product" + "Client", "product-specific client"),
            ("Product" + "State", "product-specific state"),
            ("Product" + "Panel", "product-specific panel"),
            ("Plugin" + "Sources", "plugin-source settings panel"),
            ("Voice" + "Notes", "voice notes product surface"),
        ]

        let sourceRoots = [
            iosRoot.appendingPathComponent("Sources"),
            iosRoot.appendingPathComponent("Tests"),
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

    @Test("Thin client boundary docs stay aligned with source guards")
    func testThinClientBoundaryDocsStayAlignedWithSourceGuards() throws {
        let iosRoot = iosAppRoot()
        let repoRoot = iosRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let architecture = try String(
            contentsOf: iosRoot.appendingPathComponent("docs/architecture.md"),
            encoding: .utf8
        )
        let events = try String(
            contentsOf: iosRoot.appendingPathComponent("docs/events.md"),
            encoding: .utf8
        )
        let onboarding = try String(
            contentsOf: iosRoot.appendingPathComponent("docs/onboarding.md"),
            encoding: .utf8
        )
        let readme = try String(
            contentsOf: repoRoot.appendingPathComponent("README.md"),
            encoding: .utf8
        )

        for required in [
            "fixed product panels are teardown targets",
            "Pairing accepts only bare DNS names",
            "GeneratedRuntimeSurfaceView",
            "CanonicalFailurePayload",
            "Server settings shown in the iOS settings UI are snapshots",
        ] {
            #expect(
                architecture.contains(required) || events.contains(required) || onboarding.contains(required) || readme.contains(required),
                "thin-client docs must retain boundary text: `\(required)`"
            )
        }

        #expect(readme.contains("packages/agent/docs/ios-thin-client-generic-runtime-shell-scorecard.md"))
        #expect(readme.contains("packages/agent/tests/ios_thin_client_generic_runtime_shell_invariants.rs"))
    }
}
