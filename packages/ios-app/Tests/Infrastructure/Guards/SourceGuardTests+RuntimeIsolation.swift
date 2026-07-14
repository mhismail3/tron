import Testing
import Foundation

extension SourceGuardTests {

    @Test("hosted bootstrap cannot construct production or fixture state")
    func testHostedBootstrapOwnsNoProductionOrFixtureState() throws {
        let iosRoot = iosAppRoot()
        let wrapper = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/App/Lifecycle/TronMobileApp.swift"),
            encoding: .utf8
        )
        let runtime = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/App/Lifecycle/AppRuntimeMode.swift"),
            encoding: .utf8
        )
        let productionRoot = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/App/Lifecycle/ProductionAppRoot.swift"),
            encoding: .utf8
        )

        #expect(wrapper.contains("private let productionRoot: ProductionAppRoot?"))
        #expect(wrapper.contains("if AppRuntimeMode.current.runsApplicationLifecycle"))
        #expect(wrapper.contains("productionRoot = ProductionAppRoot()"))
        #expect(wrapper.contains("productionRoot = nil"))
        #expect(wrapper.contains("Color.clear"))
        for forbidden in [
            "DependencyContainer(",
            "EventDatabase(",
            "UserDefaults.",
            "@AppStorage",
            "NotificationCenter.",
            "MetricKitDiagnosticsStore",
            "EngineConnection(",
        ] {
            #expect(!wrapper.contains(forbidden), "TronMobileApp wrapper owns \(forbidden)")
        }

        for forbidden in [
            "UserDefaults",
            "FileManager",
            "HostedTestSuiteLifecycle",
            "CleanupRegistry",
            "atexit",
            "TRON_APP_RUNTIME_MODE",
        ] {
            #expect(!runtime.contains(forbidden), "runtime-mode owner contains \(forbidden)")
        }

        #expect(productionRoot.contains("@State private var container: DependencyContainer"))
        #expect(productionRoot.contains("init(container: DependencyContainer = DependencyContainer())"))
        #expect(productionRoot.contains("container.clientLogIngestionService.handleScenePhaseChange"))
        #expect(productionRoot.contains("await registerPushIfAuthorized()"))
    }

    @Test("live lifecycle effects stay lazy behind runtime guards")
    func testLiveLifecycleEffectsStayLazy() throws {
        let source = try String(
            contentsOf: iosAppRoot().appendingPathComponent("Sources/App/Lifecycle/AppDelegate.swift"),
            encoding: .utf8
        )

        #expect(source.contains("installNotificationDelegate: { delegate in\n                UNUserNotificationCenter.current().delegate = delegate"))
        #expect(source.contains("startMetricKit: {\n                MetricKitDiagnosticsStore.shared.start()"))
        #expect(source.contains("logTokenIssued: {\n                TronLogger.shared.info"))
        #expect(source.contains("guard runtimeMode.runsApplicationLifecycle else { return true }"))
        #expect(occurrences(of: "guard runtimeMode.runsApplicationLifecycle else { return }", in: source) == 2)
        #expect(!source.contains("let notificationCenter = UNUserNotificationCenter.current()"))
        #expect(!source.contains("let metricKit = MetricKitDiagnosticsStore.shared"))
        #expect(!source.contains("let logger = TronLogger.shared"))
    }

    @Test("tests use registered isolated state and explicit storage seams")
    func testTestsUseRegisteredIsolatedState() throws {
        let iosRoot = iosAppRoot()
        let testsRoot = iosRoot.appendingPathComponent("Tests")
        var violations: [String] = []

        for url in try swiftFiles(in: testsRoot) where !isSourceGuardFile(url) {
            let relativePath = url.path.replacingOccurrences(of: iosRoot.path + "/", with: "")
            let source = try String(contentsOf: url, encoding: .utf8)
            violations.append(contentsOf: isolationViolations(in: source, path: relativePath))
        }

        #expect(
            violations.isEmpty,
            "iOS test-state isolation violations:\n\(violations.sorted().joined(separator: "\n"))"
        )
    }

    @Test("test-state isolation ratchet accepts the fixture path")
    func testIsolationRatchetAcceptsSafeSyntheticSource() {
        let safe = """
        IsolatedTestState.withDefaults(label: "first") { firstDefaults in
            IsolatedTestState.withDefaults(label: "second") { secondDefaults in
                let first = DeviceInstallationIdentity.current(defaults: firstDefaults)
                let second = DeviceInstallationIdentity.current(defaults: secondDefaults)
            }
        }
        IsolatedTestState.withState(label: "safe") { state in
            let container = state.makeContainer()
            await container.connect()
            await container.manualRetry()
            container.selectPairedServer(server)
            _ = try container.forgetPairedServer(server)
            let database = state.makeDatabase()
            let history = InputHistoryStore(defaults: state.defaults)
            let appearance = AppearanceSettings(defaults: state.defaults)
            let font = FontSettings(defaults: state.defaults)
            let manager = EventStoreManager(eventDB: database, engineClient: client, defaults: state.defaults)
        }
        let client = EngineClient(
            serverURL: url,
            sessionAttemptDirective: { _ in .handledFailure }
        )
        let repository = DefaultAppConnectionRepository(client: client)
        await repository.connect()
        await client.reconnect()
        @Test func connects() async {
            let connection = EngineConnection(
                serverURL: url,
                sessionAttemptDirective: { _ in .handledFailure }
            )
            await connection.connect()
        }
        """
        #expect(isolationViolations(in: safe, path: "Tests/SyntheticSafe.swift").isEmpty)
    }

    @Test("test-state isolation ratchet ignores constructor names embedded in longer identifiers")
    func testIsolationRatchetIgnoresConstructorNamesEmbeddedInLongerIdentifiers() {
        let safe = "func test_container_providesEventStoreManager() {}"

        #expect(isolationViolations(in: safe, path: "Tests/SyntheticSafe.swift").isEmpty)
    }

    @Test("test-state isolation ratchet rejects every owned debt class")
    func testIsolationRatchetRejectsSyntheticViolations() {
        let cases: [(source: String, diagnostic: String)] = [
            ("let value = UserDefaults.standard", "standard defaults"),
            ("let value = UserDefaults . standard", "standard defaults"),
            ("let value = UserDefaults()", "raw defaults constructor"),
            ("let value = UserDefaults ( )", "raw defaults constructor"),
            ("let value = UserDefaults(suiteName: name)", "raw defaults suite"),
            ("let value = UserDefaults ( suiteName : name )", "raw defaults suite"),
            ("let value = UserDefaults.init(suiteName: name)", "raw defaults suite"),
            ("let value = UserDefaults . init ( suiteName : name )", "raw defaults suite"),
            ("let value = DependencyContainer(storage: storage)", "direct DependencyContainer construction"),
            ("let value = EventDatabase()", "zero-argument EventDatabase"),
            ("let value = InputHistoryStore()", "zero-argument InputHistoryStore"),
            ("let value = AppearanceSettings.shared", "shared AppearanceSettings"),
            ("let value = FontSettings.shared", "shared FontSettings"),
            ("let value = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)", "Documents lookup"),
            ("let value = IsolatedTestState.registeredDefaults(label: \"escaping\")", "escaping registered defaults"),
            ("let value = EventStoreManager(eventDB: database, engineClient: client)", "EventStoreManager missing explicit defaults"),
            (
                "@Test func connects() async { let connection = EngineConnection(serverURL: url); await connection.connect() }",
                "EngineConnection connect missing session-attempt directive"
            ),
            (
                "@Test func retries() async { let connection = EngineConnection(serverURL: url); await connection.manualRetry() }",
                "EngineConnection retry missing session-attempt directive"
            ),
            (
                "let client = EngineClient(serverURL: url)\nlet alias = client\nawait alias.connect()",
                "EngineClient connect missing handled session-attempt directive"
            ),
            (
                "let client = EngineClient(serverURL: url)\nawait client.reconnect()",
                "EngineClient reconnect missing handled session-attempt directive"
            ),
            (
                "let client = EngineClient(serverURL: url)\nlet repository = DefaultAppConnectionRepository(client: client)\nawait repository.manualRetry()",
                "repository attempt derives from live EngineClient"
            ),
            (
                "let container = DependencyContainer(storage: storage)\nawait container.connect()",
                "container connect derives from direct composition"
            ),
            (
                "let container = DependencyContainer(storage: storage)\nawait container.manualRetry()",
                "container retry derives from direct composition"
            ),
            (
                "let container = DependencyContainer(storage: storage)\ncontainer.selectPairedServer(server)",
                "server switch can connect from direct composition"
            ),
            (
                "let container = DependencyContainer(storage: storage)\ncontainer.selectPairedServer(server, connectAfterSwitch: true)",
                "server switch can connect from direct composition"
            ),
            (
                "let container = DependencyContainer(storage: storage)\ntry container.forgetPairedServer(server)",
                "forget can reconnect from direct composition"
            ),
            ("let probe = URLSessionPairingProbe()", "live pairing probe in hosted tests"),
            ("let listener = OAuthLoopbackServer()", "live OAuth listener in hosted tests"),
            ("let listener = NWListener(using: .tcp)", "NWListener in hosted tests"),
            ("let store = PairedServerTokenStore()", "production PairedServerTokenStore in hosted tests"),
            ("let item = KeychainItem(service: \"s\", account: \"a\")", "KeychainItem in hosted tests"),
            ("let status = SecItemDelete(query)", "SecItem API in hosted tests"),
            (
                "Task { [weak self] in\n guard let self else { return }\n for await event in stream {}\n}",
                "strong self spans idle event stream"
            ),
            (
                "ownedTask?.cancel()\nreturn",
                "owned task cancellation is not awaited"
            ),
            (
                "await database.close()\nawait manager.shutdown()",
                "database closes before manager shutdown"
            ),
        ]

        for testCase in cases {
            let violations = isolationViolations(
                in: testCase.source,
                path: "Tests/SyntheticViolation.swift"
            )
            #expect(
                violations.contains(where: { $0.contains(testCase.diagnostic) }),
                "missing synthetic diagnostic `\(testCase.diagnostic)` in \(violations)"
            )
        }
    }

    @Test("session-attempt directive precedes all live URLSession construction")
    func testSessionAttemptDirectivePrecedesLiveSessionConstruction() throws {
        let source = try String(
            contentsOf: iosAppRoot().appendingPathComponent(
                "Sources/Engine/Transport/WebSocket/EngineConnection.swift"
            ),
            encoding: .utf8
        )
        let directive = try #require(source.range(of: "sessionAttemptDirective(request)"))
        for liveMarker in [
            "URLSessionConfiguration.default",
            "EngineConnectionSessionDelegate(owner: self)",
            "let session = URLSession(",
            "session.webSocketTask(with: request)",
            "task.resume()",
        ] {
            let live = try #require(source.range(of: liveMarker))
            #expect(directive.lowerBound < live.lowerBound, "\(liveMarker) precedes test directive")
        }
        #expect(source.contains("sessionAttemptDirective: @escaping (URLRequest) -> EngineSessionAttemptDirective = { _ in"))
        #expect(source.contains(".openLiveSession"))
    }

    @Test("runtime I/O policy survives every client composition and keeps production live")
    func testRuntimeIOPolicyPropagation() throws {
        let root = iosAppRoot()
        let client = try String(
            contentsOf: root.appendingPathComponent("Sources/Engine/Transport/WebSocket/EngineClient.swift"),
            encoding: .utf8
        )
        let runtime = try String(
            contentsOf: root.appendingPathComponent("Sources/Support/Composition/DependencyContainer+RuntimeServices.swift"),
            encoding: .utf8
        )
        let container = try String(
            contentsOf: root.appendingPathComponent("Sources/Support/Composition/DependencyContainer.swift"),
            encoding: .utf8
        )
        let fixture = try String(
            contentsOf: root.appendingPathComponent("Tests/Infrastructure/Fixtures/IsolatedTestState.swift"),
            encoding: .utf8
        )

        #expect(client.contains("private let sessionAttemptDirective: (URLRequest) -> EngineSessionAttemptDirective"))
        #expect(client.contains("sessionAttemptDirective: sessionAttemptDirective"))
        #expect(runtime.contains("static func production() -> Self"))
        #expect(runtime.contains("sessionAttemptDirective: { _ in .openLiveSession }"))
        #expect(runtime.contains("pairedServerTokenStore: PairedServerTokenStore()"))
        #expect(runtime.contains("makePairingProbe: { URLSessionPairingProbe() }"))
        #expect(container.contains("private let runtimeIO: DependencyContainerRuntimeIO"))
        #expect(occurrences(of: "sessionAttemptDirective: runtimeIO.sessionAttemptDirective", in: container) == 2)
        #expect(container.contains("pairedServerTokenStore = runtimeIO.pairedServerTokenStore"))
        #expect(container.contains("lazy var pairingProbe: any PairingProbing = runtimeIO.makePairingProbe()"))
        #expect(fixture.contains("sessionAttemptDirective: { [attemptRecorder] request in"))
        #expect(fixture.contains("pairedServerTokenStore: tokenBackend.makeStore()"))
        #expect(fixture.contains("makePairingProbe: { pairingProbe }"))
        #expect(!runtime.contains("TRON_APP_RUNTIME_MODE"))
    }

    @Test("event and fixture terminal owners cancel, await, and close database last")
    func testTerminalOwnershipShapeAndOrder() throws {
        let root = iosAppRoot()
        let manager = try String(
            contentsOf: root.appendingPathComponent("Sources/Engine/Persistence/Sync/EventStoreManager.swift"),
            encoding: .utf8
        )
        let refresh = try String(
            contentsOf: root.appendingPathComponent("Sources/Engine/Persistence/Sync/SessionRefreshService.swift"),
            encoding: .utf8
        )
        let fixture = try String(
            contentsOf: root.appendingPathComponent("Tests/Infrastructure/Fixtures/IsolatedTestState.swift"),
            encoding: .utf8
        )

        let loop = try #require(manager.range(of: "for await event in stream"))
        let strongSelf = try #require(manager.range(of: "guard let self else { return }", range: loop.lowerBound..<manager.endIndex))
        #expect(loop.lowerBound < strongSelf.lowerBound)
        #expect(manager.contains("await predecessor?.value"))
        #expect(manager.contains("await self.acceptedEventHook(event)"))
        #expect(manager.contains("await self.handleGlobalEventV2(event)"))
        #expect(manager.contains("globalTask?.cancel()"))
        #expect(manager.contains("await globalTask?.value"))
        #expect(manager.contains("await refreshCoordinator.shutdown()"))
        #expect(manager.contains("loadTask?.cancel()"))
        #expect(manager.contains("await loadTask?.value"))
        #expect(!manager.contains("_eventStream.finish"))

        #expect(refresh.contains("isStopped = true"))
        #expect(refresh.contains("connectionManager?.cancelHook(label: Self.hookLabel)"))
        #expect(refresh.contains("pendingDebounceTask?.cancel()"))
        #expect(refresh.contains("acceptedInflightTask?.cancel()"))
        #expect(refresh.contains("await pendingDebounceTask?.value"))
        #expect(refresh.contains("await acceptedInflightTask?.value"))

        let managerShutdown = try #require(fixture.range(of: "await manager.shutdown()"))
        let tokenCleanup = try #require(fixture.range(of: "ownedTokenBackends.forEach { $0.cleanup() }"))
        let databaseClose = try #require(fixture.range(of: "await database.close()"))
        let fileRemoval = try #require(
            fixture.range(of: "FileManager.default.removeItem(at: rootURL)", range: databaseClose.lowerBound..<fixture.endIndex)
        )
        let defaultsCleanup = try #require(fixture.range(of: "suiteLifecycle.cleanup()", range: fileRemoval.lowerBound..<fixture.endIndex))
        #expect(managerShutdown.lowerBound < tokenCleanup.lowerBound)
        #expect(tokenCleanup.lowerBound < databaseClose.lowerBound)
        #expect(databaseClose.lowerBound < fileRemoval.lowerBound)
        #expect(fileRemoval.lowerBound < defaultsCleanup.lowerBound)
    }

    private func isolationViolations(in source: String, path: String) -> [String] {
        let fixturePath = "Tests/Infrastructure/Fixtures/IsolatedTestState.swift"
        var violations: [String] = []

        if path != fixturePath {
            if matches(#"\bUserDefaults\s*\.\s*standard\b"#, in: source) {
                violations.append("\(path): standard defaults")
            }
            if matches(#"\bUserDefaults\s*\(\s*\)"#, in: source) {
                violations.append("\(path): raw defaults constructor")
            }
            if matches(#"\bUserDefaults\s*\(\s*suiteName\s*:"#, in: source)
                || matches(#"\bUserDefaults\s*\.\s*init\s*\(\s*suiteName\s*:"#, in: source) {
                violations.append("\(path): raw defaults suite")
            }
        }
        if path != fixturePath, source.contains("IsolatedTestState.registeredDefaults(") {
            violations.append("\(path): escaping registered defaults")
        }

        let zeroArgumentPatterns: [(String, String)] = [
            (#"\bEventDatabase\s*\(\s*\)"#, "zero-argument EventDatabase"),
            (#"\bInputHistoryStore\s*\(\s*\)"#, "zero-argument InputHistoryStore"),
        ]
        for (pattern, diagnostic) in zeroArgumentPatterns where matches(pattern, in: source) {
            violations.append("\(path): \(diagnostic)")
        }

        for (needle, diagnostic) in [
            ("AppearanceSettings.shared", "shared AppearanceSettings"),
            ("FontSettings.shared", "shared FontSettings"),
            (".documentDirectory", "Documents lookup"),
        ] where source.contains(needle) {
            violations.append("\(path): \(diagnostic)")
        }

        for arguments in callArguments(named: "EventStoreManager", in: source)
        where !arguments.contains("defaults:") {
            violations.append("\(path): EventStoreManager missing explicit defaults")
        }

        if path != fixturePath {
            if matches(#"\bDependencyContainer\s*\("#, in: source) {
                violations.append("\(path): direct DependencyContainer construction")
            }
            for (pattern, diagnostic) in [
                (#"\bURLSession\s*\("#, "URLSession in hosted tests"),
                (#"\bURLSessionPairingProbe\s*\("#, "live pairing probe in hosted tests"),
                (#"\bOAuthLoopbackServer\s*\("#, "live OAuth listener in hosted tests"),
                (#"\bNWListener\s*\("#, "NWListener in hosted tests"),
                (#"\bPairedServerTokenStore\s*\("#, "production PairedServerTokenStore in hosted tests"),
                (#"\bKeychainItem\s*\("#, "KeychainItem in hosted tests"),
                (#"\bSecItem(?:Add|Update|Delete|CopyMatching)\s*\("#, "SecItem API in hosted tests"),
            ] where matches(pattern, in: source) {
                violations.append("\(path): \(diagnostic)")
            }
        }

        violations.append(contentsOf: networkAttemptViolations(in: source, path: path))
        violations.append(contentsOf: terminalOwnershipViolations(in: source, path: path))

        return violations
    }

    private func terminalOwnershipViolations(in source: String, path: String) -> [String] {
        guard path.contains("Synthetic") else { return [] }
        var violations: [String] = []
        if let loop = source.range(of: "for await"),
           let strongSelf = source.range(of: "guard let self"),
           strongSelf.lowerBound < loop.lowerBound {
            violations.append("\(path): strong self spans idle event stream")
        }
        if let cancellation = source.range(of: #"\b([A-Za-z_][A-Za-z0-9_]*)\?*\.cancel\s*\(\)"#, options: .regularExpression) {
            let statement = String(source[cancellation])
            let owner = statement.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if !source.contains("await \(owner)?.value") && !source.contains("await \(owner).value") {
                violations.append("\(path): owned task cancellation is not awaited")
            }
        }
        if let close = source.range(of: "await database.close()"),
           let shutdown = source.range(of: "await manager.shutdown()"),
           close.lowerBound < shutdown.lowerBound {
            violations.append("\(path): database closes before manager shutdown")
        }
        return violations
    }

    private func callArguments(named name: String, in source: String) -> [String] {
        let token = "\(name)("
        var result: [String] = []
        var searchStart = source.startIndex

        while let call = source.range(of: token, range: searchStart..<source.endIndex) {
            if call.lowerBound > source.startIndex {
                let previous = source[source.index(before: call.lowerBound)]
                if previous.isLetter || previous.isNumber || previous == "_" {
                    searchStart = call.upperBound
                    continue
                }
            }
            let open = source.index(before: call.upperBound)
            var cursor = source.index(after: open)
            var depth = 1
            while cursor < source.endIndex, depth > 0 {
                switch source[cursor] {
                case "(": depth += 1
                case ")": depth -= 1
                default: break
                }
                if depth == 0 {
                    result.append(String(source[source.index(after: open)..<cursor]))
                    searchStart = source.index(after: cursor)
                    break
                }
                cursor = source.index(after: cursor)
            }
            if depth > 0 { break }
        }
        return result
    }

    private func matches(_ pattern: String, in source: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        return expression.firstMatch(
            in: source,
            range: NSRange(location: 0, length: (source as NSString).length)
        ) != nil
    }

    private func occurrences(of needle: String, in source: String) -> Int {
        source.components(separatedBy: needle).count - 1
    }

    private func sourceBlock(
        in source: String,
        startingWith start: String,
        endingWith end: String
    ) -> String? {
        guard let startRange = source.range(of: start),
              let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex)
        else { return nil }
        return String(source[startRange.lowerBound..<endRange.upperBound])
    }
}
