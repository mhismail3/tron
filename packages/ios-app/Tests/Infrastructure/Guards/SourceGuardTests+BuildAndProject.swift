import Testing
import Foundation

extension SourceGuardTests {

    @Test("feedback recipient has no tracked personal default")
    func testFeedbackRecipientConfigDefault() throws {
        let iosRoot = iosAppRoot()
        let baseConfig = try String(
            contentsOf: iosRoot.appendingPathComponent("Configuration/Base.xcconfig"),
            encoding: .utf8
        )
        let line = try #require(
            baseConfig
                .split(separator: "\n")
                .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("TRON_FEEDBACK_EMAIL =") }
        )
        let value = line
            .split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        #expect(value == "")
        #expect(value?.contains("$(") == false)
        #expect(baseConfig.contains("#include? \"Local.xcconfig\""))
        #expect(baseConfig.contains("TRON_MAC_DOWNLOAD_URL = https:/$()/github.com/tron-owner/tron/releases"))
    }


    @Test("settings log viewer remains available in production builds")
    func testSettingsLogViewerAvailableInProductionBuilds() throws {
        let iosRoot = iosAppRoot()

        let settingsView = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/UI/Settings/Shell/SettingsView.swift"),
            encoding: .utf8
        )
        let logViewer = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/UI/System/LogViewer.swift"),
            encoding: .utf8
        )
        let ingestionService = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Support/Diagnostics/ClientLogIngestionService.swift"),
            encoding: .utf8
        )
        let logsClient = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Engine/Transport/Clients/LogsClient.swift"),
            encoding: .utf8
        )
        let dependencyContainer = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Support/Composition/DependencyContainer.swift"),
            encoding: .utf8
        )
        let dependencyProviding = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Support/Composition/DependencyProviding.swift"),
            encoding: .utf8
        )
        let app = try String(
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

        #expect(settingsView.contains("@State private var showLogViewer = false"))
        #expect(settingsView.contains("Button { showLogViewer = true }"))
        #expect(settingsView.contains("LogViewer()"))
        #expect(!settingsView.contains("#if DEBUG || BETA"))
        #expect(!logViewer.hasPrefix("#if DEBUG || BETA"))
        #expect(!logViewer.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("#endif"))
        #expect(!logViewer.contains("exportLogsToServer"))
        #expect(!logViewer.contains("square.and.arrow.up"))
        #expect(logViewer.contains("Server sync is automatic while connected"))
        #expect(ingestionService.contains("ClientLogIngestionPlanner"))
        #expect(ingestionService.contains("ios:client-log-ingest:"))
        #expect(ingestionService.contains("uploadedEntryFingerprints"))
        #expect(ingestionService.contains("visibleEntryFingerprints"))
        #expect(ingestionService.contains("DiagnosticsRedactor"))
        #expect(ingestionService.contains("Task.isCancelled"))
        #expect(ingestionService.contains("uploadTaskSerial"))
        #expect(ingestionService.contains("isSuccessfulIngestionPlumbing"))
        #expect(dependencyContainer.contains("clientLogIngestionService.start()"))
        #expect(dependencyContainer.contains("clientLogIngestionService.updateEndpoint(Self.makeClientLogIngestionEndpoint(client: newClient))"))
        #expect(dependencyContainer.contains("private(set) var engineClient: EngineClient"))
        #expect(!dependencyProviding.contains("var engineClient: EngineClient { get }"))
        #expect(app.contains("container.clientLogIngestionService.handleConnectionChange"))
        #expect(app.contains("container.clientLogIngestionService.handleScenePhaseChange"))
        #expect(logsClient.contains("func ingestLogs(entries: [ClientLogEntry], idempotencyKey: EngineIdempotencyKey) async throws -> LogsIngestResult"))
        #expect(!logsClient.contains("getDiagnostics"))
        #expect(!logsClient.contains("system::get_diagnostics"))
        #expect(!logsClient.contains("SystemDiagnosticsResult"))

        let ingestStart = try #require(logsClient.range(of: "func ingestLogs(entries: [ClientLogEntry]"))
        let ingestBlock = logsClient[ingestStart.lowerBound..<logsClient.endIndex]
        #expect(!ingestBlock.contains("#if DEBUG || BETA"))
        #expect(!ingestBlock.contains("logger.info"))

        #expect(architectureDoc.contains("The settings toolbar exposes Logs in every build configuration."))
        #expect(architectureDoc.contains("mirrors bounded client logs into the server `logs` table"))
        #expect(architectureDoc.contains("self-feeding diagnostics loop"))
        #expect(rootReadme.contains("Settings also exposes the Logs sheet in every iOS build configuration"))
        #expect(rootReadme.contains("automatically ingests deduplicated client logs"))
        #expect(rootReadme.contains("self-feeding diagnostics loops"))
    }


    @Test("paired-server tokens stay in Keychain and diagnostics redact auth fields")
    func testSecretStorageAndRedactionBoundaries() throws {
        let iosRoot = iosAppRoot()

        let pairedServerStore = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Support/Pairing/PairedServerStore.swift"),
            encoding: .utf8
        )
        let pairedServerTokenStore = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Support/Storage/PairedServerTokenStore.swift"),
            encoding: .utf8
        )
        let keychainItem = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Support/Storage/KeychainItem.swift"),
            encoding: .utf8
        )
        let dependencyContainer = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Support/Composition/DependencyContainer.swift"),
            encoding: .utf8
        )
        let redactor = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Support/Diagnostics/DiagnosticsRedactor.swift"),
            encoding: .utf8
        )
        let logger = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Support/Diagnostics/TronLogger.swift"),
            encoding: .utf8
        )
        let networkFormatter = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Engine/Transport/Retry/NetworkDiagnosticsFormatter.swift"),
            encoding: .utf8
        )

        let serverStructStart = try #require(pairedServerStore.range(of: "struct PairedServer"))
        let serverStructEnd = try #require(pairedServerStore.range(of: "/// iOS-local source of truth"))
        let serverStruct = pairedServerStore[serverStructStart.lowerBound..<serverStructEnd.lowerBound]
        #expect(!serverStruct.contains("token"))
        #expect(!serverStruct.contains("authorization"))
        #expect(!serverStruct.contains("apiKey"))
        #expect(pairedServerStore.contains("defaults.set(data, forKey: Self.serversKey)"))
        #expect(pairedServerStore.contains("defaults.set(activeServerId, forKey: Self.activeIdKey)"))

        #expect(pairedServerTokenStore.contains("KeychainItem("))
        #expect(pairedServerTokenStore.contains("static let keychainServicePrefix = \"com.tron.mobile.bearer\""))
        #expect(!pairedServerTokenStore.contains("UserDefaults"))
        #expect(keychainItem.contains("kSecClassGenericPassword"))
        #expect(keychainItem.contains("kSecAttrAccessibleAfterFirstUnlock"))
        #expect(keychainItem.contains("**Access group:** intentionally unset"))

        #expect(dependencyContainer.contains("Self.resolveBearerToken(tokenStore: tokenStore)"))
        #expect(dependencyContainer.contains("UserDefaults.standard.string(forKey: PairedServerStore.activeIdKey)"))
        #expect(dependencyContainer.contains("UserDefaults.standard.data(forKey: PairedServerStore.serversKey)"))
        #expect(dependencyContainer.contains("return tokenStore.token(forServerId: activeId)"))
        #expect(!dependencyContainer.contains(#"UserDefaults.standard.string(forKey: "bearer"#))
        #expect(!dependencyContainer.contains(#"UserDefaults.standard.string(forKey: "token"#))

        for required in [
            "accessToken",
            "refreshToken",
            "clientSecret",
            "authorizationCode",
            "swiftDescriptionTokenRegex",
        ] {
            #expect(redactor.contains(required), "DiagnosticsRedactor missing auth redaction marker: \(required)")
        }
        #expect(logger.contains("DiagnosticsRedactor().redactMessage(message())"))
        #expect(networkFormatter.contains(#"authorization=\(authState)"#))
        #expect(!networkFormatter.contains(#"value(forHTTPHeaderField: "Authorization") ??"#))
        #expect(!networkFormatter.contains("Bearer \\("))
    }


    @Test("DependencyProviding stays concrete-engine-client free")
    func testDependencyProvidingDoesNotExposeEngineClient() throws {
        let iosRoot = iosAppRoot()
        let protocolSource = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Support/Composition/DependencyProviding.swift"),
            encoding: .utf8
        )
        #expect(!protocolSource.contains("var engineClient: EngineClient { get }"))
        #expect(protocolSource.contains("var diagnosticsEngineEndpoint: DiagnosticsEngineEndpoint { get }"))
        #expect(protocolSource.contains("var chatSessionServices: ChatSessionServices { get }"))

        var leaks: [String] = []
        for root in ["Sources/UI", "Sources/Session"] {
            let rootURL = iosRoot.appendingPathComponent(root)
            for url in try swiftFiles(in: rootURL) {
                let source = try String(contentsOf: url, encoding: .utf8)
                guard source.contains("dependencies.engineClient") else { continue }
                let relative = url.path.replacingOccurrences(of: iosRoot.path + "/", with: "")
                leaks.append(relative)
            }
        }
        #expect(
            leaks.isEmpty,
            "UI and Session must use repository/session service dependencies, not dependencies.engineClient: \(leaks.joined(separator: ", "))"
        )
    }


    @Test("fast production scheme keeps prod identity with debug build settings")
    func testFastProductionSchemeUsesProdIdentityAndDebugSettings() throws {
        let iosRoot = iosAppRoot()

        let projectYML = try String(
            contentsOf: iosRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        let prodDebugConfig = try String(
            contentsOf: iosRoot.appendingPathComponent("Configuration/ProdDebug.xcconfig"),
            encoding: .utf8
        )
        let developmentDoc = try String(
            contentsOf: iosRoot.appendingPathComponent("docs/development.md"),
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

        #expect(projectYML.contains("ProdDebug: Configuration/ProdDebug.xcconfig"))
        #expect(projectYML.contains("ProdDebug: debug"))
        #expect(projectYML.contains("Tron Fast:"))
        #expect(projectYML.contains("config: ProdDebug"))
        #expect(projectYML.contains("CODE_SIGN_ENTITLEMENTS: TronMobileProd.entitlements"))
        #expect(projectYML.contains("CODE_SIGN_ENTITLEMENTS: ShareExtension/ShareExtensionProd.entitlements"))

        #expect(prodDebugConfig.contains("SWIFT_OPTIMIZATION_LEVEL = -Onone"))
        #expect(prodDebugConfig.contains("ENABLE_TESTABILITY = YES"))
        #expect(prodDebugConfig.contains("ONLY_ACTIVE_ARCH = YES"))
        #expect(prodDebugConfig.contains("SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG"))
        #expect(!prodDebugConfig.contains("BETA"))
        #expect(prodDebugConfig.contains("PRODUCT_BUNDLE_IDENTIFIER = com.tron.mobile"))
        #expect(prodDebugConfig.contains("ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon"))

        #expect(developmentDoc.contains("Tron Fast"))
        #expect(architectureDoc.contains("ProdDebug"))
        #expect(rootReadme.contains("Tron Fast"))
    }


    @Test("Codex iPhone actions rebuild and install production variants")
    func testCodexIPhoneActionsRebuildAndInstallProductionVariants() throws {
        let iosRoot = iosAppRoot()
        let repoRoot = iosRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let environment = try String(
            contentsOf: repoRoot.appendingPathComponent(".codex/environments/environment.toml"),
            encoding: .utf8
        )
        let installScript = try String(
            contentsOf: repoRoot.appendingPathComponent("scripts/tron-ios-beta"),
            encoding: .utf8
        )
        let developmentDoc = try String(
            contentsOf: iosRoot.appendingPathComponent("docs/development.md"),
            encoding: .utf8
        )
        let rootReadme = try String(
            contentsOf: repoRoot.appendingPathComponent("README.md"),
            encoding: .utf8
        )

        #expect(environment.contains(#"name = "Rebuild + Install + Launch iOS Beta on iPhone""#))
        #expect(environment.contains(#"name = "Rebuild + Install + Launch iOS Prod Fast Debug on iPhone""#))
        #expect(environment.contains("TRON_IOS_DEVICE_NAME=iPhone"))
        #expect(environment.contains(#"TRON_IOS_SCHEME='Tron Fast'"#))
        #expect(environment.contains("TRON_IOS_CONFIGURATION=ProdDebug"))
        #expect(environment.contains("scripts/tron-ios-beta install"))
        #expect(environment.contains(#"name = "Rebuild + Install + Launch iOS Prod Release on iPhone""#))
        #expect(environment.contains("TRON_IOS_SCHEME=Tron"))
        #expect(environment.contains("TRON_IOS_CONFIGURATION=Prod scripts/tron-ios-beta install"))
        #expect(environment.contains(#"name = "Just Launch Installed iOS Beta on iPhone""#))
        #expect(environment.contains(#"name = "Just Launch Installed iOS Prod on iPhone""#))
        #expect(!environment.contains(#"name = "Just Launch Installed iOS Prod Fast on iPhone""#))
        #expect(environment.contains("TRON_IOS_CONFIGURATION=Prod scripts/tron-ios-beta launch"))

        var actionNames: [String] = []
        var inAction = false
        for line in environment.split(separator: "\n").map(String.init) {
            if line == "[[actions]]" {
                inAction = true
                continue
            }
            if line.hasPrefix("[") && line != "[[actions]]" {
                inAction = false
            }
            if inAction && line.hasPrefix(#"name = ""#) && line.hasSuffix(#"""#) {
                let name = line
                    .dropFirst(#"name = ""#.count)
                    .dropLast()
                actionNames.append(String(name))
            }
        }
        #expect(Set(actionNames).count == actionNames.count)
        #expect(actionNames
            .filter { $0.hasPrefix("Rebuild") }
            .allSatisfy { $0.hasPrefix("Rebuild + Install + Launch") })
        #expect(actionNames
            .filter { $0.hasPrefix("Just Launch Installed iOS Prod") }
            == ["Just Launch Installed iOS Prod on iPhone"])

        #expect(installScript.contains(#"SCHEME="${TRON_IOS_SCHEME:-Tron Beta}""#))
        #expect(installScript.contains(#"CONFIG="${TRON_IOS_CONFIGURATION:-Beta}""#))
        #expect(installScript.contains("TRON_IOS_SCHEME"))
        #expect(installScript.contains("TRON_IOS_CONFIGURATION"))
        #expect(installScript.contains(#"app="$DERIVED_DATA/Build/Products/${CONFIG}-iphoneos/TronMobile.app""#))
        #expect(!installScript.contains(#"find "$DERIVED_DATA/Build/Products" -name "TronMobile.app" -path "*iphoneos*" -type d | head -1"#))

        #expect(developmentDoc.contains("Rebuild + Install + Launch iOS Prod Fast Debug on iPhone"))
        #expect(developmentDoc.contains("Rebuild + Install + Launch iOS Prod Release on iPhone"))
        #expect(developmentDoc.contains("Just Launch Installed"))
        #expect(developmentDoc.contains("deduplicated by bundle ID"))
        #expect(developmentDoc.contains("installs the requested configuration's `iphoneos`"))
        #expect(rootReadme.contains("Rebuild + Install + Launch"))
        #expect(rootReadme.contains("Just Launch Installed"))
        #expect(rootReadme.contains("deduplicated production"))
        #expect(rootReadme.contains("installs the requested configuration's `iphoneos`"))
    }


    @Test("iOS 26 cleanup hooks stay removed")
    func testIOS26CleanupHooksStayRemoved() throws {
        let iosRoot = iosAppRoot()
        let sourcesRoot = iosRoot.appendingPathComponent("Sources")
        let forbiddenNeedles: [(String, String)] = [
            ("if #available(iOS 26.0, *)", "runtime iOS 26 availability gate"),
            ("ASPresentationAnchor(frame:", "presentation-anchor workaround"),
            ("+ Text(", "Text concatenation"),
        ]
        let chipStyleStrokeRegex = try NSRegularExpression(
            pattern: #"(?s)\.chipStyle\s*\([^)]*strokeOpacity\s*:"#,
            options: []
        )

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
            for (needle, reason) in forbiddenNeedles {
                #expect(
                    !content.contains(needle),
                    "\(url.lastPathComponent) contains removed \(reason)"
                )
            }

            let chipStyleStrokeMatches = chipStyleStrokeRegex.matches(
                in: content,
                range: NSRange(location: 0, length: (content as NSString).length)
            )
            #expect(
                chipStyleStrokeMatches.isEmpty,
                "\(url.lastPathComponent) routes removed chipStyle strokeOpacity compatibility through the glass-only API"
            )
        }
    }
}
