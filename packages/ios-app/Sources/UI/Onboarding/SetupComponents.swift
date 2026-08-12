import SwiftUI

struct ProviderSetupRow: View {
    @Environment(AppModel.self) private var model
    let provider: ProviderSummary

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: provider.configured ? "checkmark.seal.fill" : "key")
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(provider.configured ? Color.tronEmerald : Color.tronTextSecondary)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(provider.name)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(Color.tronTextPrimary)
                Text(provider.configured ? (provider.authSource ?? "Configured") : "Not configured")
                    .font(TronTypography.bodySM)
                    .foregroundStyle(Color.tronTextPrimary)
            }
            Spacer(minLength: 8)
            if provider.configured {
                Text("Connected")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                    .foregroundStyle(Color.tronAccentText)
            } else {
                Menu {
                    ForEach(provider.authMethods, id: \.self) { method in
                        Button(method == "oauth" ? "Sign in" : "Enter API key") {
                            Task {
                                do { try await model.beginAuth(providerID: provider.id, authType: method) }
                                catch { model.lastError = error.localizedDescription }
                            }
                        }
                    }
                } label: {
                    Label("Connect", systemImage: "person.crop.circle.badge.plus")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(Color.tronAccentText)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 40)
                        .glassEffect(.regular.tint(Color.tronEmerald.opacity(0.12)).interactive(), in: Capsule())
                }
                .accessibilityLabel("Connect \(provider.name)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 58)
        .tronGlassSurface(accent: .tronEmerald, cornerRadius: 14, tintOpacity: 0.11)
    }
}

struct ModelPicker: View {
    @Binding var selection: ModelRef?
    let models: [ModelSummary]
    @State private var search = ""

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 8) {
                TronSearchBar(text: $search, prompt: "Search models")
                    .padding(.bottom, 4)
                ForEach(filtered) { model in
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
            .padding(.vertical, 12)
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
    }

    private var filtered: [ModelSummary] {
        search.isEmpty ? models : models.filter { "\($0.provider) \($0.id) \($0.name)".localizedCaseInsensitiveContains(search) }
    }
}
