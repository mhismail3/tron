import SwiftUI

enum PackageResourceSummaryPolicy {
    static func summary(for resources: JSONValue) -> String {
        if let object = resources.objectValue {
            return "\(object.count) top-level categor\(object.count == 1 ? "y" : "ies")"
        }
        if let array = resources.arrayValue {
            return "\(array.count) resolved item\(array.count == 1 ? "" : "s")"
        }
        return "Resolved package resource details"
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
                    .tronGlassSurface(accent: .tronAmber, tintOpacity: 0.09)
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
        .task(id: PackageLoadID(
            target: target,
            profileRevision: model.profileRevision,
            invalidationGeneration: model.packageInvalidationGeneration,
            refreshGeneration: refreshGeneration
        )) {
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
        .sheet(isPresented: $showingInstall) {
            NavigationStack {
                packageInstallSheet
            }
            .tronTopBlur(.sheet)
            .tronPresentation()
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.hidden)
        }
        .sheet(item: $packageToRemove) { package in
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
            LazyVStack(alignment: .leading, spacing: 14) {
                TronSettingsGroup("Source", detail: "Use an npm package, Git URL, or local path.", accent: .tronEmerald) {
                    VStack(spacing: 10) {
                        TextField("Package source", text: $source)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .tronField(monospaced: true, compact: true)
                        TronToggleRow(icon: "folder.badge.gearshape", title: "Project scope", accent: .tronEmerald, isOn: $local)
                            .disabled(projectCWD == nil)
                        Button("Install Package") { install() }
                            .buttonStyle(TronActionButtonStyle(role: .primary))
                            .disabled(source.isEmpty || activeMutations[.install(source)] != nil)
                    }
                    .padding(10)
                }
            }
            .padding(16)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Install Package")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button { showingInstall = false } label: {
                    Image(systemName: "checkmark")
                        .font(TronTypography.buttonSM)
                        .foregroundStyle(Color.tronEmerald)
                }
                .accessibilityLabel("Done")
            }
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

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            TronStructuredJSONView(
                value: resources,
                title: "Resolved Resources",
                accent: .tronTeal
            )
            .padding(18)
        }
        .defaultScrollAnchor(.top)
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Resolved Resources")
    }
}
