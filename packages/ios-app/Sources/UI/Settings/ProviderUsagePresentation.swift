import Foundation
import SwiftUI

enum ProviderUsagePresentation {
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
            let shouldLabel = windows.count > 1 || index > 0
            parts.append(shouldLabel ? "\(summaryLabel(window.label, windowSeconds: window.windowSeconds)) \(value)" : value)
        }
        if parts.isEmpty, let balance = snapshot.balances.first {
            parts.append("\(balance.label): \(amount(balance.amount)) \(balance.currency)")
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

    static func summaryLabel(_ label: String, windowSeconds: Int? = nil) -> String {
        switch windowSeconds {
        case 3_600: return "Hourly"
        case 18_000: return "5h"
        case 86_400: return "Daily"
        case 604_800: return "Weekly"
        case 2_592_000: return "Monthly"
        default: break
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if includeSummary {
                Text(ProviderUsagePresentation.summary(snapshot))
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(Color.tronTextPrimary)
                    .accessibilityLabel("Account usage: \(ProviderUsagePresentation.summary(snapshot))")
            }
            if detail && (snapshot.status == .available || snapshot.status == .rateLimited) {
                ForEach(snapshot.windows) { window in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(window.label)
                            Spacer()
                            Text(ProviderUsagePresentation.detailValue(window)).monospacedDigit()
                        }
                        .font(TronTypography.secondaryDescription)
                        .foregroundStyle(Color.tronTextSecondary)
                        if let percent = window.usedPercent {
                            ProviderUsageProgress(percent: percent, accent: .tronEmerald)
                        }
                        if let quantities = ProviderUsagePresentation.quantityDetail(window) {
                            Text(quantities)
                                .font(TronTypography.caption)
                                .foregroundStyle(Color.tronTextSecondary)
                        }
                        if let resetsAt = window.resetsAt,
                           let date = GatewayTimestamp.parse(resetsAt) {
                            Text("Resets \(date.formatted(date: .abbreviated, time: .shortened))")
                                .font(TronTypography.caption)
                                .foregroundStyle(Color.tronTextMuted)
                        }
                    }
                }
                ForEach(snapshot.balances) { balance in
                    HStack {
                        Text(balance.label)
                        Spacer()
                        Text("\(ProviderUsagePresentation.amount(balance.amount)) \(balance.currency)")
                            .monospacedDigit()
                    }
                    .font(TronTypography.secondaryDescription)
                    .foregroundStyle(Color.tronTextSecondary)
                }
                if let updated = ProviderUsagePresentation.updatedCopy(snapshot) {
                    Text(updated)
                        .font(TronTypography.caption)
                        .foregroundStyle(Color.tronTextMuted)
                }
                if let retry = ProviderUsagePresentation.retryCopy(snapshot) {
                    Text(retry)
                        .font(TronTypography.caption)
                        .foregroundStyle(Color.tronTextMuted)
                }
                // Gateway message is retained only as the bounded wire field;
                // presentation uses fixed local status copy and never renders
                // upstream error text.
            }
        }
        .fixedSize(horizontal: false, vertical: true)
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
