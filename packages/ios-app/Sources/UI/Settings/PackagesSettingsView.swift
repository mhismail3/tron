import SwiftUI

enum PackageResourceKind: String, CaseIterable, Identifiable, Sendable {
    case extensions, skills, prompts, themes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .extensions: "Extensions"
        case .skills: "Skills"
        case .prompts: "Prompts"
        case .themes: "Themes"
        }
    }

    var icon: String {
        switch self {
        case .extensions: "puzzlepiece.extension.fill"
        case .skills: "sparkles"
        case .prompts: "text.quote"
        case .themes: "paintpalette.fill"
        }
    }

    // Prompt and skill accents are owned by the chat picker and shared with
    // Project Resources. Package extensions retain their purple category hue.
    @MainActor var accent: Color {
        switch self {
        case .extensions: ProjectResourceKind.extensions.accent
        case .skills: ProjectResourceKind.skills.accent
        case .prompts: ProjectResourceKind.prompts.accent
        case .themes: .tronTeal
        }
    }
}

struct PackageResolvedResourceItem: Identifiable, Equatable, Sendable {
    let path: String
    let enabled: Bool
    let source: String?
    let scope: String?
    let origin: String?

    var statusDescription: String { enabled ? "Ready to use" : "Turned off" }

    var id: String { path }

    var displayName: String { ProjectResourceTitlePresentation.resourcePathTitle(path) }

    var sourceDescription: String? {
        if source == "auto" { return "Discovered automatically" }
        if let source, !source.isEmpty { return "From \(source)" }
        return nil
    }
}

struct PackageResolvedResourceCategory: Identifiable, Equatable, Sendable {
    let kind: PackageResourceKind
    let items: [PackageResolvedResourceItem]

    var id: String { kind.id }
    var enabledCount: Int { items.count(where: \.enabled) }
    var disabledCount: Int { items.count - enabledCount }
    var hasSharedSource: Bool { Set(items.map(\.source)).count == 1 }

    var caption: String? {
        guard !items.isEmpty else { return nil }
        let scopes = Set(items.map { $0.scope == "user" ? "global" : $0.scope })
        let scope = switch scopes {
        case ["global"]: "Available in every project."
        case ["project"]: "Available in the current project."
        case ["temporary"]: "Available in this session."
        default: "Source and scope details are available in Technical Details."
        }
        let provenance = hasSharedSource ? items.first?.sourceDescription : nil
        return [provenance, scope].compactMap { $0 }.joined(separator: " · ")
    }

    var summary: String {
        guard !items.isEmpty else { return "None resolved" }
        if disabledCount == 0 {
            return "\(items.count) ready to use"
        }
        return "\(enabledCount) ready · \(disabledCount) turned off"
    }
}

struct PackageResolvedResourcesPresentation: Equatable, Sendable {
    let categories: [PackageResolvedResourceCategory]

    init(resources: JSONValue) {
        let root = resources.objectValue ?? [:]
        // Installed packages already occupy the first section. Do not render
        // their extensions again in the resolved resource lists.
        categories = [PackageResourceKind.skills, .prompts, .themes].map { kind in
            let values = root[kind.rawValue]?.arrayValue ?? []
            let items = values.compactMap { value -> PackageResolvedResourceItem? in
                guard let object = value.objectValue,
                      let path = object["path"]?.stringValue else { return nil }
                let metadata = object["metadata"]?.objectValue
                return PackageResolvedResourceItem(
                    path: path,
                    enabled: object["enabled"]?.boolValue != false,
                    source: metadata?["source"]?.stringValue,
                    scope: metadata?["scope"]?.stringValue,
                    origin: metadata?["origin"]?.stringValue
                )
            }
            return PackageResolvedResourceCategory(kind: kind, items: items)
        }
    }
}

enum PackageInstallDraftPolicy {
    static func afterSuccess(current: String, captured: String) -> String {
        current == captured ? "" : current
    }
}

enum PackageMutationOperation: Hashable {
    case install(String)
    case update(String)
    case remove(String)

    var identity: String {
        switch self {
        case .install(let source): return "install:\(source)"
        case .update(let source): return "update:\(source)"
        case .remove(let source): return "remove:\(source)"
        }
    }
}

struct PackagesSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var presentationActivity
    let projectCWD: String?
    private var target: PackageConfigurationTarget {
        PackageConfigurationTarget(cwd: projectCWD)
    }
    private var inventory: PackageInventory? { model.packageInventory(for: target) }
    private var updates: [PackageUpdate] { model.packageUpdates(for: target) }
    @State private var source = ""
    @State private var local = false
    @State private var packageToRemove: PackageSummary?
    @State private var showingInstall = false
    @State private var reloading = false
    @State private var refreshError: String?
    @State private var mutationErrors: [PackageMutationOperation: String] = [:]
    @State private var refreshGeneration = 0
    @State private var mutationToken = 0
    private struct OwnedMutation {
        let token: Int
        let task: Task<Void, Never>
    }
    @State private var activeMutations: [PackageMutationOperation: OwnedMutation] = [:]

    private var loadID: PackageLoadID {
        PackageLoadID(target: target, profileRevision: model.profileRevision,
                      invalidationGeneration: model.packageInvalidationGeneration,
                      refreshGeneration: refreshGeneration, foregroundGeneration: model.foregroundReconciliationGeneration)
    }

    private var packageError: String? {
        mutationErrors.values.first ?? refreshError
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 18) {
                resolutionSection

                if let packageError {
                    TronSettingsNotice(message: packageError, retry: reload)
                }

                TronSettingsGroup("Installed", surfaceStyle: .glass) {
                    if let packages = inventory?.packages, !packages.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(Array(packages.enumerated()), id: \.element.id) { index, package in
                                if index > 0 { TronSettingsDivider() }
                                packageRow(package)
                            }
                        }
                    } else if packageError == nil {
                        TronPlaceholderState(
                            title: "No packages configured",
                            detail: "Use Reload or install a package below.",
                            icon: "shippingbox"
                        )
                    }
                }

                // Keep installation beside the installed list, without a
                // second heading competing with the package inventory.
                Button { showingInstall = true } label: {
                    TronSettingsRow(
                        icon: "arrow.down.circle.fill",
                        title: "Install Package",
                        accent: .tronEmerald
                    )
                }
                .buttonStyle(.plain)
                .tronGlassSurface(accent: .tronEmerald, tintOpacity: 0.06)
                .tronSettingsCaption("Agent packages and extensions run with your Mac user authority. Review their source before installing.")

                if let resources = inventory?.resources {
                    PackageResolvedResourcesSection(resources: resources)
                        .environment(\.tronSettingsVisualTheme, nil)
                }

            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Packages")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                TronReloadToolbarButton(isReloading: reloading, action: reload)
            }
        }
        .task(id: PresentationActivityTaskID(
            source: loadID,
            presentationActive: presentationActivity.allowsPresentationPublication
        )) {
            await refreshPackages(loadID)
        }
        .onChange(of: target) { _, _ in
            revokeMutationTasks()
            refreshError = nil
        }
        .onChange(of: model.profileRevision) { _, _ in
            revokeMutationTasks()
            refreshError = nil
        }
        .onChange(of: model.packageInvalidationGeneration) { _, _ in
            revokeMutationTasks()
        }
        .onDisappear {
            revokeMutationTasks()
        }
        .tronManagedSheet(
            isPresented: $showingInstall,
            identity: "settings.packages.install"
        ) {
            NavigationStack {
                packageInstallSheet
            }
            .tronTopBlur(.sheet)
            .tronPresentation()
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.hidden)
        }
        .tronManagedSheet(
            item: $packageToRemove,
            identity: { _ in "settings.packages.remove" }
        ) { package in
            TronConfirmationSheet(
                title: "Remove this package?",
                message: package.source,
                confirmTitle: "Remove",
                destructive: true,
                centersTitle: true,
                icon: "shippingbox.and.arrow.down",
                onConfirm: { remove(package) }
            )
        }
    }

    private var resolutionSection: some View {
        TronSettingsGroup(
            "Resource Scope",
            detail: resolutionSummary,
            accent: .tronBlue,
            surfaceStyle: .glass
        ) {
            // Project Trust is one Settings row beside Packages, not repeated here.
            TronValueRow(icon: "scope", title: "Scope", value: projectCWD == nil ? "Global resources" : "Current project")
        }
    }

    private var resolutionSummary: String {
        guard let inventory else { return "Waiting for the Gateway resource projection" }
        let packageCount = inventory.packages.count
        let resourceCount = PackageResolvedResourcesPresentation(resources: inventory.resources).categories.reduce(0) { $0 + $1.items.count }
        return "\(packageCount) installed package\(packageCount == 1 ? "" : "s") · \(resourceCount) resolved resource\(resourceCount == 1 ? "" : "s")"
    }

    private func reload() {
        refreshGeneration &+= 1
    }

    private func refreshPackages(_ request: PackageLoadID) async {
        guard refreshIsCurrent(request) else { return }
        reloading = true
        refreshError = nil
        defer { if refreshIsCurrent(request) { reloading = false } }
        let loaded = await model.loadPackages(target: request.target, surfaceError: false)
        guard refreshIsCurrent(request) else { return }
        guard loaded else {
            // Superseded/coalesced reads have no error to publish.
            refreshError = model.packageError(for: request.target)
            return
        }
        let updatesLoaded = await model.checkPackageUpdates(target: request.target, surfaceError: false)
        guard refreshIsCurrent(request) else { return }
        refreshError = updatesLoaded ? nil : model.packageError(for: request.target)
    }

    private func refreshIsCurrent(_ request: PackageLoadID) -> Bool {
        // A successful foreground/reconnect pass invalidates even a late offline
        // failure. Only reads restart; accepted package commands are not replayed.
        !Task.isCancelled && presentationActivity.allowsPresentationPublication && request == loadID
    }

    private func beginMutation(_ operation: PackageMutationOperation) -> Int {
        activeMutations[operation]?.task.cancel()
        mutationToken &+= 1
        return mutationToken
    }

    private func mutationIsCurrent(
        target requestedTarget: PackageConfigurationTarget,
        operation: PackageMutationOperation,
        token: Int,
        profileRevision: Int,
        invalidationGeneration: Int
    ) -> Bool {
        !Task.isCancelled
            && requestedTarget == target
            && model.profileRevision == profileRevision
            && activeMutations[operation]?.token == token
            && model.packageInvalidationGeneration == invalidationGeneration
    }

    private func finishMutation(
        _ operation: PackageMutationOperation,
        target requestedTarget: PackageConfigurationTarget,
        token: Int,
        profileRevision: Int,
        invalidationGeneration: Int
    ) {
        guard mutationIsCurrent(
            target: requestedTarget,
            operation: operation,
            token: token,
            profileRevision: profileRevision,
            invalidationGeneration: invalidationGeneration
        ) else { return }
        activeMutations[operation] = nil
    }

    private func revokeMutationTasks() {
        for owned in activeMutations.values { owned.task.cancel() }
        activeMutations.removeAll()
        mutationErrors.removeAll()
    }

    private func isMutating(_ package: PackageSummary) -> Bool {
        activeMutations[.update(package.id)] != nil
            || activeMutations[.remove(package.id)] != nil
    }

    private func recordMutationSuccess(_ operation: PackageMutationOperation) {
        mutationErrors[operation] = nil
    }

    private func recordMutationFailure(_ operation: PackageMutationOperation, error: Error) {
        mutationErrors[operation] = error.localizedDescription
    }

    private var packageInstallSheet: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    sheetSectionHeader(
                        "Source",
                        detail: "Use an npm package, Git URL, or local path."
                    )
                    PackageSourceField(source: $source)
                }

                VStack(alignment: .leading, spacing: 8) {
                    sheetSectionHeader(
                        "Install Scope",
                        detail: projectCWD == nil
                            ? "Packages are installed for every project from this screen."
                            : "Choose whether this package is available everywhere or only in the current project."
                    )
                    TronToggleRow(
                        icon: "folder.badge.gearshape",
                        title: "Current project only",
                        accent: .tronEmerald,
                        isOn: $local
                    )
                    .tronGlassSurface(accent: .tronEmerald, tintOpacity: 0.07)
                    .disabled(projectCWD == nil)
                }

                Button("Install Package") { install() }
                    .buttonStyle(TronActionButtonStyle(role: .primary))
                    .disabled(source.isEmpty || activeMutations[.install(source)] != nil)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Install Package")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button { showingInstall = false } label: {
                    Image(systemName: "checkmark")
                        .font(TronTypography.buttonSM)
                        .tronSettingsAccent()
                }
                .accessibilityLabel("Done")
            }
        }
    }

    private func sheetSectionHeader(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: TronSpacing.xs) {
            Text(title)
                .font(TronTypography.sheetSectionHeader)
                .foregroundStyle(Color.tronTextPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(detail)
                .font(TronTypography.caption)
                .foregroundStyle(Color.tronTextMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func packageRow(_ package: PackageSummary) -> some View {
        PackageSourceRow(
            source: package.source,
            detail: [
                package.scope == .project ? "Project" : "Global",
                package.filtered ? "Filtered" : nil,
                updates.contains { $0.id == package.id } ? "Update available" : nil,
            ].compactMap { $0 }.joined(separator: " · "),
            accent: .tronBlue
        ) {
            if isMutating(package) {
                TronPulseLoadingIndicator(size: 18)
            } else {
                Menu {
                    Button("Update", systemImage: "arrow.clockwise") { update(package) }
                    Button("Remove", systemImage: "trash", role: .destructive) { packageToRemove = package }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
            }
        }
    }

    private func install() {
        let value = source
        let operation = PackageMutationOperation.install(value)
        let requestedTarget = target
        let profileRevision = model.profileRevision
        let invalidationGeneration = model.packageInvalidationGeneration
        let token = beginMutation(operation)
        let authoritative = Task { @MainActor in
            try await model.mutatePackage(
                action: .install,
                source: value,
                local: local,
                target: requestedTarget,
                surfaceError: false
            )
        }
        let task = Task { @MainActor in
            defer {
                finishMutation(
                    operation,
                    target: requestedTarget,
                    token: token,
                    profileRevision: profileRevision,
                    invalidationGeneration: invalidationGeneration
                )
            }
            do {
                try await authoritative.value
                guard mutationIsCurrent(
                    target: requestedTarget,
                    operation: operation,
                    token: token,
                    profileRevision: profileRevision,
                    invalidationGeneration: invalidationGeneration
                ) else { return }
                source = PackageInstallDraftPolicy.afterSuccess(current: source, captured: value)
                recordMutationSuccess(operation)
            } catch is CancellationError {
                return
            } catch {
                guard mutationIsCurrent(
                    target: requestedTarget,
                    operation: operation,
                    token: token,
                    profileRevision: profileRevision,
                    invalidationGeneration: invalidationGeneration
                ) else { return }
                recordMutationFailure(operation, error: error)
            }
        }
        activeMutations[operation] = OwnedMutation(token: token, task: task)
    }

    private func update(_ package: PackageSummary) {
        let operation = PackageMutationOperation.update(package.id)
        let requestedTarget = target
        let profileRevision = model.profileRevision
        let invalidationGeneration = model.packageInvalidationGeneration
        let token = beginMutation(operation)
        let authoritative = Task { @MainActor in
            try await model.mutatePackage(
                action: .update,
                source: package.source,
                local: package.scope == .project,
                target: requestedTarget,
                surfaceError: false
            )
        }
        let task = Task { @MainActor in
            defer {
                finishMutation(
                    operation,
                    target: requestedTarget,
                    token: token,
                    profileRevision: profileRevision,
                    invalidationGeneration: invalidationGeneration
                )
            }
            do {
                try await authoritative.value
                guard mutationIsCurrent(
                    target: requestedTarget,
                    operation: operation,
                    token: token,
                    profileRevision: profileRevision,
                    invalidationGeneration: invalidationGeneration
                ) else { return }
                recordMutationSuccess(operation)
            } catch is CancellationError {
                return
            } catch {
                guard mutationIsCurrent(
                    target: requestedTarget,
                    operation: operation,
                    token: token,
                    profileRevision: profileRevision,
                    invalidationGeneration: invalidationGeneration
                ) else { return }
                recordMutationFailure(operation, error: error)
            }
        }
        activeMutations[operation] = OwnedMutation(token: token, task: task)
    }

    private func remove(_ package: PackageSummary) {
        let operation = PackageMutationOperation.remove(package.id)
        let requestedTarget = target
        let profileRevision = model.profileRevision
        let invalidationGeneration = model.packageInvalidationGeneration
        let token = beginMutation(operation)
        packageToRemove = nil
        let authoritative = Task { @MainActor in
            try await model.mutatePackage(
                action: .remove,
                source: package.source,
                local: package.scope == .project,
                target: requestedTarget,
                surfaceError: false
            )
        }
        let task = Task { @MainActor in
            defer {
                finishMutation(
                    operation,
                    target: requestedTarget,
                    token: token,
                    profileRevision: profileRevision,
                    invalidationGeneration: invalidationGeneration
                )
            }
            do {
                try await authoritative.value
                guard mutationIsCurrent(
                    target: requestedTarget,
                    operation: operation,
                    token: token,
                    profileRevision: profileRevision,
                    invalidationGeneration: invalidationGeneration
                ) else { return }
                recordMutationSuccess(operation)
            } catch is CancellationError {
                return
            } catch {
                guard mutationIsCurrent(
                    target: requestedTarget,
                    operation: operation,
                    token: token,
                    profileRevision: profileRevision,
                    invalidationGeneration: invalidationGeneration
                ) else { return }
                recordMutationFailure(operation, error: error)
            }
        }
        activeMutations[operation] = OwnedMutation(token: token, task: task)
    }
}

private struct PackageSourceRow<Trailing: View>: View {
    let source: String
    let detail: String
    let accent: Color
    let trailing: Trailing

    init(source: String, detail: String, accent: Color, @ViewBuilder trailing: () -> Trailing) {
        self.source = source
        self.detail = detail
        self.accent = accent
        self.trailing = trailing()
    }

    var body: some View {
        TronSettingsRow(icon: "shippingbox.fill", title: source, subtitle: detail,
                        titleIsIdentifier: true, accent: accent, subtitleColor: .tronTextSecondary) {
            trailing
        }
        .accessibilityLabel("\(source). \(detail)")
    }
}
