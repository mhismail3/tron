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
    @State private var workingSources: Set<String> = []
    @State private var checking = false
    @State private var reloading = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 18) {
                TronSettingsGroup("Installed") {
                    if let packages = inventory?.packages, !packages.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(Array(packages.enumerated()), id: \.element.id) { index, package in
                                if index > 0 { TronSettingsDivider() }
                                packageRow(package)
                            }
                        }
                    } else {
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

                TronSettingsGroup("Updates", accent: .tronCyan) {
                    VStack(spacing: 0) {
                        Button {
                            checking = true
                            Task { await model.checkPackageUpdates(target: target); checking = false }
                        } label: {
                            TronValueRow(icon: "arrow.clockwise", title: checking ? "Checking…" : "Check for Updates", accent: .tronCyan) {
                                if checking { ProgressView().controlSize(.small) }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(checking)
                        if !updates.isEmpty {
                            TronSettingsDivider(accent: .tronCyan)
                            Button("Update All") {
                                Task {
                                    do { try await model.mutatePackage(action: .update, source: nil, local: false, target: target) }
                                    catch { model.presentConfigurationActionError(error) }
                                }
                            }
                            .buttonStyle(TronActionButtonStyle(role: .primary))
                            .padding(12)
                        }
                    }
                }

                TronSettingsGroup("Install", detail: "Use an npm package, Git URL, or local path.", accent: .tronPurple) {
                    VStack(spacing: 12) {
                        TextField("Package source", text: $source)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .tronField(monospaced: true, compact: true)
                        TronToggleRow(icon: "folder.badge.gearshape", title: "Project scope", accent: .tronPurple, isOn: $local)
                            .disabled(projectCWD == nil)
                        Button("Install Package") { install() }
                            .buttonStyle(TronActionButtonStyle(role: .primary))
                            .disabled(source.isEmpty || workingSources.contains("install:\(source)"))
                    }
                    .padding(12)
                }

                if let resources = inventory?.resources {
                    let summary = PackageResourceSummaryPolicy.summary(for: resources)
                    TronSettingsGroup("Resolved Resources", accent: .tronTeal) {
                        TronProgressiveSheetLink(
                            accessibilityLabel: "Inspect resolved resources, \(summary)"
                        ) {
                            PackageResolvedResourcesView(resources: resources)
                        } label: {
                            TronSettingsRow(
                                icon: "shippingbox.and.arrow.forward",
                                title: "Inspect Resolved Resources",
                                subtitle: summary,
                                accent: .tronTeal
                            )
                        }
                    }
                }

                Label("Agent packages and extensions run with your Mac user authority. Review their source before installing.", systemImage: "exclamationmark.shield")
                    .font(TronTypography.bodySM)
                    .foregroundStyle(Color.tronTextPrimary)
                    .padding(14)
                    .tronGlassSurface(accent: .tronAmber, tintOpacity: 0.09)
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
            await model.loadPackages(target: target)
        }
        .confirmationDialog(
            "Remove this package?",
            isPresented: Binding(get: { packageToRemove != nil }, set: { if !$0 { packageToRemove = nil } }),
            presenting: packageToRemove
        ) { package in
            Button("Remove Package", role: .destructive) { remove(package) }
        } message: { package in Text(package.source) }
    }

    private func reload() {
        guard !reloading else { return }
        reloading = true
        Task {
            defer { reloading = false }
            await model.loadPackages(target: target)
        }
    }

    private func packageRow(_ package: PackageSummary) -> some View {
        TronValueRow(
            icon: "shippingbox.fill",
            title: package.source,
            detail: [package.scope == .project ? "Project" : "Global", package.filtered ? "Filtered" : nil, updates.contains { $0.id == package.id } ? "Update available" : nil]
                .compactMap { $0 }.joined(separator: " · ")
        ) {
            if workingSources.contains(package.id) {
                ProgressView().controlSize(.small)
            } else {
                Menu {
                    Button("Update", systemImage: "arrow.clockwise") { update(package) }
                    Button("Remove", systemImage: "trash", role: .destructive) { packageToRemove = package }
                } label: {
                    Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
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
                try await model.mutatePackage(action: .install, source: value, local: local, target: target)
                source = ""
            } catch { model.presentConfigurationActionError(error) }
        }
    }

    private func update(_ package: PackageSummary) {
        workingSources.insert(package.id)
        Task {
            defer { workingSources.remove(package.id) }
            do { try await model.mutatePackage(action: .update, source: package.source, local: package.scope == .project, target: target) }
            catch { model.presentConfigurationActionError(error) }
        }
    }

    private func remove(_ package: PackageSummary) {
        workingSources.insert(package.id)
        packageToRemove = nil
        Task {
            defer { workingSources.remove(package.id) }
            do { try await model.mutatePackage(action: .remove, source: package.source, local: package.scope == .project, target: target) }
            catch { model.presentConfigurationActionError(error) }
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
