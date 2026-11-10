import Foundation
import SwiftUI
import TronMobileCore

enum ProviderUsagePresentation {
    static let loadingPlaceholder = "00% used (5h) · 00% used (Weekly)"
    static let loadingPlaceholderParts = [
        WindowPart(text: "00% (5h)", usedPercent: 0),
        WindowPart(text: "00% (Weekly)", usedPercent: 0),
    ]

    enum Level: Equatable {
        case normal, warning, exhausted

        static let warningPercent: Double = 60

        var accent: Color? {
            switch self {
            case .normal: nil
            case .warning: .tronAmber
            case .exhausted: Color.tronError.opacity(0.75)
            }
        }
    }

    static func level(_ window: UsageWindow) -> Level {
        let percent: Double?
        if let used = window.usedPercent {
            percent = used
        } else if let used = window.used, let limit = window.limit, limit > 0 {
            percent = used / limit * 100
        } else {
            percent = nil
        }
        guard let percent else { return .normal }
        if percent >= 100 { return .exhausted }
        return percent >= Level.warningPercent ? .warning : .normal
    }

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

    static func hasDetailContent(_ snapshot: ProviderUsageSnapshot) -> Bool {
        guard snapshot.status == .available || snapshot.status == .rateLimited else { return false }
        return !snapshot.windows.isEmpty || !snapshot.balances.isEmpty || retryCopy(snapshot) != nil
    }

    static func lenderName(_ snapshot: ProviderUsageSnapshot) -> String? {
        guard snapshot.source == "openai-codex.wham", snapshot.providerId != "openai-codex" else { return nil }
        return "OpenAI Codex (legacy)"
    }

    static func summary(_ snapshot: ProviderUsageSnapshot) -> String {
        summarySegments(snapshot).map(\.text).joined(separator: " · ")
    }

    static func styledSummary(_ snapshot: ProviderUsageSnapshot) -> AttributedString {
        var line = AttributedString()
        for (index, segment) in summarySegments(snapshot).enumerated() {
            if index > 0 { line += AttributedString(" · ") }
            var part = AttributedString(segment.text)
            if let accent = segment.level.accent { part.foregroundColor = accent }
            line += part
        }
        return line
    }

    private static func summarySegments(_ snapshot: ProviderUsageSnapshot) -> [WindowPart] {
        guard snapshot.status == .available || snapshot.status == .rateLimited else {
            if snapshot.status == .unconfigured, let lender = lenderName(snapshot) {
                return [WindowPart(text: "Sign in to \(lender) to view plan usage", usedPercent: nil)]
            }
            return [WindowPart(text: statusCopy(snapshot.status), usedPercent: nil)]
        }
        var parts = windowParts(snapshot)
        guard !parts.isEmpty else {
            return [WindowPart(text: snapshot.stale ? "Usage unavailable · Last known data is stale" : statusCopy(snapshot.status), usedPercent: nil)]
        }
        if snapshot.status == .rateLimited { parts.insert(WindowPart(text: statusCopy(snapshot.status), usedPercent: nil), at: 0) }
        if snapshot.stale { parts.append(WindowPart(text: "Stale", usedPercent: nil)) }
        return parts
    }

    struct WindowPart: Equatable {
        let text: String
        let usedPercent: Double?
        var level = Level.normal
    }

    static func windowParts(_ snapshot: ProviderUsageSnapshot, columns: Bool = false) -> [WindowPart] {
        guard snapshot.status == .available || snapshot.status == .rateLimited else { return [] }
        var parts: [WindowPart] = []
        let windows = summaryWindows(snapshot.windows)
        for (index, window) in windows.enumerated() {
            guard let value = windowSummary(window, columns: columns) else { continue }
            let shouldLabel = windows.count > 1 || index > 0 || cadenceLabel(window.windowSeconds) != nil
            let text = shouldLabel ? "\(value) (\(summaryLabel(window.label, windowSeconds: window.windowSeconds)))" : value
            parts.append(WindowPart(text: text, usedPercent: window.usedPercent, level: level(window)))
        }
        if parts.isEmpty, let balance = snapshot.balances.first {
            parts.append(WindowPart(text: "\(currency(balance.amount, code: balance.currency)) \(balance.label)", usedPercent: nil))
        }
        return parts
    }

    static func summaryWindows(_ windows: [UsageWindow]) -> [UsageWindow] {
        var shown: [UsageWindow] = []
        var cadences = Set<String>()
        for (index, window) in windows.enumerated() {
            if let cadence = cadenceLabel(window.windowSeconds) {
                if cadences.insert(cadence).inserted { shown.append(window) }
            } else if index < 2 {
                shown.append(window)
            }
        }
        return shown
    }

    static func windowPartsNote(_ snapshot: ProviderUsageSnapshot) -> String? {
        var notes: [String] = []
        if snapshot.status == .rateLimited { notes.append(statusCopy(snapshot.status)) }
        if snapshot.stale { notes.append("Stale") }
        return notes.isEmpty ? nil : notes.joined(separator: " · ")
    }

    static func windowSummary(_ window: UsageWindow, columns: Bool = false) -> String? {
        let used = columns ? "" : " used"
        if let percent = window.usedPercent {
            return "\(number(percent))%\(used)"
        }
        if let usedAmount = window.used, let limit = window.limit, limit > 0 {
            return "\(amount(usedAmount))/\(amount(limit))\(window.unit.map { " \($0)" } ?? "")\(used)"
        }
        if let usedAmount = window.used {
            return "\(amount(usedAmount))\(window.unit.map { " \($0)" } ?? "")\(used)"
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
        let lender = lenderName(snapshot).map { " · From your \($0) sign-in" } ?? ""
        return "Updated \(date.formatted(date: .abbreviated, time: .shortened))\(snapshot.stale ? " · Stale" : "")\(lender)"
    }

    static func retryCopy(_ snapshot: ProviderUsageSnapshot) -> String? {
        guard snapshot.status == .rateLimited,
              let retryAt = snapshot.retryAt,
              let date = GatewayTimestamp.parse(retryAt) else { return nil }
        return "Retry after \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    static func balanceShare(_ balance: UsageBalance, of primary: UsageBalance) -> Double? {
        guard primary.amount > 0, balance.amount >= 0,
              balance.currency.caseInsensitiveCompare(primary.currency) == .orderedSame else { return nil }
        return min(100, max(0, balance.amount / primary.amount * 100))
    }

    static func balanceShareCaption(_ share: Double, of primary: UsageBalance) -> String {
        "\(number(share))% of \(primary.label.lowercased())"
    }

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
                                .foregroundStyle(ProviderUsagePresentation.level(window).accent ?? Color.tronTextSecondary)
                        }
                        .font(detailFont)
                        .foregroundStyle(Color.tronTextSecondary)
                        if let percent = window.usedPercent {
                            ProviderUsageProgress(percent: percent, accent: ProviderUsagePresentation.level(window).accent ?? .tronEmerald)
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
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct ProviderUsageSummaryHeader: View {
    let snapshot: ProviderUsageSnapshot
    @Environment(\.tronSettingsSecondaryTextSizeAdjustment) private var secondaryTextSizeAdjustment

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(ProviderUsagePresentation.styledSummary(snapshot))
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
    static let height: CGFloat = 5

    let percent: Double
    let accent: Color
    var fillProbe: String? = nil

    static func fillWidth(percent: Double, trackWidth: CGFloat, height: CGFloat = height) -> CGFloat {
        let clamped = min(max(percent, 0), 100)
        guard clamped > 0, trackWidth > 0 else { return 0 }
        return min(trackWidth, max(height, trackWidth * clamped / 100))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(accent.opacity(0.16))
                Capsule().fill(accent)
                    .frame(width: Self.fillWidth(percent: percent, trackWidth: proxy.size.width, height: proxy.size.height))
                    .homeUsageLayoutProbe(fillProbe)
            }
        }
        .frame(height: Self.height)
        .accessibilityHidden(true)
    }
}

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

struct ProviderUsageLoadingLine: View {
    @Environment(\.tronSettingsSecondaryTextSizeAdjustment) private var secondaryTextSizeAdjustment

    var body: some View {
        ProviderUsageLoadingPlaceholder {
            Text(verbatim: ProviderUsagePresentation.loadingPlaceholder)
                .font(TronTypography.settingsSubtext(adjustment: secondaryTextSizeAdjustment))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ProviderUsageLoadingPlaceholder<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.tronPresentationActivity) private var presentationActivity
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
            content()
                .foregroundStyle(Color.tronTextMuted)
                .redacted(reason: .placeholder)
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
