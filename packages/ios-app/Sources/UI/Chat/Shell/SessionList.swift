import SwiftUI

// MARK: - List Projection

struct SessionListWorkspaceGroup: Identifiable {
    let path: String
    let name: String
    let sessions: [CachedSession]

    var id: String { path.isEmpty ? "__default_workspace__" : path }

    static func groups(from sessions: [CachedSession]) -> [SessionListWorkspaceGroup] {
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
            return SessionListWorkspaceGroup(
                path: path,
                name: CachedSession.workspaceDisplayName(for: path),
                sessions: sessions
            )
        }
    }
}

struct SessionListWorkspaceExpansion: Equatable {
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

enum SessionListLayout {
    static let rowContainerHorizontalInset: CGFloat = 16
    static let rowContentHorizontalPadding: CGFloat = 12
    static var headerLeadingPadding: CGFloat {
        rowContainerHorizontalInset + rowContentHorizontalPadding
    }
    static var headerTrailingPadding: CGFloat {
        rowContainerHorizontalInset
    }
    static let iconColumnWidth: CGFloat = 18
    static let iconTextSpacing: CGFloat = 8
    static let minimumRowHeight: CGFloat = 38
    static let listTopContentMargin: CGFloat = 38
    static let listBottomContentMargin: CGFloat = 92
    static let headerTopPadding: CGFloat = 10
    static let headerBottomPadding: CGFloat = 3
    static let rowVerticalPadding: CGFloat = 7
    static let rowTrailingMinimumSpacing: CGFloat = 10
    static let rowContainerCornerRadius: CGFloat = 12
    static let deletingRowOpacity = 0.45
    static let floatingButtonSize: CGFloat = 56
    static let floatingButtonTrailingPadding: CGFloat = 20
    static let floatingButtonBottomPadding: CGFloat = 8
    static let headerIconSize: CGFloat = 14
    static let headerChevronSize: CGFloat = 10
    static let headerTitleSize: CGFloat = TronTypography.sizeBodyLG
    static let rowTitleSize: CGFloat = TronTypography.sizeBody3
    static let expansionAnimation = Animation.snappy(duration: 0.14)

    static var headerInsets: EdgeInsets {
        EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
    }

    static var rowInsets: EdgeInsets {
        EdgeInsets(
            top: 2,
            leading: rowContainerHorizontalInset,
            bottom: 2,
            trailing: rowContainerHorizontalInset
        )
    }
}

enum SessionListStatus: Equatable {
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

// MARK: - List Views

struct SessionWorkspaceHeader: View {
    let title: String
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: SessionListLayout.iconTextSpacing) {
                Image(systemName: isExpanded ? "folder.fill" : "folder")
                    .font(.system(size: SessionListLayout.headerIconSize, weight: .semibold))
                    .frame(
                        width: SessionListLayout.iconColumnWidth,
                        height: SessionListLayout.iconColumnWidth
                    )
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)

                Text(title)
                    .font(TronTypography.sans(size: SessionListLayout.headerTitleSize, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Image(systemName: "chevron.right")
                    .font(.system(size: SessionListLayout.headerChevronSize, weight: .bold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.tronEmerald)
            .padding(.leading, SessionListLayout.headerLeadingPadding)
            .padding(.trailing, SessionListLayout.headerTrailingPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .animation(SessionListLayout.expansionAnimation, value: isExpanded)
        }
        .buttonStyle(.plain)
        .textCase(nil)
        .padding(.top, SessionListLayout.headerTopPadding)
        .padding(.bottom, SessionListLayout.headerBottomPadding)
        .listRowInsets(SessionListLayout.headerInsets)
        .accessibilityLabel(title)
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
        .accessibilityHint(isExpanded ? "Double tap to hide sessions" : "Double tap to show sessions")
    }
}

struct SessionListRow: View {
    let session: CachedSession
    let isSelected: Bool

    private var status: SessionListStatus {
        SessionListStatus(session: session)
    }

    private var accessibilityLabel: String {
        "\(session.listTitle), \(status.accessibilityLabel), last active \(session.formattedDate)"
    }

    var body: some View {
        HStack(alignment: .center, spacing: SessionListLayout.iconTextSpacing) {
            SessionListStatusIcon(status: status)
                .frame(
                    width: SessionListLayout.iconColumnWidth,
                    height: SessionListLayout.iconColumnWidth
                )

            Text(session.listTitle)
                .font(TronTypography.sans(size: SessionListLayout.rowTitleSize, weight: .medium))
                .foregroundStyle(.tronTextPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: SessionListLayout.rowTrailingMinimumSpacing)

            Text(session.compactDate)
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                .foregroundStyle(.tronTextMuted)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, SessionListLayout.rowContentHorizontalPadding)
        .padding(.vertical, SessionListLayout.rowVerticalPadding)
        .contentShape(Rectangle())
        .hoverEffect(.highlight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }
}

private struct SessionListStatusIcon: View {
    let status: SessionListStatus

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
