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
}

struct PackageResolvedResourceItem: Identifiable, Equatable, Sendable {
    let path: String
    let enabled: Bool
    let source: String?
    let scope: String?
    let origin: String?

    var id: String { path }

    var displayName: String {
        let url = URL(fileURLWithPath: path)
        if url.lastPathComponent == "SKILL.md" {
            return url.deletingLastPathComponent().lastPathComponent
        }
        return url.lastPathComponent.isEmpty ? path : url.lastPathComponent
    }

    var sourceDescription: String {
        let scopeLabel = switch scope {
        case "project": "Current project"
        case "temporary": "This session"
        default: "Every project"
        }
        if origin == "package", let source, !source.isEmpty {
            return "From \(source) · \(scopeLabel)"
        }
        if source == "auto" { return "Discovered automatically · \(scopeLabel)" }
        if let source, !source.isEmpty { return "From \(source) · \(scopeLabel)" }
        return scopeLabel
    }
}

struct PackageResolvedResourceCategory: Identifiable, Equatable, Sendable {
    let kind: PackageResourceKind
    let items: [PackageResolvedResourceItem]
    let rawValue: JSONValue

    var id: String { kind.id }
    var enabledCount: Int { items.count(where: \.enabled) }
    var disabledCount: Int { items.count - enabledCount }

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
    let additionalCategoryCount: Int

    init(resources: JSONValue) {
        let root = resources.objectValue ?? [:]
        let knownKeys = Set(PackageResourceKind.allCases.map(\.rawValue))
        additionalCategoryCount = root.keys.count(where: { !knownKeys.contains($0) })
        categories = PackageResourceKind.allCases.compactMap { kind in
            guard let rawValue = root[kind.rawValue], let values = rawValue.arrayValue else { return nil }
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
            return PackageResolvedResourceCategory(kind: kind, items: items, rawValue: rawValue)
        }
    }

    var totalCount: Int { categories.reduce(0) { $0 + $1.items.count } }
    var enabledCount: Int { categories.reduce(0) { $0 + $1.enabledCount } }
    var disabledCount: Int { totalCount - enabledCount }
    var populatedCategoryCount: Int { categories.count(where: { !$0.items.isEmpty }) }

    var overview: String {
        guard totalCount > 0 else {
            return additionalCategoryCount == 0
                ? "No package resources are currently resolved."
                : "Additional technical resource data is available below."
        }
        let typeLabel = populatedCategoryCount == 1 ? "resource type" : "resource types"
        let availability: String
        if disabledCount == 0 {
            availability = "All are ready to use."
        } else {
            let ready = "\(enabledCount) \(enabledCount == 1 ? "is" : "are") ready to use"
            let disabled = "\(disabledCount) \(disabledCount == 1 ? "is" : "are") turned off"
            availability = "\(ready) and \(disabled)."
        }
        let additional = additionalCategoryCount == 0
            ? ""
            : " Additional technical resource data is available below."
        return "\(totalCount) resources across \(populatedCategoryCount) \(typeLabel). \(availability)\(additional)"
    }
}

enum PackageResourceSummaryPolicy {
    static func summary(for resources: JSONValue) -> String {
        let presentation = PackageResolvedResourcesPresentation(resources: resources)
        guard presentation.totalCount > 0 else {
            return presentation.additionalCategoryCount == 0
                ? "No resources resolved"
                : "Additional resource details"
        }
        let known = presentation.additionalCategoryCount == 0 ? "" : " known"
        return "\(presentation.totalCount)\(known) resolved resource\(presentation.totalCount == 1 ? "" : "s")"
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

    private var packageError: String? {
        mutationErrors.values.first ?? refreshError
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 18) {
                if let packageError {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(packageError, systemImage: "exclamationmark.triangle")
                            .font(TronTypography.bodySM)
                            .foregroundStyle(Color.tronTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Retry", action: reload)
                            .buttonStyle(TronRowButtonStyle(accent: .tronAmber))
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tronGlassSurface(
                        accent: .tronAmber,
                        tintOpacity: 0.09,
                        respectsSettingsTheme: false
                    )
                }

                TronSettingsGroup("Installed", surfaceStyle: .scrollOptimized) {
                    if let packages = inventory?.packages, !packages.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(Array(packages.enumerated()), id: \.element.id) { index, package in
                                if index > 0 { TronSettingsDivider() }
                                packageRow(package)
                            }
                        }
                    } else if packageError == nil {
                        VStack(spacing: 10) {
                            Image(systemName: "shippingbox").font(TronTypography.sans(size: TronTypography.sizeXL, weight: .semibold))
                            Text("No packages configured").font(TronTypography.headline)
                            Text("Use Reload or install a package below.")
                                .font(TronTypography.bodySM)
                                .foregroundStyle(Color.tronTextPrimary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    }
                }

                TronSettingsGroup("Install", detail: "Use an npm package, Git URL, or local path.", accent: .tronEmerald) {
                    Button { showingInstall = true } label: {
                        TronSettingsRow(
                            icon: "arrow.down.circle.fill",
                            title: "Install Package",
                            subtitle: "Enter a package source and choose its scope.",
                            accent: .tronEmerald
                        )
                    }
                    .buttonStyle(.plain)
                }

                if let resources = inventory?.resources {
                    let summary = PackageResourceSummaryPolicy.summary(for: resources)
                    TronSettingsGroup("Resolved Resources", accent: .tronTeal) {
                        TronProgressiveSheetLink(
                            accessibilityLabel: "Inspect resolved resources, \(summary)"
                        ) {
                            PackageResolvedResourcesView(resources: resources)
                        } label: {
                            TronValueRow(
                                icon: "magnifyingglass.circle.fill",
                                title: "Inspect Resolved Resources",
                                value: summary,
                                accent: .tronTeal
                            )
                        }
                    }
                }

                TronInfoCard(
                    icon: "exclamationmark.shield",
                    text: "Agent packages and extensions run with your Mac user authority. Review their source before installing.",
                    accent: .tronAmber
                )
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
            source: PackageLoadID(
                target: target,
                profileRevision: model.profileRevision,
                invalidationGeneration: model.packageInvalidationGeneration,
                refreshGeneration: refreshGeneration
            ),
            presentationActive: presentationActivity.allowsPresentationPublication
        )) {
            guard presentationActivity.allowsPresentationPublication else { return }
            let requestedTarget = target
            let profileRevision = model.profileRevision
            let generation = refreshGeneration
            let invalidationGeneration = model.packageInvalidationGeneration
            await refreshPackages(
                target: requestedTarget,
                profileRevision: profileRevision,
                generation: generation,
                invalidationGeneration: invalidationGeneration
            )
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
                confirmTitle: "Remove Package",
                destructive: true,
                icon: "shippingbox.and.arrow.down",
                onConfirm: { remove(package) }
            )
        }
    }

    private func reload() {
        refreshGeneration &+= 1
    }

    private func refreshPackages(
        target requestedTarget: PackageConfigurationTarget,
        profileRevision: Int,
        generation: Int,
        invalidationGeneration: Int
    ) async {
        guard refreshIsCurrent(
            target: requestedTarget,
            profileRevision: profileRevision,
            generation: generation,
            invalidationGeneration: invalidationGeneration
        ) else { return }
        reloading = true
        refreshError = nil
        defer {
            if refreshIsCurrent(
                target: requestedTarget,
                profileRevision: profileRevision,
                generation: generation,
                invalidationGeneration: invalidationGeneration
            ) {
                reloading = false
            }
        }
        let loaded = await model.loadPackages(target: requestedTarget, surfaceError: false)
        guard refreshIsCurrent(
            target: requestedTarget,
            profileRevision: profileRevision,
            generation: generation,
            invalidationGeneration: invalidationGeneration
        ) else { return }
        guard loaded else {
            // A false result without coordinator error means this request was
            // superseded or coalesced; it is not a user-visible failure.
            guard let error = model.packageError(for: requestedTarget) else { return }
            refreshError = error
            return
        }
        let updatesLoaded = await model.checkPackageUpdates(target: requestedTarget, surfaceError: false)
        guard refreshIsCurrent(
            target: requestedTarget,
            profileRevision: profileRevision,
            generation: generation,
            invalidationGeneration: invalidationGeneration
        ) else { return }
        if updatesLoaded {
            refreshError = nil
        } else if let error = model.packageError(for: requestedTarget) {
            refreshError = error
        }
    }

    private func refreshIsCurrent(
        target requestedTarget: PackageConfigurationTarget,
        profileRevision: Int,
        generation: Int,
        invalidationGeneration: Int
    ) -> Bool {
        !Task.isCancelled
            && requestedTarget == target
            && profileRevision == model.profileRevision
            && generation == refreshGeneration
            && invalidationGeneration == model.packageInvalidationGeneration
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
                    TextField("Package source", text: $source)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .tronField(
                            monospaced: true,
                            compact: true,
                            dense: true,
                            surfaceTint: Color.tronEmerald.opacity(0.14),
                            border: Color.tronEmerald.opacity(0.42)
                        )
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
        TronValueRow(
            icon: "shippingbox.fill",
            title: package.source,
            value: [package.scope == .project ? "Project" : "Global", package.filtered ? "Filtered" : nil, updates.contains { $0.id == package.id } ? "Update available" : nil]
                .compactMap { $0 }.joined(separator: " · ")
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

struct PackageResolvedResourcesView: View {
    let resources: JSONValue

    private var presentation: PackageResolvedResourcesPresentation {
        PackageResolvedResourcesPresentation(resources: resources)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 18) {
                TronInfoCard(
                    icon: presentation.totalCount == 0 ? "tray" : "checkmark.seal.fill",
                    text: presentation.overview,
                    accent: .tronTeal
                )

                if !presentation.categories.isEmpty {
                    TronSettingsGroup(
                        "Resource Types",
                        detail: "Open a type to see the user-facing names and where they came from.",
                        accent: .tronTeal
                    ) {
                        VStack(spacing: 0) {
                            ForEach(Array(presentation.categories.enumerated()), id: \.element.id) { index, category in
                                if index > 0 { TronSettingsDivider(accent: .tronTeal) }
                                TronProgressiveSheetLink(
                                    accessibilityLabel: "\(category.kind.title), \(category.summary)",
                                    accent: .tronTeal
                                ) {
                                    PackageResolvedResourceCategoryView(category: category)
                                } label: {
                                    TronSettingsRow(
                                        icon: category.kind.icon,
                                        title: category.kind.title,
                                        subtitle: category.summary,
                                        accent: .tronTeal,
                                        subtitleColor: .tronTextSecondary
                                    )
                                }
                            }
                        }
                    }
                }

                TronTechnicalJSONRow(
                    value: resources,
                    title: "Technical JSON",
                    subtitle: "View the full resolved resource protocol data",
                    sheetTitle: "Resolved Resources JSON",
                    accent: .tronSlate
                )
            }
            .padding(20)
        }
        .defaultScrollAnchor(.top)
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Resolved Resources")
    }
}

private struct PackageResolvedResourceCategoryView: View {
    let category: PackageResolvedResourceCategory

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 18) {
                TronInfoCard(
                    icon: category.kind.icon,
                    text: category.summary,
                    accent: .tronTeal
                )

                if category.items.isEmpty {
                    TronInfoCard(
                        icon: "tray",
                        text: "No \(category.kind.title.lowercased()) are currently available.",
                        accent: .tronSlate
                    )
                } else {
                    TronSettingsGroup("Available", accent: .tronTeal) {
                        VStack(spacing: 0) {
                            ForEach(Array(category.items.enumerated()), id: \.element.id) { index, item in
                                if index > 0 { TronSettingsDivider(accent: .tronTeal) }
                                TronSettingsRow(
                                    icon: item.enabled ? "checkmark.circle.fill" : "minus.circle",
                                    title: item.displayName,
                                    subtitle: item.sourceDescription,
                                    subtitleLineLimit: 2,
                                    accent: item.enabled ? .tronTeal : .tronSlate,
                                    subtitleColor: .tronTextSecondary
                                )
                                .accessibilityValue(item.enabled ? "Ready to use" : "Turned off")
                            }
                        }
                    }
                }

                TronTechnicalJSONRow(
                    value: category.rawValue,
                    title: "Technical Details",
                    subtitle: "View paths, metadata, and raw values for \(category.kind.title.lowercased())",
                    sheetTitle: "\(category.kind.title) JSON",
                    accent: .tronSlate
                )
            }
            .padding(20)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle(category.kind.title, accent: .tronTeal)
    }
}
