import SwiftUI
import TronMobileCore

// The one list standard for Manage Home and Manage Session subsheets (#1691):
// short fixed sets are one sectioned glass group of joined rows; unbounded
// feeds are separate glass cards that load themselves. Every row has the same
// anatomy, so sheets only map their data into `TronListRowContent`.

/// A quiet metadata pill: kind, scope or project. Mono only for IDs, paths and durations.
struct TronListTag: Hashable, Sendable {
    let text: String
    var mono = false
}

/// The one status pill a row may carry, top-right.
struct TronListStatus: Equatable {
    let text: String
    let tone: Color
    /// Work in progress shows a dot before the word.
    var live = false
}

enum TronListLeading: Equatable {
    /// A kind icon; only where the kind varies within the section.
    case icon(String, Color)
    /// A reading-order number (Instructions).
    case ordinal(Int)
}

struct TronListRowContent {
    var leading: TronListLeading?
    let title: String
    /// Content rows show up to three regular lines instead of a two-line title.
    var preview = false
    var monoTitle = false
    var status: TronListStatus?
    var subtext: String?
    /// A path or ID subtext reads in mono and shortens in the middle.
    var monoSubtext = false
    var tags: [TronListTag] = []
    var timestamp: String?
    var accessibilityHint: String?
    /// Name the row by its title alone and read status and details as its value,
    /// for rows whose title is a stable name (a subagent) rather than content.
    var accessibilityValueHoldsDetails = false

    private var details: [String] {
        [status?.text, subtext, tags.map(\.text).joined(separator: ", "), timestamp]
            .compactMap { $0 }.filter { !$0.isEmpty }
    }
    var accessibilityLabelText: String {
        accessibilityValueHoldsDetails ? title : ([title] + details).joined(separator: ", ")
    }
    var accessibilityValueText: String { accessibilityValueHoldsDetails ? details.joined(separator: ", ") : "" }
}

enum TronListMetrics {
    static let horizontalPadding: CGFloat = 14
    static let verticalPadding: CGFloat = 12
    static let slotGap: CGFloat = 12
    static let lineGap: CGFloat = 4
    static let leadingWidth: CGFloat = 26
    static let iconSize: CGFloat = 18
    static let minimumHeight: CGFloat = 48
    static let feedGap: CGFloat = 8
    static let cornerRadius: CGFloat = 16
    /// Dividers start at the text column.
    static func dividerInset(hasLeading: Bool) -> CGFloat {
        hasLeading ? horizontalPadding + leadingWidth + slotGap : horizontalPadding
    }
}

/// A row's anatomy: leading slot (vertically centred) → title or preview with
/// one status pill top-right → subtext → tags on the left and time on the right.
struct TronListRow: View {
    let content: TronListRowContent
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(_ content: TronListRowContent) { self.content = content }

    var body: some View {
        HStack(alignment: .center, spacing: TronListMetrics.slotGap) {
            if let leading = content.leading { TronListLeadingView(leading: leading) }
            VStack(alignment: .leading, spacing: TronListMetrics.lineGap) {
                titleLine
                if let subtext = content.subtext, !subtext.isEmpty {
                    Text(subtext)
                        .font(content.monoSubtext ? TronTypography.code(size: TronTypography.sizeSecondary) : TronTypography.settingsRowSubtext)
                        .foregroundStyle(Color.tronTextSecondary)
                        .lineLimit(content.monoSubtext ? 1 : 2)
                        .truncationMode(content.monoSubtext ? .middle : .tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !content.tags.isEmpty || content.timestamp != nil { metadataLine }
            }
        }
        .padding(.horizontal, TronListMetrics.horizontalPadding)
        .padding(.vertical, TronListMetrics.verticalPadding)
        .frame(maxWidth: .infinity, minHeight: TronListMetrics.minimumHeight, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.accessibilityLabelText)
        .accessibilityValue(content.accessibilityValueText)
        .accessibilityHint(content.accessibilityHint ?? "")
    }

    @ViewBuilder private var titleLine: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 10))
        layout {
            Text(content.title)
                .font(content.monoTitle ? TronTypography.code(size: TronTypography.sizeBody3)
                    : TronTypography.sans(size: TronTypography.sizeBody, weight: content.preview ? .regular : .semibold))
                .foregroundStyle(Color.tronTextPrimary)
                .lineLimit(content.preview ? 3 : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let status = content.status {
                TronListStatusPill(status: status).tronListMarker(.status)
            }
        }
    }

    private var metadataLine: some View {
        HStack(alignment: .center, spacing: 8) {
            TronListTags(tags: content.tags)
            if let timestamp = content.timestamp {
                Text(timestamp)
                    .font(TronTypography.bodySM)
                    .foregroundStyle(Color.tronTextMuted)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.top, 2)
    }

}

private struct TronListLeadingView: View {
    let leading: TronListLeading
    var body: some View {
        Group {
            switch leading {
            case .icon(let symbol, let tone):
                Image(systemName: symbol)
                    .font(.system(size: TronListMetrics.iconSize, weight: .medium))
                    .foregroundStyle(tone)
            case .ordinal(let number):
                Text(number.formatted())
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.tronEmerald)
                    .frame(width: 24, height: 24)
                    .overlay(Circle().strokeBorder(Color.tronEmerald, lineWidth: 1.5))
            }
        }
        .frame(width: TronListMetrics.leadingWidth)
        .tronListMarker(.leading)
    }
}

/// Exactly one per row, tinted by state.
struct TronListStatusPill: View {
    let status: TronListStatus
    var body: some View {
        HStack(spacing: 5) {
            if status.live { Circle().fill(status.tone).frame(width: 6, height: 6) }
            Text(status.text)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(status.tone)
        .padding(.horizontal, 9).padding(.vertical, 3)
        .background(Capsule().fill(status.tone.opacity(0.15)))
        .overlay(Capsule().strokeBorder(status.tone.opacity(0.3), lineWidth: 0.5))
        .fixedSize()
    }
}

/// Neutral pills, never tinted by state.
struct TronListTags: View {
    let tags: [TronListTag]
    var body: some View {
        // Tags that do not fit drop from the end rather than wrapping the line.
        ViewThatFits(in: .horizontal) {
            ForEach(Array(stride(from: tags.count, through: 0, by: -1)), id: \.self) { count in
                HStack(spacing: 5) {
                    ForEach(Array(tags.prefix(count).enumerated()), id: \.offset) { _, tag in TronListTagPill(tag: tag) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TronListTagPill: View {
    let tag: TronListTag
    var body: some View {
        Text(tag.text)
            .font(tag.mono ? TronTypography.code(size: TronTypography.sizeSecondary) : TronTypography.sans(size: TronTypography.sizeBodySM, weight: .medium))
            .foregroundStyle(Color.tronTextSecondary)
            .lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.tronTextPrimary.opacity(0.06)))
            .fixedSize()
    }
}

// MARK: - Grouped lists

/// One section of a grouped list: rows plus an optional in-container header.
struct TronListSection<Row: Identifiable> {
    let title: String?
    let rows: [Row]
    var id: String { title ?? "rows" }
}

/// Short, fixed sets: one sectioned glass container, joined rows, inset dividers.
/// Section headers sit inside the container; a thin band separates sections.
struct TronListGroup<Row: Identifiable, RowView: View>: View {
    let sections: [TronListSection<Row>]
    var hasLeading = false
    var identifier: String?
    @ViewBuilder let row: (Row) -> RowView

    init(_ rows: [Row], hasLeading: Bool = false, identifier: String? = nil, @ViewBuilder row: @escaping (Row) -> RowView) {
        sections = [TronListSection(title: nil, rows: rows)]
        self.hasLeading = hasLeading; self.identifier = identifier; self.row = row
    }

    init(sections: [TronListSection<Row>], hasLeading: Bool = false, identifier: String? = nil, @ViewBuilder row: @escaping (Row) -> RowView) {
        self.sections = sections.filter { !$0.rows.isEmpty }
        self.hasLeading = hasLeading; self.identifier = identifier; self.row = row
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                if index > 0 {
                    Rectangle().fill(Color.tronTextPrimary.opacity(0.04)).frame(height: 6)
                        .overlay(alignment: .top) { TronListDivider(inset: 0) }
                        .overlay(alignment: .bottom) { TronListDivider(inset: 0) }
                }
                if let title = section.title {
                    HStack(alignment: .firstTextBaseline) {
                        Text(title).font(TronTypography.sheetSectionHeader).foregroundStyle(Color.tronAccentText)
                        Spacer(minLength: 8)
                        Text(section.rows.count.formatted()).font(TronTypography.bodySM).foregroundStyle(Color.tronTextMuted)
                    }
                    .padding(.horizontal, TronListMetrics.horizontalPadding)
                    .padding(.top, 12).padding(.bottom, 2)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                }
                ForEach(Array(section.rows.enumerated()), id: \.element.id) { rowIndex, item in
                    if rowIndex > 0 { TronListDivider(inset: TronListMetrics.dividerInset(hasLeading: hasLeading)) }
                    row(item)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tronGlassSurface(accent: .tronEmerald, cornerRadius: TronListMetrics.cornerRadius, tintOpacity: 0.10)
        .clipShape(RoundedRectangle(cornerRadius: TronListMetrics.cornerRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier ?? "")
    }
}

struct TronListDivider: View {
    let inset: CGFloat
    var body: some View {
        Rectangle().fill(Color.tronTextPrimary.opacity(0.09)).frame(height: 0.5)
            .padding(.leading, inset)
            .accessibilityHidden(true)
    }
}

/// A row as a tappable grouped-list or feed entry, with an optional long-press menu
/// that must offer exactly the actions its detail subsheet holds.
struct TronListButton<Menu: View>: View {
    let content: TronListRowContent
    let identifier: String
    let action: () -> Void
    @ViewBuilder let menu: () -> Menu

    init(_ content: TronListRowContent, identifier: String, action: @escaping () -> Void,
         @ViewBuilder menu: @escaping () -> Menu = { EmptyView() }) {
        self.content = content; self.identifier = identifier; self.action = action; self.menu = menu
    }

    var body: some View {
        Button(action: action) { TronListRow(content) }
            .buttonStyle(.plain)
            .accessibilityLabel(content.accessibilityLabelText)
            .accessibilityValue(content.accessibilityValueText)
            .accessibilityHint(content.accessibilityHint ?? "")
            .contextMenu { menu() }
            .accessibilityIdentifier(identifier)
            .tronListMarkers(identifier)
    }
}

/// A feed entry: one uniform glass card per row.
struct TronFeedCard<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        content()
            .tronScrollSurface(accent: .tronEmerald, cornerRadius: TronListMetrics.cornerRadius, tintOpacity: 0.07)
            .environment(\.tronSettingsVisualTheme, nil)
    }
}

// MARK: - Feeds

/// The tail of a feed: loading, failed with Retry, or the end.
enum TronFeedTail: Equatable {
    case idle
    case loading
    case failed(String)
    case end(String)
}

struct TronFeedStateRow: View {
    let tail: TronFeedTail
    var retry: () -> Void = {}
    var body: some View {
        switch tail {
        case .idle: Color.clear.frame(height: 1).accessibilityHidden(true)
        case .loading:
            TronFeedCard {
                HStack(spacing: 10) {
                    ProgressView().tint(.tronEmerald)
                    Text("Loading more…").font(TronTypography.settingsRowSubtext).foregroundStyle(Color.tronTextSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 52)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("feed-loading")
        case .failed(let message):
            TronFeedCard {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.tronAmber)
                    Text(message).font(TronTypography.settingsRowSubtext).foregroundStyle(Color.tronTextSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(action: retry) { TronInlineActionLabel("Retry", accent: .tronEmerald) }
                        .buttonStyle(.plain).accessibilityIdentifier("feed-retry")
                }
                .padding(.horizontal, TronListMetrics.horizontalPadding).frame(minHeight: 52)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("feed-error")
        case .end(let text):
            HStack(spacing: 10) {
                TronListDivider(inset: 0)
                Text(text).font(TronTypography.bodySM).foregroundStyle(Color.tronTextMuted).fixedSize()
                TronListDivider(inset: 0)
            }
            .padding(.vertical, 12).padding(.horizontal, 4)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("feed-end")
        }
    }
}

/// Where the reader is in a long feed. Kept outside the feed's own view state so
/// scrolling republishes only the chip, never the row collection.
@MainActor @Observable
final class TronFeedPosition {
    var newest: Int?
    var oldest: Int?
    var long = false
    static let hysteresis: CGFloat = 60
}

/// "6,689–6,714 of 6,733", newest first; tapping jumps to the newest entry.
struct TronFeedPositionChip: View {
    let position: TronFeedPosition
    let total: Int?
    let totalIsExact: Bool
    let jump: () -> Void

    var body: some View {
        if position.long, let newest = position.newest, let oldest = position.oldest {
            let low = min(newest, oldest), high = max(newest, oldest)
            Button(action: jump) {
                HStack(spacing: 8) {
                    Text("\(low.formatted())–\(high.formatted())").font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(Color.tronTextPrimary)
                    if let total {
                        Text("of \(total.formatted())\(totalIsExact ? "" : "+")").font(TronTypography.bodySM).foregroundStyle(Color.tronTextMuted)
                        bar(low: low, high: high, total: total)
                    }
                    Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.tronEmerald)
                }
                .monospacedDigit()
                .padding(.horizontal, 13).frame(height: 30)
                .glassEffect(.regular.interactive(), in: Capsule())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .accessibilityLabel("Entries \(low.formatted()) to \(high.formatted())\(total.map { " of \($0.formatted())" } ?? "")")
            .accessibilityHint("Jumps to the newest entry")
            .accessibilityIdentifier("feed-position-chip")
        }
    }

    private func bar(low: Int, high: Int, total: Int) -> some View {
        let start = Double(max(0, low - 1)) / Double(max(total, 1))
        let length = max(Double(high - low + 1) / Double(max(total, 1)), 0.04)
        return Capsule().fill(Color.tronTextPrimary.opacity(0.1)).frame(width: 44, height: 4)
            .overlay(alignment: .leading) {
                Capsule().fill(Color.tronEmerald).frame(width: 44 * min(length, 1), height: 4)
                    .offset(x: 44 * min(start, 1 - min(length, 1)))
            }
            .accessibilityHidden(true)
    }
}

/// An unbounded feed: newest first, one card per row, loading itself before the
/// reader reaches the bottom. Rows render lazily; only the chip observes scrolling.
struct TronFeed<Item: Identifiable, Header: View, Row: View>: View where Item.ID: Hashable & Sendable {
    let items: [Item]
    let identifier: String
    /// Canonical ordinal shown in the chip (1 = oldest), or a 1-based position when unknown.
    let ordinal: (Item) -> Int
    let total: Int?
    var totalIsExact = true
    let tail: TronFeedTail
    let loadMore: () -> Void
    let retry: () -> Void
    @ViewBuilder let header: () -> Header
    @ViewBuilder let row: (Item) -> Row
    @State private var position = TronFeedPosition()
    @State private var ordinals: [Item.ID: Int] = [:]

    var body: some View {
        // Prefetch while five rows remain; the tail row also asks, so a fast
        // fling past the trigger still loads.
        let trigger = items.count > 5 ? items[items.count - 5].id : items.last?.id
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: TronListMetrics.feedGap) {
                    header()
                    ForEach(items) { item in
                        row(item)
                            .id(item.id)
                            .onAppear { if item.id == trigger { loadMore() } }
                    }
                    TronFeedStateRow(tail: tail, retry: retry)
                        .onAppear { if tail == .idle { loadMore() } }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 24)
            }
            // The chip floats above the feed rather than inside the lazy stack, so
            // updating it never re-places rows (a pinned header did, without end).
            .safeAreaInset(edge: .top, spacing: 0) {
                TronFeedPositionChip(position: position, total: total, totalIsExact: totalIsExact) {
                    guard let first = items.first?.id else { return }
                    withAnimation(.snappy) { reader.scrollTo(first, anchor: .top) }
                }
            }
            .tronScrollEdgeChrome()
            // The chip adds its own height, so it hides only well below the threshold
            // that shows it; otherwise a feed near one screen would toggle it forever.
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height - $0.containerSize.height } action: { _, excess in
                if position.long { if excess < -TronFeedPosition.hysteresis { position.long = false } }
                else if excess > 1 { position.long = true }
            }
            .onScrollTargetVisibilityChange(idType: Item.ID.self, threshold: 0.3) { visible in
                // Keep the last range while no row is visible, and publish only a
                // real change: the chip must never resize the feed under the reader.
                let values = visible.compactMap { ordinals[$0] }
                guard let newest = values.max(), let oldest = values.min(),
                      newest != position.newest || oldest != position.oldest else { return }
                position.newest = newest; position.oldest = oldest
            }
            .onChange(of: items.count, initial: true) { _, _ in
                ordinals = Dictionary(items.map { ($0.id, ordinal($0)) }, uniquingKeysWith: { first, _ in first })
            }
            .accessibilityIdentifier(identifier)
        }
    }
}

// MARK: - Geometry markers (hosted UI tests only)

enum TronListMarkerKind: String { case leading, status }

private struct TronListMarkerKey: PreferenceKey {
    static let defaultValue: [TronListMarkerKind: Anchor<CGRect>] = [:]
    static func reduce(value: inout [TronListMarkerKind: Anchor<CGRect>], nextValue: () -> [TronListMarkerKind: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Publishes a slot's frame so a hosted UI test can measure the real layout;
    /// the combined row element otherwise hides its children.
    func tronListMarker(_ kind: TronListMarkerKind) -> some View {
        #if HOSTED_TEST
        anchorPreference(key: TronListMarkerKey.self, value: .bounds) { [kind: $0] }
        #else
        self
        #endif
    }

    func tronListMarkers(_ identifier: String) -> some View {
        #if HOSTED_TEST
        overlayPreferenceValue(TronListMarkerKey.self) { anchors in
            GeometryReader { proxy in
                ForEach(Array(anchors.keys), id: \.rawValue) { kind in
                    let rect = proxy[anchors[kind]!]
                    Color.clear.frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .accessibilityElement()
                        .accessibilityLabel(kind.rawValue)
                        .accessibilityIdentifier("\(identifier)-\(kind.rawValue)")
                        .allowsHitTesting(false)
                }
            }
        }
        #else
        self
        #endif
    }
}

// MARK: - Time

enum TronListTime {
    /// "38m ago" under a day, then "Oct 21" (with the year when not this year).
    static func short(_ date: Date, now: Date = .now) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 && seconds > -60 { return "now" }
        if seconds > 0 && seconds < 3_600 { return "\(Int(seconds / 60))m ago" }
        if seconds > 0 && seconds < 86_400 { return "\(Int(seconds / 3_600))h ago" }
        let sameYear = Calendar.current.isDate(date, equalTo: now, toGranularity: .year)
        return date.formatted(sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year())
    }

    static func short(iso: String?, now: Date = .now) -> String? {
        guard let iso, let date = GatewayTimestamp.parse(iso) else { return nil }
        return short(date, now: now)
    }

    static func short(milliseconds: Int, now: Date = .now) -> String {
        short(Date(timeIntervalSince1970: Double(milliseconds) / 1_000), now: now)
    }
}
