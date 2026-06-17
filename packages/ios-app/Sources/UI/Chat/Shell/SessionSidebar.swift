import SwiftUI

// MARK: - Session Sidebar

struct SessionSidebar: View {
    @Environment(\.dependencies) var dependencies
    @Environment(\.interactionPolicy) var interactionPolicy
    @Binding var selectedSessionId: String?
    @State private var sessionToArchive: String?
    @State private var showArchiveConfirmation = false
    @State private var workspaceExpansion = SessionDashboardWorkspaceExpansion()

    private var eventStoreManager: EventStoreManager { dependencies.eventStoreManager }
    let onNewSession: () -> Void
    let onDeleteSession: (String) -> Void
    let actions: ShellToolbarActions

    private var workspaceGroups: [SessionDashboardWorkspaceGroup] {
        SessionDashboardWorkspaceGroup.groups(from: eventStoreManager.sortedSessions)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            List(selection: $selectedSessionId) {
                ForEach(workspaceGroups) { group in
                    Section {
                        if workspaceExpansion.isExpanded(group.id) {
                            ForEach(group.sessions) { session in
                                SessionDashboardRow(
                                    session: session,
                                    isSelected: session.id == selectedSessionId
                            )
                            .tag(session.id)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(SessionDashboardLayout.rowInsets)
                            .opacity(session.isDeleting ? 0.45 : 1.0)
                            .allowsHitTesting(!session.isDeleting)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    if !session.isDeleting && (interactionPolicy?.canMutateSession ?? false) {
                                        Button {
                                            sessionToArchive = session.id
                                            showArchiveConfirmation = true
                                        } label: {
                                            Image(systemName: "archivebox")
                                        }
                                        .tint(.tronEmerald)
                                    }
                                }
                            }
                        }
                    } header: {
                        SessionWorkspaceHeader(
                            title: group.name,
                            isExpanded: workspaceExpansion.isExpanded(group.id)
                        ) {
                            withAnimation(.snappy(duration: 0.14)) {
                                workspaceExpansion.toggle(group.id)
                            }
                        }
                    }
                }
            }
            .tint(.clear)
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 34)
            .contentMargins(.top, 38)
            .contentMargins(.bottom, 92)
            .overlay {
                if eventStoreManager.sortedSessions.isEmpty {
                    SessionDashboardEmptyState()
                }
            }

            let canCreate = interactionPolicy?.canCreateSession ?? false
            FloatingNewSessionButton(action: onNewSession, size: 56)
                .disabled(!canCreate)
                .opacity(canCreate ? 1.0 : 0.4)
                .padding(.trailing, 20)
                .padding(.bottom, 8)
        }
        .background {
            Color.clear
                .alert("Archive Session", isPresented: $showArchiveConfirmation) {
                    Button("Cancel", role: .cancel) {}
                    Button("Archive", role: .destructive) {
                        if let id = sessionToArchive {
                            onDeleteSession(id)
                        }
                    }
                } message: {
                    Text("This will archive the session from your device. Server data will remain.")
                }
                .tint(.gray)
        }
        .tronScreenBackground()
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            ShellToolbarContent(title: "Tron", accent: .tronEmerald, actions: actions)
        }
    }
}

// MARK: - Dashboard Projection

struct SessionDashboardWorkspaceGroup: Identifiable {
    let path: String
    let name: String
    let sessions: [CachedSession]

    var id: String { path.isEmpty ? "__default_workspace__" : path }

    static func groups(from sessions: [CachedSession]) -> [SessionDashboardWorkspaceGroup] {
        var orderedPaths: [String] = []
        var sessionsByPath: [String: [CachedSession]] = [:]

        for session in sessions {
            let path = session.workingDirectory
            if sessionsByPath[path] == nil {
                orderedPaths.append(path)
                sessionsByPath[path] = []
            }
            sessionsByPath[path]?.append(session)
        }

        return orderedPaths.compactMap { path in
            guard let sessions = sessionsByPath[path], !sessions.isEmpty else { return nil }
            return SessionDashboardWorkspaceGroup(
                path: path,
                name: CachedSession.workspaceDisplayName(for: path),
                sessions: sessions
            )
        }
    }
}

struct SessionDashboardWorkspaceExpansion: Equatable {
    private(set) var collapsedGroupIds: Set<String> = []

    func isExpanded(_ groupId: String) -> Bool {
        !collapsedGroupIds.contains(groupId)
    }

    mutating func toggle(_ groupId: String) {
        if collapsedGroupIds.contains(groupId) {
            collapsedGroupIds.remove(groupId)
        } else {
            collapsedGroupIds.insert(groupId)
        }
    }
}

enum SessionDashboardLayout {
    static let outerHorizontalPadding: CGFloat = 24
    static let iconColumnWidth: CGFloat = 18
    static let iconTextSpacing: CGFloat = 8
    static let headerTopPadding: CGFloat = 10
    static let headerBottomPadding: CGFloat = 3
    static let rowVerticalPadding: CGFloat = 5

    static var headerInsets: EdgeInsets {
        EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
    }

    static var rowInsets: EdgeInsets {
        EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0)
    }
}

enum SessionDashboardStatus: Equatable {
    case deleting
    case processing
    case forked
    case idle

    init(session: CachedSession) {
        if session.isDeleting {
            self = .deleting
        } else if session.isProcessing == true {
            self = .processing
        } else if session.isFork == true {
            self = .forked
        } else {
            self = .idle
        }
    }

    var symbolName: String {
        switch self {
        case .deleting:
            "archivebox"
        case .processing:
            "circle.dotted"
        case .forked:
            "arrow.triangle.branch"
        case .idle:
            "circle"
        }
    }

    var color: Color {
        switch self {
        case .deleting:
            .tronTextMuted
        case .processing:
            .tronEmerald
        case .forked:
            .tronEmerald.opacity(0.8)
        case .idle:
            .tronEmerald.opacity(0.8)
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .deleting:
            "archiving"
        case .processing:
            "active"
        case .forked:
            "forked"
        case .idle:
            "idle"
        }
    }
}

// MARK: - Dashboard Views

private struct SessionWorkspaceHeader: View {
    let title: String
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: SessionDashboardLayout.iconTextSpacing) {
                Image(systemName: isExpanded ? "folder.fill" : "folder")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(
                        width: SessionDashboardLayout.iconColumnWidth,
                        height: SessionDashboardLayout.iconColumnWidth
                    )
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)

                Text(title)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.tronEmerald)
            .padding(.horizontal, SessionDashboardLayout.outerHorizontalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .animation(.snappy(duration: 0.14), value: isExpanded)
        }
        .buttonStyle(.plain)
        .textCase(nil)
        .padding(.top, SessionDashboardLayout.headerTopPadding)
        .padding(.bottom, SessionDashboardLayout.headerBottomPadding)
        .listRowInsets(SessionDashboardLayout.headerInsets)
        .accessibilityLabel(title)
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
        .accessibilityHint(isExpanded ? "Double tap to hide sessions" : "Double tap to show sessions")
    }
}

struct SessionDashboardRow: View {
    let session: CachedSession
    let isSelected: Bool

    private var status: SessionDashboardStatus {
        SessionDashboardStatus(session: session)
    }

    private var accessibilityLabel: String {
        "\(session.dashboardTitle), \(status.accessibilityLabel), last active \(session.formattedDate)"
    }

    var body: some View {
        HStack(spacing: SessionDashboardLayout.iconTextSpacing) {
            SessionDashboardStatusIcon(status: status)
                .frame(
                    width: SessionDashboardLayout.iconColumnWidth,
                    height: SessionDashboardLayout.iconColumnWidth
                )

            Text(session.dashboardTitle)
                .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .medium))
                .foregroundStyle(.tronTextPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 10)

            Text(session.compactDate)
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                .foregroundStyle(.tronTextMuted)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.leading, 0)
        .padding(.horizontal, SessionDashboardLayout.outerHorizontalPadding)
        .padding(.vertical, SessionDashboardLayout.rowVerticalPadding)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.tronEmerald.opacity(0.12))
            }
        }
        .contentShape(Rectangle())
        .hoverEffect(.highlight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }
}

private struct SessionDashboardStatusIcon: View {
    let status: SessionDashboardStatus

    var body: some View {
        Group {
            if status == .processing {
                ProgressView()
                    .controlSize(.small)
                    .tint(status.color)
            } else {
                Image(systemName: status.symbolName)
                    .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .semibold))
                    .foregroundStyle(status.color)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct SessionDashboardEmptyState: View {
    var body: some View {
        VStack(spacing: 16) {
            Image("TronLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 80)

            Text("Start talking")
                .font(TronTypography.messageBody)
                .foregroundStyle(.tronTextMuted)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Floating New Session Button (iOS 26 Liquid Glass)

internal enum FloatingNewSessionButtonAccessibility {
    static let label = "New Session"
    static let hint = "Opens the new session sheet"
}

struct FloatingNewSessionButton: View {
    let action: () -> Void
    var onLongPress: (() -> Void)? = nil
    var size: CGFloat = 44
    var accent: Color = .tronEmerald

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(accent.opacity(0.25)).interactive(), in: .circle)
        .accessibilityLabel(FloatingNewSessionButtonAccessibility.label)
        .accessibilityHint(FloatingNewSessionButtonAccessibility.hint)
        .onLongPressGesture(minimumDuration: 0.5) {
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
            onLongPress?() ?? action()
        }
    }
}
