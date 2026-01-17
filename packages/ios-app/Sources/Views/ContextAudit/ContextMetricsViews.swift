import SwiftUI

// MARK: - Token Formatting Helper

func formatTokenCount(_ count: Int) -> String {
    if count >= 1_000_000 {
        return String(format: "%.1fM", Double(count) / 1_000_000)
    } else if count >= 1000 {
        return String(format: "%.1fk", Double(count) / 1000)
    }
    return "\(count)"
}
// MARK: - Total Session Tokens View

@available(iOS 26.0, *)
struct TotalSessionTokensView: View {
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheCreationTokens: Int

    private var totalTokens: Int {
        inputTokens + outputTokens
    }

    /// Whether any cache tokens exist (hides cache section if none)
    private var hasCacheTokens: Bool {
        cacheReadTokens > 0 || cacheCreationTokens > 0
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000)
        }
        return "\(count)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header with explanatory subtitle
            VStack(alignment: .leading, spacing: 2) {
                Text("Session Totals")
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                Text("Accumulated tokens across all turns (for billing)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
            }

            // Main content card
            VStack(spacing: 12) {
                // Header with total
                HStack {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 14))
                        .foregroundStyle(.tronAmberLight)

                    Text("Accumulated")
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tronAmberLight)

                    Spacer()

                    Text(formatTokenCount(totalTokens))
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundStyle(.tronAmberLight)
                }

                // Token breakdown row
                HStack(spacing: 8) {
                    // Input tokens
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.tronOrange)
                            Text("Input")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        Text(formatTokenCount(inputTokens))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tronOrange)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.clear)
                            .glassEffect(.regular.tint(Color.tronOrange.opacity(0.3)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }

                    // Output tokens
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.tronRed)
                            Text("Output")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        Text(formatTokenCount(outputTokens))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tronRed)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.clear)
                            .glassEffect(.regular.tint(Color.tronRed.opacity(0.3)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }

                // Cache tokens row (only shown if cache tokens exist)
                if hasCacheTokens {
                    HStack(spacing: 8) {
                        // Cache read tokens
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                Image(systemName: "bolt.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tronAmber)
                                Text("Cache Read")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                            Text(formatTokenCount(cacheReadTokens))
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(.tronAmber)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.clear)
                                .glassEffect(.regular.tint(Color.tronAmber.opacity(0.3)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }

                        // Cache creation tokens
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                Image(systemName: "memorychip.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tronAmberLight)
                                Text("Cache Write")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                            Text(formatTokenCount(cacheCreationTokens))
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(.tronAmberLight)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.clear)
                                .glassEffect(.regular.tint(Color.tronAmberLight.opacity(0.3)), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }

                // Footer explanation
                Text("Input grows each turn • Output sums all responses")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular.tint(Color.tronBronze.opacity(0.2)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }
}

// MARK: - Context Usage Gauge View

@available(iOS 26.0, *)
struct ContextUsageGaugeView: View {
    let currentTokens: Int
    let contextLimit: Int
    let usagePercent: Double
    let thresholdLevel: String

    private var usageColor: Color {
        switch thresholdLevel {
        case "critical", "exceeded":
            return .tronError
        case "alert":
            return .tronAmber
        case "warning":
            return .tronWarning
        default:
            return .tronCyan
        }
    }

    private var formattedTokens: String {
        formatTokenCount(currentTokens)
    }

    private var formattedLimit: String {
        formatTokenCount(contextLimit)
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000)
        }
        return "\(count)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header with explanatory subtitle
            VStack(alignment: .leading, spacing: 2) {
                Text("Context Window")
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                Text("What's being sent to the model this turn")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
            }

            // Main content card
            VStack(spacing: 12) {
                // Header
                HStack {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 14))
                        .foregroundStyle(usageColor)

                    Text("Current Size")
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tronSlate)

                    Spacer()

                    Text("\(Int(usagePercent * 100))%")
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundStyle(usageColor)
                }

                // Progress bar
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        // Background
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.1))

                        // Fill
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(usageColor.opacity(0.8))
                            .frame(width: geometry.size.width * min(usagePercent, 1.0))
                    }
                }
                .frame(height: 10)

                // Token counts
                HStack {
                    Text("\(formattedTokens) / \(formattedLimit)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))

                    Spacer()

                    Text("\(formatTokenCount(contextLimit - currentTokens)) remaining")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular.tint(Color.tronSlateDark.opacity(0.5)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }
}

// MARK: - Token Breakdown Header

@available(iOS 26.0, *)
struct TokenBreakdownHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Window Breakdown")
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
            Text("Components that make up the Context Window above")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.35))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }
}
