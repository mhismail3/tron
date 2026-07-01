import SwiftUI

enum DashboardV2LabDetent: String, Equatable {
    case compact
    case expanded

    var title: String {
        switch self {
        case .compact: "Compact"
        case .expanded: "Expanded"
        }
    }
}

struct DashboardV2LabOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var detent: DashboardV2LabDetent
    let onClose: () -> Void
    @State private var isSheetSettled = false
    @State private var isClosing = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                Color.black.opacity(isSheetSettled ? 0.28 : 0)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                    .onTapGesture {
                        dismissSheet()
                    }

                DashboardV2LabSheet(
                    detent: $detent,
                    bottomSafeArea: proxy.safeAreaInsets.bottom,
                    onClose: dismissSheet
                )
                    .frame(height: sheetHeight(in: proxy) + proxy.safeAreaInsets.bottom)
                    .frame(maxWidth: .infinity)
                    .offset(y: sheetOffset(in: proxy))
                    .scaleEffect(isSheetSettled || reduceMotion ? 1 : 0.985, anchor: .bottom)
                    .opacity(isSheetSettled || !reduceMotion ? 1 : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(edges: .bottom)
        }
        .animation(dimAnimation, value: isSheetSettled)
        .animation(settleAnimation, value: isSheetSettled)
        .onAppear {
            isSheetSettled = false
            Task { @MainActor in
                await Task.yield()
                withAnimation(settleAnimation) {
                    isSheetSettled = true
                }
            }
        }
        .accessibilityIdentifier("dashboard-v2-lab-overlay")
    }

    private var settleAnimation: Animation {
        reduceMotion ? .linear(duration: 0.01) : DashboardV2Motion.sheetPresent
    }

    private var dimAnimation: Animation {
        reduceMotion ? .linear(duration: 0.01) : DashboardV2Motion.sheetDim
    }

    private var dismissAnimation: Animation {
        reduceMotion ? .linear(duration: 0.01) : DashboardV2Motion.sheetDismiss
    }

    private func sheetOffset(in proxy: GeometryProxy) -> CGFloat {
        guard !reduceMotion else { return 0 }
        return isSheetSettled ? 0 : sheetHeight(in: proxy) + proxy.safeAreaInsets.bottom + 44
    }

    private func dismissSheet() {
        guard !isClosing else { return }
        isClosing = true
        withAnimation(dismissAnimation) {
            isSheetSettled = false
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: reduceMotion ? 40_000_000 : 260_000_000)
            onClose()
        }
    }

    private func sheetHeight(in proxy: GeometryProxy) -> CGFloat {
        switch detent {
        case .compact:
            min(430, proxy.size.height * 0.55)
        case .expanded:
            max(560, proxy.size.height - proxy.safeAreaInsets.top - 34)
        }
    }
}

private struct DashboardV2LabSheet: View {
    @Binding var detent: DashboardV2LabDetent
    let bottomSafeArea: CGFloat
    let onClose: () -> Void

    private let cornerRadius: CGFloat = 34

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    controlGrid
                    geometryProbe
                    componentStates
                }
                .padding(.bottom, 26)
            }
            .scrollContentBackground(.hidden)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, max(bottomSafeArea, 12))
        .dashboardV2BottomSheetSurface(
            topRadius: cornerRadius,
            tint: Color.tronTextPrimary.opacity(0.09),
            backingOpacity: 0.46,
            strokeOpacity: 0.16
        )
        .overlay(alignment: .top) {
            Capsule()
                .fill(Color.tronTextMuted.opacity(0.45))
                .frame(width: 46, height: 4)
                .padding(.top, 8)
                .accessibilityHidden(true)
        }
        .gesture(
            DragGesture(minimumDistance: 16)
                .onEnded { value in
                    withAnimation(DashboardV2Motion.sheetDetent) {
                        if value.translation.height < -70 {
                            detent = .expanded
                        } else if value.translation.height > 70 {
                            detent = .compact
                        }
                    }
                }
        )
        .accessibilityIdentifier("dashboard-v2-lab-sheet")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            DashboardV2IconButton(
                systemImage: "xmark",
                accessibilityLabel: "Close component lab",
                accessibilityIdentifier: "dashboard-v2-lab-close",
                size: 44,
                symbolSize: 20,
                action: onClose
            )

            VStack(alignment: .leading, spacing: 2) {
                Text("Glass Lab")
                    .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .bold))
                    .foregroundStyle(.tronTextPrimary)
                Text("Owned sheet chrome · \(detent.title)")
                    .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                    .foregroundStyle(.tronTextMuted)
            }

            Spacer(minLength: 8)

            DashboardV2IconButton(
                systemImage: detent == .compact ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left",
                accessibilityLabel: detent == .compact ? "Expand component lab" : "Collapse component lab",
                accessibilityIdentifier: "dashboard-v2-lab-detent",
                size: 44,
                symbolSize: 18,
                accent: .tronCyan
            ) {
                withAnimation(DashboardV2Motion.sheetDetent) {
                    detent = detent == .compact ? .expanded : .compact
                }
            }
        }
        .padding(.top, 10)
    }

    private var controlGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            labCaption("Circular Controls")
            HStack(spacing: 12) {
                DashboardV2IconButton(
                    systemImage: "gearshape",
                    accessibilityLabel: "Lab regular circle",
                    accessibilityIdentifier: "dashboard-v2-lab-circle-regular",
                    size: 44,
                    symbolSize: 20,
                    action: {}
                )

                DashboardV2IconButton(
                    systemImage: "sparkles",
                    accessibilityLabel: "Lab large circle",
                    accessibilityIdentifier: "dashboard-v2-lab-circle-large",
                    size: 52,
                    symbolSize: 23,
                    accent: .tronCyan,
                    glassTint: Color.tronTextPrimary.opacity(0.06),
                    action: {}
                )

                DashboardV2IconButton(
                    systemImage: "checkmark",
                    accessibilityLabel: "Lab disabled circle",
                    accessibilityIdentifier: "dashboard-v2-lab-circle-disabled",
                    size: 44,
                    symbolSize: 19,
                    isEnabled: false,
                    action: {}
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var geometryProbe: some View {
        VStack(alignment: .leading, spacing: 12) {
            labCaption("Shape Probes")

            HStack(spacing: 10) {
                DashboardV2PillButton(
                    title: "Inspect",
                    systemImage: "scope",
                    accent: .tronCyan,
                    isSelected: true,
                    action: {}
                )
                .accessibilityIdentifier("dashboard-v2-lab-pill-selected")

                DashboardV2PillButton(
                    title: "Neutral",
                    systemImage: "circle.hexagongrid",
                    action: {}
                )
                .accessibilityIdentifier("dashboard-v2-lab-pill-neutral")
            }

            HStack(spacing: 10) {
                labTile(title: "Sheet", value: detent.title, color: .tronEmerald)
                labTile(title: "Chrome", value: "Owned", color: .tronCyan)
            }
        }
    }

    private var componentStates: some View {
        VStack(alignment: .leading, spacing: 12) {
            labCaption("Rows")

            VStack(spacing: 9) {
                labRow(title: "Idle component row", icon: "circle", color: .tronEmerald)
                labRow(title: "Active component row", icon: "circle.dotted", color: .tronCyan)
                labRow(title: "Warning component row", icon: "exclamationmark.triangle", color: .tronWarning)
            }
        }
    }

    private func labCaption(_ text: String) -> some View {
        Text(text)
            .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .bold))
            .foregroundStyle(.tronTextMuted)
            .textCase(.uppercase)
            .tracking(0.5)
    }

    private func labTile(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .semibold))
                .foregroundStyle(.tronTextMuted)
            Text(value)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .bold))
                .foregroundStyle(color)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardV2GlassSurface(cornerRadius: 18, tint: color.opacity(0.12))
    }

    private func labRow(title: String, icon: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)

            Text(title)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.tronTextPrimary)

            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .dashboardV2GlassSurface(cornerRadius: 16, tint: color.opacity(0.10))
    }
}
