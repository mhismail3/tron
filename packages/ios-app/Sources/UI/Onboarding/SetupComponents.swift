import SwiftUI

struct ProviderSetupRow: View {
    @Environment(AppModel.self) private var model
    let provider: ProviderSummary
    var sessionID: String? = nil

    private var providerTarget: ProviderCatalogTarget {
        sessionID.map(ProviderCatalogTarget.session(id:)) ?? .global
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: provider.configured ? "checkmark.seal.fill" : "key")
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(provider.configured ? Color.tronEmerald : Color.tronTextSecondary)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(Color.tronTextPrimary)
                    .lineLimit(1)
                Text(connectionDetail)
                    .font(TronTypography.bodySM)
                    .foregroundStyle(Color.tronTextSecondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            if provider.configured {
                Menu {
                    Button("Log Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                        Task {
                            do { try await model.logout(providerID: provider.id, target: providerTarget) }
                            catch { model.lastError = error.localizedDescription }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .bold))
                        .foregroundStyle(Color.tronEmerald)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("\(provider.name) provider actions")
            } else {
                Menu {
                    ForEach(provider.authMethods, id: \.self) { method in
                        Button(method == "oauth" ? "Sign in" : "Enter API key") {
                            Task {
                                do { try await model.beginAuth(providerID: provider.id, authType: method, target: providerTarget) }
                                catch { model.lastError = error.localizedDescription }
                            }
                        }
                    }
                } label: {
                    Text("Connect")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(Color.tronEmerald)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .accessibilityLabel("Connect \(provider.name)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
        .tronGlassSurface(accent: .tronEmerald, cornerRadius: 12, tintOpacity: 0.08)
    }

    private var connectionDetail: String {
        guard provider.configured else { return "Not configured" }
        let source = provider.authSource?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = source?.lowercased().replacingOccurrences(of: "_", with: " ")
        let label: String
        switch normalized {
        case "oauth": label = "OAuth"
        case "stored credential", "stored cred", "api key", "credential": label = "stored credential"
        default: label = (source?.isEmpty == false ? source : nil) ?? "stored credential"
        }
        return "Connected - \(label)"
    }
}

struct ModelPicker: View {
    @Binding var selection: ModelRef?
    let models: [ModelSummary]
    @State private var search = ""
    @State private var showingSearch = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 8) {
                ForEach(filtered, id: \.ref) { model in
                    Button { selection = model.ref } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selection == model.ref ? "checkmark.circle.fill" : "cpu")
                                .foregroundStyle(selection == model.ref ? Color.tronEmerald : Color.tronSlate)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.name)
                                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                                    .foregroundStyle(Color.tronTextPrimary)
                                Text("\(model.provider) / \(model.id)")
                                    .font(TronTypography.codeContent)
                                    .foregroundStyle(Color.tronTextPrimary)
                            }
                            Spacer(minLength: 8)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .tronGlassSurface(
                        accent: selection == model.ref ? .tronEmerald : .tronSlate,
                        cornerRadius: 14,
                        tintOpacity: selection == model.ref ? 0.18 : 0.08,
                        interactive: true
                    )
                    .accessibilityLabel(model.name)
                    .accessibilityValue(selection == model.ref ? "Selected" : "")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 72)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Group {
                if showingSearch {
                    TronSearchBar(
                        text: $search,
                        prompt: "Search models",
                        focusOnAppear: true,
                        onClose: {
                            withAnimation(.snappy(duration: 0.18)) {
                                search = ""
                                showingSearch = false
                            }
                        }
                    )
                } else {
                    Button {
                        withAnimation(.snappy(duration: 0.18)) { showingSearch = true }
                    } label: {
                        Label("Search models", systemImage: "magnifyingglass")
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                            .foregroundStyle(Color.tronEmerald)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .padding(.horizontal, TronSpacing.inputHorizontal)
                            .contentShape(Capsule())
                            .glassEffect(.clear.tint(Color.tronEmerald.opacity(0.10)).interactive(), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Search models")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.clear)
        }
        .scrollDismissesKeyboard(.interactively)
        .tronScrollEdgeChrome()
    }

    private var filtered: [ModelSummary] {
        search.isEmpty ? models : models.filter { "\($0.provider) \($0.id) \($0.name)".localizedCaseInsensitiveContains(search) }
    }
}
