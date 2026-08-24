import SwiftUI

/// Content-layer host. It deliberately sits below system toolbar chrome; the
/// app draws Liquid Glass only in the content region reserved by each shell.
struct InAppNoticeHost: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hostID: UUID?
    @State private var showLogs = false

    var body: some View {
        Group {
            if hostID == model.noticeCenter.activeHost {
                InAppNoticeStack(notices: model.visibleNotices, reduceMotion: reduceMotion)
            }
        }
        .onAppear {
            if hostID == nil { hostID = model.noticeCenter.acquireHost() }
            consumeLogsIfOwner()
        }
        .onDisappear {
            if let hostID { model.noticeCenter.releaseHost(hostID) }
            hostID = nil
        }
        .onChange(of: model.logsPresentationRequested) { _, _ in consumeLogsIfOwner() }
        .sheet(isPresented: $showLogs) {
            NavigationStack {
                GatewayLogsSettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showLogs = false }
                        }
                    }
            }
        }
    }

    private func consumeLogsIfOwner() {
        guard model.logsPresentationRequested, hostID == model.noticeCenter.activeHost else { return }
        model.consumeLogsPresentationRequest()
        showLogs = true
    }
}

private enum InAppNoticeLayout {
    // Leaves enough room for the shell's leading/trailing toolbar controls
    // without drawing glass inside system toolbar chrome.
    static let horizontalControlReservation: CGFloat = 80
}

private struct InAppNoticeStack: View {
    let notices: [InAppNoticeCenter.Notice]
    let reduceMotion: Bool

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            ZStack(alignment: .top) {
                ForEach(Array(notices.enumerated()), id: \.element.id) { index, notice in
                    InAppNoticeCard(notice: notice, index: index, reduceMotion: reduceMotion)
                        .scaleEffect(index == 0 ? 1 : 1 - CGFloat(index) * 0.035, anchor: .top)
                        .offset(y: CGFloat(index) * 9)
                        .opacity(index == 0 ? 1 : max(0.45, 0.78 - CGFloat(index) * 0.12))
                        .zIndex(Double(notices.count - index))
                }
            }
        }
        .frame(maxWidth: .infinity)
        // Conservative reservation for the dashboard/chat top controls. The
        // exact safe-area/toolbar relationship still needs device validation.
        .padding(.horizontal, InAppNoticeLayout.horizontalControlReservation)
        .padding(.top, 8)
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: notices)
    }
}

private struct InAppNoticeCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let notice: InAppNoticeCenter.Notice
    let index: Int
    let reduceMotion: Bool
    @State private var dragY: CGFloat = 0

    private var accent: Color {
        switch notice.role {
        case .error: .tronError
        case .warning: .tronAmber
        case .success, .progress: .tronEmerald
        case .info: .tronCyan
        }
    }
    private var symbol: String {
        switch notice.role {
        case .error: "exclamationmark.triangle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .success: "checkmark.circle.fill"
        case .progress: "arrow.triangle.2.circlepath"
        case .info: "info.circle.fill"
        }
    }
    private var isCompactPill: Bool {
        notice.message == nil && notice.actions.isEmpty
    }
    private var cornerRadius: CGFloat {
        isCompactPill ? 1_000 : 18
    }
    private var contentAlignment: VerticalAlignment {
        isCompactPill ? .center : .top
    }

    var body: some View {
        HStack(alignment: contentAlignment, spacing: 9) {
            Image(systemName: symbol).foregroundStyle(accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .font(TronTypography.bodySM.weight(.semibold))
                    .foregroundStyle(Color.tronTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let message = notice.message {
                    Text(message)
                        .font(TronTypography.caption)
                        .foregroundStyle(Color.tronTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !notice.actions.isEmpty {
                    Group {
                        if dynamicTypeSize.isAccessibilitySize {
                            actionButtons(.vertical)
                        } else {
                            ViewThatFits(in: .horizontal) {
                                actionButtons(.horizontal)
                                actionButtons(.vertical)
                            }
                        }
                    }
                    .padding(.top, 3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .frame(maxWidth: 420, minHeight: 44, alignment: .leading)
        .glassEffect(.regular.tint(accent.opacity(index == 0 ? 0.16 : 0.08)), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .offset(y: dragY)
        .simultaneousGesture(index == 0 ? swipeGesture : nil)
        .allowsHitTesting(index == 0)
        .accessibilityHidden(index != 0)
        .accessibilityElement(children: notice.actions.isEmpty ? .combine : .contain)
        .accessibilityIdentifier("in-app-notice-card")
        .accessibilityLabel([notice.title, notice.message].compactMap { $0 }.joined(separator: ". "))
        .accessibilityAddTraits(notice.actions.isEmpty ? .isStaticText : [])
        .accessibilityAction(named: "Dismiss notification") { model.noticeCenter.dismiss(notice.id) }
        .onAppear { announceIfNeeded() }
        .onChange(of: index) { _, _ in announceIfNeeded() }
        .onChange(of: notice) { _, _ in
            dragY = 0
            announceIfNeeded()
        }
        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
    }

    @ViewBuilder
    private func actionButtons(_ axis: Axis) -> some View {
        let layout = axis == .horizontal ? AnyLayout(HStackLayout(spacing: 10)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
        layout {
            ForEach(notice.actions) { action in
                Button(action.title) { model.noticeCenter.performAction(action, for: notice.id) }
                    .font(TronTypography.caption.weight(.semibold))
                    .foregroundStyle(action.role == .destructive ? Color.tronError : accent)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
        }
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                model.noticeCenter.setInteraction(notice.id, active: true)
                dragY = min(0, value.translation.height)
            }
            .onEnded { value in
                model.noticeCenter.setInteraction(notice.id, active: false)
                if value.translation.height < -28 || value.predictedEndTranslation.height < -55 {
                    model.noticeCenter.dismiss(notice.id)
                } else if reduceMotion { dragY = 0 }
                else { withAnimation(.smooth(duration: 0.18)) { dragY = 0 } }
            }
    }

    private func announceIfNeeded() {
        guard index == 0, model.noticeCenter.markForegroundAnnounced(notice.id) else { return }
        AccessibilityNotification.Announcement(
            [notice.title, notice.message].compactMap { $0 }.joined(separator: ". ")
        ).post()
    }
}

struct InAppNoticeHostModifier: ViewModifier {
    func body(content: Content) -> some View { content.overlay(alignment: .top) { InAppNoticeHost() } }
}

extension View {
    func inAppNoticeHost() -> some View { modifier(InAppNoticeHostModifier()) }
}
