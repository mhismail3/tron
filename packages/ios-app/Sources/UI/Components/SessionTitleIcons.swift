import SwiftUI

/// Small metadata icon shown immediately before a forked session's title.
///
/// Shared by the chat toolbar and the sidebar row so both read from the same
/// composition and remain visually identical.
///
/// The icons are purely decorative — the surrounding row/toolbar supplies
/// an accessibility label that announces the forked state ("…, forked").
struct SessionTitleIcons: View {
    let isFork: Bool

    static let forkColor: Color = .tronCoral

    enum Icon: Hashable { case fork }

    /// Pure, view-free computation of which icons should render. Used by the
    /// view body below and by unit tests to verify presentation rules.
    static func iconsShown(isFork: Bool) -> Set<Icon> {
        isFork ? [.fork] : []
    }

    static func accessibilityDescriptors(isFork: Bool) -> [String] {
        var descriptors: [String] = []
        if isFork { descriptors.append("forked") }
        return descriptors
    }

    var body: some View {
        let icons = Self.iconsShown(isFork: isFork)
        HStack(alignment: .center, spacing: 6) {
            if icons.contains(.fork) {
                Image(systemName: "tuningfork")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 11, height: 11)
                    .foregroundStyle(Self.forkColor)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}
