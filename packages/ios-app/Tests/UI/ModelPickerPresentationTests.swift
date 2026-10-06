import SwiftUI
@testable import TronMobileCore
import XCTest
@testable import TronMobile

/// Hosted presentation of the organized model picker.
///
/// This SwiftUI version paints `Text` without `UILabel` and exposes no
/// `accessibilityElements`, so the evidence here is the set of elements the
/// mounted picker actually installs: the hosted probe attaches to the real
/// search action, every provider header, and every rail card / provider row, and
/// installs and retires with that element's own mount lifecycle. Section
/// ordering and rail admission are owned by `ModelPickerSearchTests`; the
/// light/dark captures are this layout's retained visual artifact. Hosted-sheet
/// checks do not establish physical-device visual acceptance.
@MainActor
final class ModelPickerPresentationTests: XCTestCase {
    private var currentAppModel: AppModel?

    private static let catalog: [ModelSummary] = [
        summary("anthropic", "claude-opus-5", "Claude Opus 5", releaseDate: "2026-01-01"),
        summary("anthropic", "claude-opus-4-5", "Claude Opus 4.5 (latest)", releaseDate: "2025-11-01"),
        summary("anthropic", "claude-opus-4-5-20251101", "Claude Opus 4.5", releaseDate: "2025-11-01"),
        summary("anthropic", "claude-haiku-4-6", "Claude Haiku 4.6", cost: ModelTokenPrice(input: 0.8, output: 4)),
        summary("openai", "gpt-5", "GPT 5", releaseDate: "2025-10-01"),
        summary("openai", "gpt-5-mini", "GPT 5 Mini", cost: nil),
        summary("beta", "beta-hidden", "Beta Hidden", available: false, releaseDate: "2025-09-01"),
    ]

    private static let undatedCatalog = catalog.map {
        summary($0.provider, $0.id, $0.name, available: $0.available, cost: $0.cost)
    }

    /// The Gateway's history, newest first. One entry has no release date, so
    /// only the Recent rail can account for its card.
    private static let recents = [
        RecentModelRef(provider: "openai", id: "gpt-5", lastUsedAt: "2026-02-01T00:00:00Z"),
        RecentModelRef(provider: "anthropic", id: "claude-haiku-4-6", lastUsedAt: "2026-01-15T00:00:00Z"),
    ]

    func testRailsAndProviderSectionsMountForLightAndDark() async throws {
        for scheme in [ColorScheme.light, .dark] {
            resetSharedExpansion()
            let probe = ModelPickerHostedProbe()
            var selection: ModelRef? = ModelRef(provider: "anthropic", id: "claude-opus-4-5")
            try await withPicker(
                selection: Binding(get: { selection }, set: { selection = $0 }),
                probe: probe,
                scheme: scheme
            ) { controller in
                XCTAssertTrue(probe.contains("picker.search"))

                // Both rails mount: undated models can only come from the
                // Recent rail, dated ones from the Latest rail, and a model in
                // neither rail mounts no card at all.
                XCTAssertTrue(probe.contains("picker.card.anthropic/claude-haiku-4-6"),
                              "Recent: \(self.mountedProbeIDs(probe))")
                XCTAssertTrue(probe.contains("picker.card.openai/gpt-5"))
                XCTAssertTrue(probe.contains("picker.card.anthropic/claude-opus-5"))
                XCTAssertTrue(probe.contains("picker.card.anthropic/claude-opus-4-5"))
                XCTAssertFalse(probe.contains("picker.card.anthropic/claude-opus-4-5-20251101"),
                               "the pinned release stays out of the Latest rail")

                // The selected provider leads, expanded, below the portrait
                // rails. Rows below the fold are lazily unmounted, so section
                // membership beyond the first screen is owned by the policy
                // suite and the collapsed-section test below.
                XCTAssertTrue(probe.contains("picker.provider.anthropic"))
                XCTAssertFalse(probe.contains("picker.provider.beta"),
                               "an unavailable model never creates a provider section")
                XCTAssertTrue(probe.contains("picker.row.anthropic/claude-opus-5"))
                XCTAssertTrue(probe.contains("picker.row.anthropic/claude-opus-4-5-20251101"),
                              "the pinned release is still selectable in the provider section")

                self.capture(controller, name: "model-picker-sections-\(scheme == .dark ? "dark" : "light")")
            }
        }
    }

    func testProviderExpansionTogglesAndSurvivesTheNextPicker() async throws {
        resetSharedExpansion()
        defer { resetSharedExpansion() }
        let probe = ModelPickerHostedProbe()
        var selection: ModelRef? = ModelRef(provider: "anthropic", id: "claude-opus-5")
        // No rails, so both provider sections fit on the first screen.
        try await withPicker(
            selection: Binding(get: { selection }, set: { selection = $0 }),
            probe: probe,
            models: Self.undatedCatalog,
            recents: []
        ) { controller in
            XCTAssertTrue(probe.activate("picker.provider.openai"))
            try await self.waitForMount("picker.row.openai/gpt-5", probe: probe, in: controller)
            XCTAssertTrue(probe.activate("picker.provider.openai"))
            try await self.waitForUnmount("picker.row.openai/gpt-5", probe: probe, in: controller)

            // The selected provider's own section collapses too.
            XCTAssertTrue(probe.activate("picker.provider.anthropic"))
            try await self.waitForUnmount("picker.row.anthropic/claude-opus-4-5", probe: probe, in: controller)
            // Capture the settled layout, not a frame of the 0.34 s disclosure.
            try await Task.sleep(for: .milliseconds(450))
            self.capture(controller, name: "model-picker-anthropic-collapsed")
        }

        // A remembered collapse survives the next presentation of the picker.
        let next = ModelPickerHostedProbe()
        var nextSelection: ModelRef? = ModelRef(provider: "anthropic", id: "claude-opus-5")
        try await withPicker(
            selection: Binding(get: { nextSelection }, set: { nextSelection = $0 }),
            probe: next,
            models: Self.undatedCatalog,
            recents: []
        ) { controller in
            try await self.settle()
            XCTAssertFalse(next.contains("picker.row.anthropic/claude-opus-4-5"),
                           "a remembered collapse survives the next picker")
            XCTAssertFalse(next.contains("picker.row.openai/gpt-5"))
        }
    }

    /// Performance guard: an expanded provider's rows are separate lazy
    /// children, so a long section builds only what is on screen. Before the
    /// rows were flattened, the whole section mounted as one child.
    func testLongProviderSectionMountsOnlyVisibleRows() async throws {
        resetSharedExpansion()
        defer { resetSharedExpansion() }
        let probe = ModelPickerHostedProbe()
        let long = (0..<60).map { Self.summary("bulk", "bulk-\($0)", "Bulk Model \($0)", cost: nil) }
        var selection: ModelRef? = ModelRef(provider: "bulk", id: "bulk-0")
        try await withPicker(
            selection: Binding(get: { selection }, set: { selection = $0 }),
            probe: probe,
            models: long,
            recents: []
        ) { _ in
            try await self.settle()
            XCTAssertTrue(probe.contains("picker.row.bulk/bulk-0"))
            let mounted = long.filter { probe.contains("picker.row.\($0.provider)/\($0.id)") }.count
            XCTAssertLessThan(mounted, 30, "only on-screen rows mount; \(mounted) of 60 mounted")
        }
    }

    func testSearchHidesRailsAndShowsEveryMatch() async throws {
        resetSharedExpansion()
        defer { resetSharedExpansion() }
        let probe = ModelPickerHostedProbe()
        var selection: ModelRef?
        try await withPicker(selection: Binding(get: { selection }, set: { selection = $0 }), probe: probe) { controller in
            XCTAssertTrue(probe.activate("picker.search"))
            let field = try await self.searchField(in: controller)
            field.text = "gpt"
            field.sendActions(for: .editingChanged)
            try await self.waitForMount("picker.row.openai/gpt-5", probe: probe, in: controller)
            // Rails and non-matching sections animate out with the query.
            try await self.waitForUnmount("picker.card.openai/gpt-5", probe: probe, in: controller)
            try await self.waitForUnmount("picker.provider.anthropic", probe: probe, in: controller)

            XCTAssertFalse(probe.contains("picker.card.openai/gpt-5"),
                           "search replaces both rails: \(self.mountedProbeIDs(probe))")
            XCTAssertFalse(probe.contains("picker.provider.anthropic"),
                           "a provider with no match is omitted")
            XCTAssertTrue(probe.contains("picker.row.openai/gpt-5-mini"),
                          "every match in a section shows while searching")

            field.text = "nothing-matches-this"
            field.sendActions(for: .editingChanged)
            try await self.waitForUnmount("picker.row.openai/gpt-5", probe: probe, in: controller)

            field.text = ""
            field.sendActions(for: .editingChanged)
            try await self.waitForMount("picker.card.openai/gpt-5", probe: probe, in: controller)
            XCTAssertFalse(probe.contains("picker.row.openai/gpt-5"),
                           "clearing the query restores the remembered collapse")
            self.capture(controller, name: "model-picker-search-restored")
        }
    }

    /// Manage Session and New Session open the picker at a content-fit detent:
    /// exactly the toolbar and both rails, stopping before the first provider
    /// header. The picker measures inside a NavigationStack and the detent is
    /// applied outside it, so the sheet must actually open at the published
    /// height. The retained capture is the visual check.
    func testOpeningDetentFitsBothRails() async throws {
        resetSharedExpansion()
        defer { resetSharedExpansion() }
        let probe = ModelPickerHostedProbe()
        var selection: ModelRef? = ModelRef(provider: "anthropic", id: "claude-opus-4-5")
        try await withPicker(
            selection: Binding(get: { selection }, set: { selection = $0 }),
            probe: probe,
            scheme: .dark,
            detents: nil
        ) { controller in
            XCTAssertTrue(probe.contains("picker.card.openai/gpt-5"))
            try await Task.sleep(for: .milliseconds(500))
            let fit = try XCTUnwrap(ModelPickerSheetFixture<EmptyView>.publishedFitHeight,
                                    "the picker never published a fit height")
            // The published value is the visible sheet height the rails need.
            XCTAssertEqual(controller.view.bounds.height, fit, accuracy: 2,
                           "the sheet did not open at the rails' height")
            self.capture(controller, name: "model-picker-fit-detent")
        }
    }

    /// Picking a model from another provider must not reorder sections or flip
    /// their default expansion under the finger: order and defaults follow the
    /// selection the picker opened with.
    func testSelectingAnotherProviderKeepsSectionsInPlace() async throws {
        resetSharedExpansion()
        defer { resetSharedExpansion() }
        let probe = ModelPickerHostedProbe()
        var selection: ModelRef? = ModelRef(provider: "anthropic", id: "claude-opus-5")
        try await withPicker(
            selection: Binding(get: { selection }, set: { selection = $0 }),
            probe: probe,
            models: Self.undatedCatalog,
            recents: Self.recents
        ) { controller in
            try await self.waitForMount("picker.row.anthropic/claude-opus-5", probe: probe, in: controller)
            XCTAssertTrue(probe.activate("picker.card.openai/gpt-5"))
            try await Task.sleep(for: .milliseconds(450))
            XCTAssertEqual(selection, ModelRef(provider: "openai", id: "gpt-5"))
            XCTAssertTrue(probe.contains("picker.row.anthropic/claude-opus-5"),
                          "the opening provider collapsed after picking another provider's model")
            XCTAssertFalse(probe.contains("picker.row.openai/gpt-5"),
                           "an untouched provider expanded after a pick")
        }
    }

    /// A Recent rail that reorders or gains cards while open moves cards under
    /// the finger; the picker holds the list it first showed.
    func testRecentRailHoldsWhileOpen() async throws {
        resetSharedExpansion()
        defer { resetSharedExpansion() }
        let probe = ModelPickerHostedProbe()
        var selection: ModelRef? = ModelRef(provider: "anthropic", id: "claude-opus-5")
        try await withPicker(
            selection: Binding(get: { selection }, set: { selection = $0 }),
            probe: probe,
            models: Self.undatedCatalog,
            recents: Self.recents
        ) { controller in
            try await self.waitForMount("picker.card.anthropic/claude-haiku-4-6", probe: probe, in: controller)
            let model = try XCTUnwrap(self.currentAppModel)
            model.installHostedRecentModels([
                RecentModelRef(provider: "openai", id: "gpt-5-mini", lastUsedAt: "2026-03-01T00:00:00Z"),
            ])
            try await self.settle()
            XCTAssertFalse(probe.contains("picker.card.openai/gpt-5-mini"),
                           "a recent-list change rebuilt the open rail")
            XCTAssertTrue(probe.contains("picker.card.anthropic/claude-haiku-4-6"))
        }
    }

    /// The Gateway rejects model changes while a session works; the picker
    /// must not accept a pick it cannot keep.
    func testLockedPickerIgnoresSelection() async throws {
        resetSharedExpansion()
        defer { resetSharedExpansion() }
        let probe = ModelPickerHostedProbe()
        var selection: ModelRef? = ModelRef(provider: "anthropic", id: "claude-opus-5")
        try await withPicker(
            selection: Binding(get: { selection }, set: { selection = $0 }),
            probe: probe,
            selectionLockedReason: "Model changes are available when the session is idle."
        ) { _ in
            try await self.settle()
            _ = probe.activate("picker.card.openai/gpt-5")
            try await self.settle()
            XCTAssertEqual(selection, ModelRef(provider: "anthropic", id: "claude-opus-5"))
        }
    }

    func testRailCardSelectionWritesTheModelRef() async throws {
        resetSharedExpansion()
        defer { resetSharedExpansion() }
        let probe = ModelPickerHostedProbe()
        var selection: ModelRef?
        try await withPicker(selection: Binding(get: { selection }, set: { selection = $0 }), probe: probe) { controller in
            XCTAssertTrue(probe.activate("picker.card.anthropic/claude-haiku-4-6"),
                          "the Recent rail exposes a mounted action for every model")
            try await self.settle()
            XCTAssertEqual(selection, ModelRef(provider: "anthropic", id: "claude-haiku-4-6"))
            self.capture(controller, name: "model-picker-rail-selection")
        }
    }

    // MARK: - Fixtures

    private static func summary(
        _ provider: String,
        _ id: String,
        _ name: String,
        available: Bool = true,
        releaseDate: String? = nil,
        cost: ModelTokenPrice? = ModelTokenPrice(input: 5, output: 25)
    ) -> ModelSummary {
        ModelSummary(
            provider: provider,
            id: id,
            name: name,
            reasoning: true,
            input: ["text"],
            contextWindow: 200_000,
            maxTokens: 32_000,
            available: available,
            releaseDate: releaseDate,
            cost: cost
        )
    }

    /// The picker reads the app's device preference. Each fixture run starts
    /// from "nothing remembered" so an earlier run cannot decide this one.
    private func resetSharedExpansion() {
        ModelProviderExpansionStore.shared.resetForHostedTest()
    }

    private func withPicker(
        selection: Binding<ModelRef?>,
        probe: ModelPickerHostedProbe,
        scheme: ColorScheme = .light,
        models: [ModelSummary] = ModelPickerPresentationTests.catalog,
        recents: [RecentModelRef] = ModelPickerPresentationTests.recents,
        detents: Set<PresentationDetent>? = [.large],
        selectionLockedReason: String? = nil,
        inspect: (UIViewController) async throws -> Void
    ) async throws {
        let suiteName = "model-picker-presentation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let cacheURL = FileManager.default.temporaryDirectory.appending(path: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: cacheURL)
        }
        let model = AppModel(
            client: GatewayClient(),
            profiles: GatewayProfileStore(defaults: defaults),
            cache: SnapshotCache(root: cacheURL)
        )
        model.installHostedRecentModels(recents)
        XCTAssertNil(model.profiles.selected, "the fixture device is unpaired, so the preference key is the unpaired one")
        currentAppModel = model
        defer { currentAppModel = nil }
        // The app owns selection as SwiftUI state, so a pick re-renders the
        // picker; a plain captured variable would hide selection-driven layout.
        let content = NavigationStack {
            ModelPickerSelectionOwner(
                initial: selection.wrappedValue,
                sink: { selection.wrappedValue = $0 },
                models: models,
                selectionLockedReason: selectionLockedReason
            )
        }
        .tronNavigationTitle("Models", accent: .tronPurple)
        .environment(model)
        .environment(\.modelPickerHostedProbe, probe)
        .preferredColorScheme(scheme)
        try await withSheet(content, detents: detents, inspect: inspect)
    }

    // MARK: - Reading the mounted sheet

    private func mountedProbeIDs(_ probe: ModelPickerHostedProbe) -> [String] {
        ["picker.search", "picker.provider.anthropic", "picker.provider.openai", "picker.provider.beta"]
            + ModelPickerPresentationTests.catalog.map {
                probe.contains("picker.card.\($0.provider)/\($0.id)") ? "card:\($0.provider)/\($0.id)" : nil
            }.compactMap { $0 }
            + ModelPickerPresentationTests.catalog.map {
                probe.contains("picker.row.\($0.provider)/\($0.id)") ? "row:\($0.provider)/\($0.id)" : nil
            }.compactMap { $0 }
    }

    private func withSheet<Sheet: View>(
        _ sheet: Sheet,
        detents: Set<PresentationDetent>?,
        inspect: (UIViewController) async throws -> Void
    ) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let appeared = expectation(description: "Sheet appeared")
        let host = UIHostingController(rootView: ModelPickerSheetFixture(content: sheet.onAppear { appeared.fulfill() }, detents: detents))
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await awaitHostedEvents([appeared])
        let presented = try XCTUnwrap(host.presentedViewController)
        if let transition = presented.transitionCoordinator {
            let completed = expectation(description: "Sheet transition completed")
            if transition.animate(alongsideTransition: nil, completion: { _ in completed.fulfill() }) {
                try await awaitHostedEvents([completed])
            }
        }
        presented.view.layoutIfNeeded()
        try await settle()
        var failure: Error?
        do { try await inspect(presented) } catch { failure = error }
        await withCheckedContinuation { continuation in
            host.dismiss(animated: false) { continuation.resume() }
        }
        if let failure { throw failure }
    }

    private func settle() async throws {
        for _ in 0..<5 {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    private func waitForMount(
        _ id: String,
        probe: ModelPickerHostedProbe,
        in controller: UIViewController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try await wait(id, probe: probe, in: controller, mounted: true, file: file, line: line)
    }

    private func waitForUnmount(
        _ id: String,
        probe: ModelPickerHostedProbe,
        in controller: UIViewController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try await wait(id, probe: probe, in: controller, mounted: false, file: file, line: line)
    }

    private func wait(
        _ id: String,
        probe: ModelPickerHostedProbe,
        in controller: UIViewController,
        mounted: Bool,
        file: StaticString,
        line: UInt
    ) async throws {
        for _ in 0..<60 {
            controller.view.layoutIfNeeded()
            if probe.contains(id) == mounted { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail(
            "\(id) never \(mounted ? "mounted" : "unmounted"). Mounted: \(mountedProbeIDs(probe))",
            file: file,
            line: line
        )
    }

    private func searchField(in controller: UIViewController) async throws -> UITextField {
        for _ in 0..<60 {
            controller.view.layoutIfNeeded()
            if let field = views(of: UITextField.self, in: controller.view).first { return field }
            try await Task.sleep(for: .milliseconds(25))
        }
        return try XCTUnwrap(nil as UITextField?, "The search field never mounted")
    }

    private func views<T: UIView>(of type: T.Type, in root: UIView) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { views(of: type, in: $0) }
    }

    private func capture(_ controller: UIViewController, name: String) {
        guard let window = controller.view.window else { return XCTFail("Capture requires a mounted sheet") }
        let origin = controller.view.convert(controller.view.bounds, to: window).origin
        let image = UIGraphicsImageRenderer(size: controller.view.bounds.size).image { context in
            context.cgContext.translateBy(x: -origin.x, y: -origin.y)
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor
private struct ModelPickerSelectionOwner: View {
    @State private var selection: ModelRef?
    let sink: (ModelRef?) -> Void
    let models: [ModelSummary]
    let selectionLockedReason: String?

    init(initial: ModelRef?, sink: @escaping (ModelRef?) -> Void, models: [ModelSummary], selectionLockedReason: String?) {
        _selection = State(initialValue: initial)
        self.sink = sink
        self.models = models
        self.selectionLockedReason = selectionLockedReason
    }

    var body: some View {
        ModelPicker(selection: $selection, models: models, selectionLockedReason: selectionLockedReason)
            .onChange(of: selection) { _, value in sink(value) }
    }
}

private struct ModelPickerSheetFixture<Content: View>: View {
    let content: Content
    /// nil applies the production content-fit policy.
    var detents: Set<PresentationDetent>? = [.large]
    @State private var presented = true
    /// Latest height the picker published through the real preference path.
    nonisolated(unsafe) static var publishedFitHeight: CGFloat? {
        get { FitHeightRecord.value }
        set { FitHeightRecord.value = newValue }
    }

    var body: some View {
        Color.tronBackground.sheet(isPresented: $presented) {
            if let detents {
                content.presentationDetents(detents)
            } else {
                content
                    .onPreferenceChange(TronSheetFitHeightKey.self) { value in
                        if let value { FitHeightRecord.value = value.rounded() }
                    }
                    .tronContentFitDetents()
            }
        }
    }
}

private enum FitHeightRecord {
    nonisolated(unsafe) static var value: CGFloat?
}
