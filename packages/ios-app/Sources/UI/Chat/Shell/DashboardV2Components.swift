import SwiftUI

enum DashboardSurfaceMode: String, CaseIterable, Identifiable {
    case classic
    case dashboardV2

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic:
            "Current Dashboard"
        case .dashboardV2:
            "Dashboard 2.0"
        }
    }

    var subtitle: String {
        switch self {
        case .classic:
            "Shipping surface"
        case .dashboardV2:
            "Owned glass lab"
        }
    }
}

enum DashboardV2Motion {
    static let menuPresent = Animation.snappy(duration: 0.20, extraBounce: 0.01)
    static let menuDismiss = Animation.smooth(duration: 0.16)
    static let sheetPresent = Animation.snappy(duration: 0.42, extraBounce: 0.03)
    static let sheetDismiss = Animation.smooth(duration: 0.24)
    static let sheetDim = Animation.smooth(duration: 0.18)
    static let sheetDetent = Animation.snappy(duration: 0.34, extraBounce: 0.02)
}

struct DashboardModeSelectorButton: View {
    @Binding var selectedMode: DashboardSurfaceMode
    var size: CGFloat = 44
    var accent: Color = .tronEmerald
    @State private var isMenuPresented = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            DashboardModeSelectorTrigger(
                selectedMode: selectedMode,
                isMenuPresented: $isMenuPresented,
                size: size,
                accent: accent
            )

            if isMenuPresented {
                DashboardModePopupMenu(
                    selectedMode: $selectedMode,
                    isPresented: $isMenuPresented
                )
                .offset(x: 0, y: size + 10)
                .transition(.scale(scale: 0.96, anchor: .topLeading).combined(with: .opacity))
                .zIndex(10)
            }
        }
    }
}

struct DashboardModeSelectorTrigger: View {
    let selectedMode: DashboardSurfaceMode
    @Binding var isMenuPresented: Bool
    var size: CGFloat = 44
    var accent: Color = .tronEmerald

    var body: some View {
        Button {
            withAnimation(DashboardV2Motion.menuPresent) {
                isMenuPresented.toggle()
            }
        } label: {
            DashboardV2LogoSurface(size: size, accent: accent)
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .accessibilityIdentifier("dashboard-mode-selector")
        .accessibilityLabel("Dashboard selector")
        .accessibilityValue(selectedMode.title)
    }
}

struct DashboardModePopupMenu: View {
    @Binding var selectedMode: DashboardSurfaceMode
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(DashboardSurfaceMode.allCases) { mode in
                Button {
                    selectedMode = mode
                    withAnimation(DashboardV2Motion.menuDismiss) {
                        isPresented = false
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: selectedMode == mode ? "checkmark.circle.fill" : "circle")
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                            .foregroundStyle(selectedMode == mode ? Color.tronEmerald : Color.tronTextMuted)
                            .frame(width: 20, height: 20)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.title)
                                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                                .foregroundStyle(.tronTextPrimary)
                            Text(mode.subtitle)
                                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                                .foregroundStyle(.tronTextMuted)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(width: 210, alignment: .leading)
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("dashboard-mode-option-\(mode.rawValue)")
                .accessibilityLabel(mode.title)
                .accessibilityHint(mode.subtitle)
                .accessibilityAddTraits(.isButton)
            }
        }
        .padding(6)
        .dashboardV2GlassSurface(
            cornerRadius: 20,
            tint: Color.tronTextPrimary.opacity(0.08),
            strokeOpacity: 0.14
        )
        .accessibilityIdentifier("dashboard-mode-menu")
    }
}

struct DashboardV2LogoSurface: View {
    var size: CGFloat
    var accent: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.clear)
                .glassEffect(
                    .regular.tint(Color.tronTextPrimary.opacity(0.10)).interactive(),
                    in: Circle()
                )
                .overlay {
                    Circle()
                        .stroke(Color.tronTextPrimary.opacity(0.14), lineWidth: 1)
                }

            Image("TronLogoVector")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size * 0.50, height: size * 0.50)
                .offset(y: 1)
                .foregroundStyle(accent)
                .accessibilityHidden(true)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
    }
}

struct DashboardV2IconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    var accessibilityIdentifier: String? = nil
    var size: CGFloat = 44
    var symbolSize: CGFloat = 20
    var accent: Color = .tronTextPrimary
    var glassTint: Color = Color.tronTextPrimary.opacity(0.06)
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button {
            guard isEnabled else { return }
            action()
        } label: {
            ZStack {
                Circle()
                    .fill(Color.clear)
                    .glassEffect(
                        .regular.tint(glassTint).interactive(isEnabled),
                        in: Circle()
                    )
                    .overlay {
                        Circle()
                            .stroke(Color.tronTextPrimary.opacity(0.14), lineWidth: 1)
                    }

                Image(systemName: systemImage)
                    .font(TronTypography.sans(size: symbolSize, weight: .medium))
                    .foregroundStyle(isEnabled ? accent : Color.tronTextDisabled)
                    .accessibilityHidden(true)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .frame(width: size, height: size)
        .contentShape(Circle())
        .accessibilityIdentifier(accessibilityIdentifier ?? accessibilityLabel.lowercased().replacingOccurrences(of: " ", with: "-"))
        .accessibilityLabel(accessibilityLabel)
    }
}

struct DashboardV2PillButton: View {
    let title: String
    let systemImage: String
    var accent: Color = .tronTextPrimary
    var isSelected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .accessibilityHidden(true)
                Text(title)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Color.tronTextPrimary : accent)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.tint((isSelected ? accent : Color.tronTextPrimary).opacity(isSelected ? 0.20 : 0.08)).interactive(),
            in: Capsule()
        )
        .glassEffectTransition(.materialize)
        .accessibilityLabel(title)
    }
}

extension View {
    func dashboardV2GlassSurface(
        cornerRadius: CGFloat,
        tint: Color = Color.tronTextPrimary.opacity(0.08),
        strokeOpacity: Double = 0.12
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background {
                shape
                    .fill(Color.clear)
                    .glassEffect(.regular.tint(tint).interactive(), in: shape)
                    .glassEffectTransition(.materialize)
                    .overlay {
                        shape.stroke(Color.tronTextPrimary.opacity(strokeOpacity), lineWidth: 1)
                    }
            }
            .clipShape(shape)
    }

    func dashboardV2BottomSheetSurface(
        topRadius: CGFloat,
        tint: Color = Color.tronTextPrimary.opacity(0.08),
        backingOpacity: Double = 0.42,
        strokeOpacity: Double = 0.12
    ) -> some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: topRadius,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: topRadius,
            style: .continuous
        )
        return self
            .background {
                ZStack {
                    shape
                        .fill(Color.tronSurface.opacity(backingOpacity))

                    shape
                        .fill(Color.clear)
                        .glassEffect(.regular.tint(tint).interactive(), in: shape)
                        .glassEffectTransition(.materialize)
                }
                    .overlay {
                        shape.stroke(Color.tronTextPrimary.opacity(strokeOpacity), lineWidth: 1)
                    }
            }
            .clipShape(shape)
    }
}
