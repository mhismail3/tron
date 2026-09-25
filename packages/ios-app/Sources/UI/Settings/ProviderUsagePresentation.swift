import Foundation
import SwiftUI

enum ProviderUsagePresentation {
    /// Skeleton copy shown while a supported row waits for its first snapshot.
    /// It shares the usage line's font and stays single-line at ordinary widths
    /// so the resolved text does not change the row height.
    static let loadingPlaceholder = "00% used (5h) · 00% used (Weekly)"

    /// A supported configured row reserves its usage line while the bounded read
    /// is pending. Once the read settles, the snapshot (or its absence) owns the
    /// line, so a failed read never leaves a permanent skeleton.
    static func showsUsageLoadingLine(
        snapshot: ProviderUsageSnapshot?,
        configured: Bool,
        usageSupported: Bool,
        capabilityAvailable: Bool,
        readResolved: Bool
    ) -> Bool {
        guard snapshot == nil, configured, usageSupported, capabilityAvailable else { return false }
        return !readResolved
    }

    /// Keep summary-only states from reserving an empty detail row and its gap.
    /// The updated line belongs to the summary header, so it is not detail.
    static func hasDetailContent(_ snapshot: ProviderUsageSnapshot) -> Bool {
        guard snapshot.status == .available || snapshot.status == .rateLimited else { return false }
        return !snapshot.windows.isEmpty || !snapshot.balances.isEmpty || retryCopy(snapshot) != nil
    }

    static func summary(_ snapshot: ProviderUsageSnapshot) -> String {
        guard snapshot.status == .available || snapshot.status == .rateLimited else {
            return statusCopy(snapshot.status)
        }
        var parts: [String] = []
        let windows = snapshot.windows
        for (index, window) in windows.prefix(2).enumerated() {
            guard let value = windowSummary(window) else { continue }
            // A provider can expose both a short window and a weekly quota. Keep
            // both labels so the primary row never hides the meaningful limit.
            // A lone window is labeled only when its duration names a cadence
            // (Codex's single weekly window), not a generic "Primary"/"Usage".
            let shouldLabel = windows.count > 1 || index > 0 || cadenceLabel(window.windowSeconds) != nil
            // The value leads and the window label trails in parentheses: "3% used (5h)".
            parts.append(shouldLabel ? "\(value) (\(summaryLabel(window.label, windowSeconds: window.windowSeconds)))" : value)
        }
        if parts.isEmpty, let balance = snapshot.balances.first {
            // A balance-only provider still presents like its window peers: the
            // localized primary amount followed by its label, e.g. "$0.03 Available".
            parts.append("\(currency(balance.amount, code: balance.currency)) \(balance.label)")
        }
        guard !parts.isEmpty else {
            return snapshot.stale ? "Usage unavailable · Last known data is stale" : statusCopy(snapshot.status)
        }
        if snapshot.status == .rateLimited { parts.insert(statusCopy(snapshot.status), at: 0) }
        if snapshot.stale { parts.append("Stale") }
        return parts.joined(separator: " · ")
    }

    static func windowSummary(_ window: UsageWindow) -> String? {
        if let percent = window.usedPercent {
            return "\(number(percent))% used"
        }
        // Only a positive denominator supports a percentage. Amount-only spend
        // rows stay amount-only rather than implying a quota.
        if let used = window.used, let limit = window.limit, limit > 0 {
            return "\(amount(used))/\(amount(limit))\(window.unit.map { " \($0)" } ?? "") used"
        }
        if let used = window.used {
            return "\(amount(used))\(window.unit.map { " \($0)" } ?? "") used"
        }
        if let remaining = window.remaining {
            return "\(amount(remaining))\(window.unit.map { " \($0)" } ?? "") remaining"
        }
        return nil
    }

    static func detailValue(_ window: UsageWindow) -> String {
        windowSummary(window) ?? "No usage value reported"
    }

    static func quantityDetail(_ window: UsageWindow) -> String? {
        let unit = window.unit.map { " \($0)" } ?? ""
        var parts: [String] = []
        // Percentage summaries must not hide the provider's actual quota amounts.
        if window.usedPercent != nil {
            if let used = window.used { parts.append("\(amount(used))\(unit) used") }
            if let limit = window.limit { parts.append("Limit \(amount(limit))\(unit)") }
        } else if window.used == nil, let limit = window.limit {
            parts.append("Limit \(amount(limit))\(unit)")
        }
        if let remaining = window.remaining, window.usedPercent != nil || window.used != nil {
            parts.append("\(amount(remaining))\(unit) remaining")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func statusCopy(_ status: ProviderUsageStatus) -> String {
        switch status {
        case .available: return "Usage not reported"
        case .unsupported: return "Account usage is not supported by this provider"
        case .unconfigured: return "Connect this provider to view account usage"
        case .authenticationRequired: return "Sign in again to view account usage"
        case .rateLimited: return "Usage temporarily rate limited"
        case .unavailable: return "Account usage is currently unavailable"
        }
    }

    static func cadenceLabel(_ windowSeconds: Int?) -> String? {
        switch windowSeconds {
        case 3_600: return "Hourly"
        case 18_000: return "5h"
        case 86_400: return "Daily"
        case 604_800: return "Weekly"
        case 2_592_000: return "Monthly"
        default: return nil
        }
    }

    static func summaryLabel(_ label: String, windowSeconds: Int? = nil) -> String {
        if let cadence = cadenceLabel(windowSeconds) { return cadence }
        let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.lowercased().contains("week") ? "Weekly" : normalized
    }

    static func updatedCopy(_ snapshot: ProviderUsageSnapshot) -> String? {
        guard let updatedAt = snapshot.updatedAt, let date = GatewayTimestamp.parse(updatedAt) else { return nil }
        return "Updated \(date.formatted(date: .abbreviated, time: .shortened))\(snapshot.stale ? " · Stale" : "")"
    }

    static func retryCopy(_ snapshot: ProviderUsageSnapshot) -> String? {
        guard snapshot.status == .rateLimited,
              let retryAt = snapshot.retryAt,
              let date = GatewayTimestamp.parse(retryAt) else { return nil }
        return "Retry after \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    /// The share of the primary balance a secondary balance represents on the
    /// 0-100 progress scale. Only a positive primary and a non-negative,
    /// same-currency balance can be expressed as a share; a cash deficit is
    /// presented as such instead. The ratio is clamped so an inconsistent
    /// snapshot cannot overflow the bar.
    static func balanceShare(_ balance: UsageBalance, of primary: UsageBalance) -> Double? {
        guard primary.amount > 0, balance.amount >= 0,
              balance.currency.caseInsensitiveCompare(primary.currency) == .orderedSame else { return nil }
        return min(100, max(0, balance.amount / primary.amount * 100))
    }

    static func balanceShareCaption(_ share: Double, of primary: UsageBalance) -> String {
        "\(number(share))% of \(primary.label.lowercased())"
    }

    /// Secondary balance copy when a share cannot be expressed. A negative
    /// balance is a deficit (the provider withheld or owes funds) rather than a
    /// 0% share of the primary.
    static let balanceDeficitCopy = "Deficit"

    static func showsLocalUnlimited(
        configured: Bool,
        localOnly: Bool,
        snapshot: ProviderUsageSnapshot?,
        isLoading: Bool
    ) -> Bool {
        guard snapshot == nil, configured, localOnly else { return false }
        return !isLoading
    }

    /// Currency copy for balance amounts. ICU's currency style supplies the
    /// locale's exact presentation for a reported ISO code ($49.59, CN¥12.50);
    /// anything outside that shape keeps its raw code so an unexpected value is
    /// visible instead of silently re-labeled.
    static func currency(_ amount: Double, code: String) -> String {
        guard code.count == 3, code.allSatisfy({ $0.isASCII && $0.isLetter }) else {
            return "\(Self.amount(amount)) \(code)"
        }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: amount)) ?? "\(Self.amount(amount)) \(code)"
    }

    static func number(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = value.rounded() == value ? 0 : 1
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func amount(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

struct ProviderUsageSummaryView: View {
    let snapshot: ProviderUsageSnapshot
    var detail: Bool = false
    var includeSummary: Bool = true
    @Environment(\.tronSettingsSecondaryTextSizeAdjustment) private var secondaryTextSizeAdjustment

    /// Account usage detail copy uses the app's standard secondary sub-text
    /// treatment: the settings-adjusted secondary size in the reading family
    /// with the standard secondary color. Caption scale was too small here.
    private var detailFont: Font {
        TronTypography.sans(size: TronTypography.sizeSecondary + secondaryTextSizeAdjustment)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if includeSummary {
                ProviderUsageSummaryHeader(snapshot: snapshot)
            }
            if detail && ProviderUsagePresentation.hasDetailContent(snapshot) {
                ForEach(snapshot.windows) { window in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(window.label)
                            Spacer()
                            Text(ProviderUsagePresentation.detailValue(window)).monospacedDigit()
                        }
                        .font(detailFont)
                        .foregroundStyle(Color.tronTextSecondary)
                        if let percent = window.usedPercent {
                            ProviderUsageProgress(percent: percent, accent: .tronEmerald)
                        }
                        if let quantities = ProviderUsagePresentation.quantityDetail(window) {
                            Text(quantities)
                                .font(detailFont)
                                .foregroundStyle(Color.tronTextSecondary)
                        }
                        if let resetsAt = window.resetsAt,
                           let date = GatewayTimestamp.parse(resetsAt) {
                            Text("Resets \(date.formatted(date: .abbreviated, time: .shortened))")
                                .font(detailFont)
                                .foregroundStyle(Color.tronTextSecondary)
                        }
                    }
                }
                let primaryBalance = snapshot.balances.first
                ForEach(Array(snapshot.balances.enumerated()), id: \.element.id) { index, balance in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(balance.label)
                            Spacer()
                            Text(ProviderUsagePresentation.currency(balance.amount, code: balance.currency))
                                .monospacedDigit()
                        }
                        .font(detailFont)
                        .foregroundStyle(Color.tronTextSecondary)
                        // The primary balance is the headline; every later
                        // balance is presented as its share so the group reads
                        // like the window rows above it.
                        if index > 0, let primaryBalance {
                            if let share = ProviderUsagePresentation.balanceShare(balance, of: primaryBalance) {
                                ProviderUsageProgress(percent: share, accent: .tronEmerald)
                                Text(ProviderUsagePresentation.balanceShareCaption(share, of: primaryBalance))
                                    .font(detailFont)
                                    .foregroundStyle(Color.tronTextSecondary)
                            } else if balance.amount < 0 {
                                Text(ProviderUsagePresentation.balanceDeficitCopy)
                                    .font(detailFont)
                                    .foregroundStyle(Color.tronTextSecondary)
                            }
                        }
                    }
                }
                if let retry = ProviderUsagePresentation.retryCopy(snapshot) {
                    Text(retry)
                        .font(detailFont)
                        .foregroundStyle(Color.tronTextSecondary)
                }
                // Gateway message is retained only as the bounded wire field;
                // presentation uses fixed local status copy and never renders
                // upstream error text.
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Usage headline with its "Updated" sub-text. The 2pt gap matches the
/// provider row's line spacing so the header reads as one unit, which the
/// detail sheet centers its refresh control against.
struct ProviderUsageSummaryHeader: View {
    let snapshot: ProviderUsageSnapshot
    @Environment(\.tronSettingsSecondaryTextSizeAdjustment) private var secondaryTextSizeAdjustment

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(ProviderUsagePresentation.summary(snapshot))
                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                .foregroundStyle(Color.tronTextPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Account usage: \(ProviderUsagePresentation.summary(snapshot))")
            if let updated = ProviderUsagePresentation.updatedCopy(snapshot) {
                Text(updated)
                    .font(TronTypography.sans(size: TronTypography.sizeSecondary + secondaryTextSizeAdjustment))
                    .foregroundStyle(Color.tronTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ProviderUsageProgress: View {
    let percent: Double
    let accent: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(accent.opacity(0.16))
                Capsule().fill(accent)
                    .frame(width: proxy.size.width * min(max(percent, 0), 100) / 100)
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}

/// Breathing opacity for the usage skeleton. Kept as pure math so the bounded
/// range is testable without rendering.
enum ProviderUsageLoadingLineEngine {
    static let cycleDuration: Double = 1.8
    static let minimumOpacity: Double = 0.32
    static let maximumOpacity: Double = 0.8

    static func opacity(progress: Double) -> Double {
        let clamped = min(1, max(0, progress))
        let wave = (sin(clamped * 2 * .pi) + 1) / 2
        return minimumOpacity + (maximumOpacity - minimumOpacity) * wave
    }
}

/// Placeholder for the provider row's usage line. It renders the exact usage
/// line layout (same font, same single-line text) with redacted skeleton bars,
/// so the row holds its height while the snapshot is in flight and the resolved
/// text can crossfade in without a layout jump.
struct ProviderUsageLoadingLine: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @Environment(\.tronSettingsSecondaryTextSizeAdjustment) private var secondaryTextSizeAdjustment
    @State private var isVisible = false

    var body: some View {
        TimelineView(.animation(
            minimumInterval: 1 / 30,
            paused: TronPulseLoadingIndicatorEngine.animationPaused(
                reduceMotion: reduceMotion,
                sceneActive: scenePhase == .active,
                surfaceActive: presentationActivity.allowsContinuousAnimation && isVisible
            )
        )) { context in
            Text(verbatim: ProviderUsagePresentation.loadingPlaceholder)
                .font(TronTypography.sans(size: TronTypography.sizeSecondary + secondaryTextSizeAdjustment))
                .foregroundStyle(Color.tronTextMuted)
                .redacted(reason: .placeholder)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(reduceMotion
                    ? ProviderUsageLoadingLineEngine.maximumOpacity
                    : ProviderUsageLoadingLineEngine.opacity(
                        progress: context.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: ProviderUsageLoadingLineEngine.cycleDuration)
                            / ProviderUsageLoadingLineEngine.cycleDuration
                    ))
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .accessibilityLabel("Loading account usage")
    }
}
