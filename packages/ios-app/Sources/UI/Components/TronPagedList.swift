import SwiftUI

/// The Session History window: one lazy page, controls at both ends and a native
/// viewport replaced only after successful explicit navigation. No infinite load.
struct TronPagedList<Header: View, Rows: View, Controls: View>: View {
    let viewportGeneration: Int
    let identifier: String
    let active: Bool
    let loading: Bool
    let hasPage: Bool
    let hasRows: Bool
    let error: String?
    let loadingLabel: String
    let accent: Color
    let retry: () -> Void
    @ViewBuilder let header: () -> Header
    @ViewBuilder let rows: () -> Rows
    @ViewBuilder let controls: (String) -> Controls
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: TronSpacing.md) {
                    header()
                    if loading && !hasPage { TronSheetLoadingState(label: loadingLabel, accent: accent) }
                    if hasPage {
                        controls("top")
                        rows()
                        if hasRows { controls("bottom") }
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
            }
            .tronScrollEdgeChrome()
            .id(viewportGeneration)
            .transition(.opacity)
            .accessibilityIdentifier(identifier)
        }
        .animation(active && !reduceMotion ? .easeInOut(duration: 0.2) : nil, value: viewportGeneration)
        .overlay(alignment: .bottom) {
            if let error {
                TronSettingsNotice(message: error, retry: retry)
                    .padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .padding(18)
            }
        }
    }
}

struct TronPageControls: View {
    let range: String
    let enabled: Bool
    let location: String
    let identifier: String
    let olderTitle: String
    let newerTitle: String
    let accent: Color
    var older: (() -> Void)?
    var newer: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        layout {
            if older != nil || newer != nil {
                HStack(spacing: 6) {
                    if let older {
                        Button(action: older) {
                            TronInlineActionLabel(olderTitle, icon: "arrow.down", accent: accent, usesSemanticAccent: true)
                        }
                        .accessibilityIdentifier("\(identifier)-older-\(location)")
                        .transition(.opacity)
                    }
                    if let newer {
                        Button(action: newer) {
                            TronInlineActionLabel(newerTitle, icon: "arrow.up", accent: accent, usesSemanticAccent: true)
                        }
                        .accessibilityIdentifier("\(identifier)-newer-\(location)")
                        .transition(.opacity)
                    }
                }
                .controlSize(.small).fixedSize(horizontal: true, vertical: false)
                .buttonStyle(.plain).disabled(!enabled)
            }
            Text(range)
                .foregroundStyle(Color.tronTextSecondary).contentTransition(.opacity)
                .accessibilityIdentifier("\(identifier)-range-\(location)")
                .font(TronTypography.bodySM).multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.top, 4).padding(.bottom, location == "top" ? 2 : 8)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: range)
    }
}

/// Shared card geometry and typography; each domain owns its metadata/actions.
struct TronPagedListRow<Metadata: View, Trailing: View>: View {
    let title: String
    let accent: Color
    var emphasized = false
    var identifier = ""
    let select: () -> Void
    @ViewBuilder let metadata: () -> Metadata
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Button(action: select) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(TronTypography.body.weight(.semibold))
                        .foregroundStyle(Color.tronTextPrimary).lineLimit(3)
                    metadata()
                        .font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier(identifier)
            trailing()
        }
        .padding(.horizontal, TronSpacing.xl).padding(.vertical, TronSpacing.md)
        .tronScrollSurface(accent: accent, tintOpacity: emphasized ? 0.15 : 0.07)
        .environment(\.tronSettingsVisualTheme, nil).tint(accent)
    }
}
