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
    @State private var workingSources: Set<String> = []
    @State private var reloading = false
    @State private var packageError: String?

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

                TronSettingsGroup("Installed") {
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
        .task(id: PackageLoadID(target: target, invalidationGeneration: model.packageInvalidationGeneration)) {
            await refreshPackages()
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
        guard !reloading else { return }
        reloading = true
        Task {
            defer { reloading = false }
            await refreshPackages()
        }
    }

    private func refreshPackages() async {
        let loaded = await model.loadPackages(target: target, surfaceError: false)
        guard loaded else {
            packageError = model.packageError(for: target) ?? "The package catalog is unavailable. Try again."
            return
        }
        let updatesLoaded = await model.checkPackageUpdates(target: target, surfaceError: false)
        if updatesLoaded {
            packageError = nil
        } else {
            packageError = model.packageError(for: target) ?? "Package updates are unavailable. Try again."
        }
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
                            .disabled(source.isEmpty || workingSources.contains("install:\(source)"))
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
            if workingSources.contains(package.id) {
                ProgressView().controlSize(.small)
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
        let identity = "install:\(value)"
        workingSources.insert(identity)
        Task {
            defer { workingSources.remove(identity) }
            do {
                try await model.mutatePackage(
                    action: .install,
                    source: value,
                    local: local,
                    target: target,
                    surfaceError: false
                )
                source = ""
                packageError = nil
            } catch { packageError = error.localizedDescription }
        }
    }

    private func update(_ package: PackageSummary) {
        workingSources.insert(package.id)
        Task {
            defer { workingSources.remove(package.id) }
            do {
                try await model.mutatePackage(
                    action: .update,
                    source: package.source,
                    local: package.scope == .project,
                    target: target,
                    surfaceError: false
                )
                packageError = nil
            } catch { packageError = error.localizedDescription }
        }
    }

    private func remove(_ package: PackageSummary) {
        workingSources.insert(package.id)
        packageToRemove = nil
        Task {
            defer { workingSources.remove(package.id) }
            do {
                try await model.mutatePackage(
                    action: .remove,
                    source: package.source,
                    local: package.scope == .project,
                    target: target,
                    surfaceError: false
                )
                packageError = nil
            } catch { packageError = error.localizedDescription }
        }
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
