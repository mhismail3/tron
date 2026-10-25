#if HOSTED_TEST
import SwiftUI
import TronMobileCore

/// Synthetic design canvas only. No provider classification or transcript grouping
/// lives here; labels represent the proposed Gateway projection contract.
struct HostedChatErrorsFixture: View {
    var previewSurface: String? = nil
    @State private var selected: String?
    @State private var expanded: Set<Int> = [0]
    private let accent = ChatNotificationTone.error.surfaceColor
    private let overload = """
    {"type":"error","error":{"details":null,"type":"overloaded_error","message":"Overloaded"},"request_id":"req_preview_01"}
    """
    private var dark: Bool { ProcessInfo.processInfo.arguments.contains("-error-preview-dark") }
    private var surface: String {
        if let previewSurface { return previewSurface }
        guard let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-error-preview-surface"),
              ProcessInfo.processInfo.arguments.indices.contains(i + 1) else { return "pills" }
        return ProcessInfo.processInfo.arguments[i + 1]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Design preview · Synthetic errors")
                        .font(TronTypography.settingsRowSubtext).foregroundStyle(Color.tronTextMuted)
                    if surface == "pills" { pills }
                    else { details(surface) }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    TronSheetTitle(title: surface == "pills" ? "Home" : title(surface), accent: accent)
                }
            }
        }
        .tronTopBlur(.toolDetail)
        .tronPresentation()
        .preferredColorScheme(dark ? .dark : .light)
        .tronManagedSheet(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } }),
                          identity: "preview.error") {
            HostedChatErrorsFixture(previewSurface: selected)
        }
    }

    private var pills: some View {
        VStack(alignment: .leading, spacing: 20) {
            caption("Single provider error")
            chip("Anthropic is overloaded", count: 1, route: "single")
            caption("Four adjacent failures → one pill")
            chip("Anthropic is overloaded", count: 4, route: "grouped")
            HStack { Spacer(); Text("Continue").padding(12).tronGlassSurface(accent: .tronEmerald) }
            chip("Anthropic is overloaded", count: 4, route: "grouped")
            TranscriptNotice(title: "Model changed", value: "OpenAI · GPT", icon: "arrow.triangle.2.circlepath", tone: .information)
            caption("Mixed adjacent failures → one run")
            chip("Provider errors", count: 3, route: "mixed")
            caption("Non-JSON fallback")
            chip("The connection timed out", count: 1, route: "text")
            Text("User messages and model changes split runs. Mixed failures stay together; the sheet breaks them down.")
                .font(TronTypography.settingsRowSubtext).foregroundStyle(Color.tronTextSecondary)
        }
    }

    private func caption(_ value: String) -> some View {
        Text(value).font(TronTypography.settingsRowSubtext).foregroundStyle(Color.tronTextMuted)
    }
    private func title(_ kind: String) -> String {
        switch kind {
        case "grouped": "4 provider errors"
        case "mixed": "3 provider errors"
        case "text": "The connection timed out"
        default: "Anthropic is overloaded"
        }
    }
    private func chip(_ label: String, count: Int, route: String) -> some View {
        ChatCompactPillSurface(tone: .error, material: .flat, interactive: true,
                               cornerRadiusOverride: ChatToolChipShapePolicy.cornerRadius) {
            ChatCompactPillLabel(icon: "exclamationmark.triangle.fill", title: label, detail: nil,
                                 tone: .error, showsProgress: false) {
                if count > 1 {
                    Text("×\(count)").font(TronTypography.secondaryCodeDescription)
                        .foregroundStyle(accent)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .chatCompactPillInteraction(accessibilityLabel: "\(label), \(count) errors", accessibilityValue: label) {
            selected = route
        }
    }

    @ViewBuilder private func details(_ kind: String) -> some View {
        let grouped = kind == "grouped" || kind == "mixed"
        if grouped {
            TronListRow(.init(title: kind == "mixed" ? "3 errors · 2 distinct errors" : "4 errors · 1 distinct error",
                              subtext: "First 10:42:01 · Last 10:42:18"))
            caption("Breakdown")
            VStack(spacing: 0) {
                TronListRow(.init(leading: .icon("exclamationmark.triangle.fill", accent),
                                  title: "Anthropic is overloaded",
                                  status: .init(text: kind == "mixed" ? "×2" : "×4", tone: accent),
                                  subtext: "Anthropic · Claude Sonnet"))
                if kind == "mixed" {
                    Divider()
                    TronListRow(.init(leading: .icon("exclamationmark.triangle.fill", accent),
                                      title: "Rate limited by OpenAI", status: .init(text: "×1", tone: accent),
                                      subtext: "OpenAI · GPT"))
                }
            }.tronScrollSurface(accent: accent, cornerRadius: 16, tintOpacity: 0.10)
            caption("Occurrences · newest first")
            ForEach(0..<(kind == "mixed" ? 3 : 4), id: \.self) { i in
                DisclosureGroup(isExpanded: Binding(get: { expanded.contains(i) }, set: { value in
                    if value { expanded.insert(i) } else { expanded.remove(i) }
                })) {
                    occurrence(kind == "mixed" && i == 0 ? "rate" : "json")
                } label: {
                    TronListRow(.init(title: kind == "mixed" && i == 0 ? "Rate limited by OpenAI" : "Anthropic is overloaded",
                                      timestamp: "10:42:\(18 - i * 5)"))
                }.tint(accent)
            }
        } else {
            occurrence(kind == "text" ? "text" : "json")
        }
    }

    private func occurrence(_ kind: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TronListRow(.init(title: kind == "rate" ? "OpenAI · GPT" : "Anthropic · Claude Sonnet",
                              subtext: kind == "text" ? "Timeout · 10:42:18" : "\(kind == "rate" ? "rate_limit_error" : "overloaded_error") · 10:42:18"))
            if kind != "text" {
                TronListRow(.init(title: "Request ID", monoTitle: false, subtext: "req_preview_01", monoSubtext: true))
            }
            ToolDetailCodeBlock(text: formatted(kind), accent: accent)
        }
    }
    private func formatted(_ kind: String) -> String {
        if kind == "text" { return "Request timed out after 60 seconds. The connection was closed before a response was received." }
        let raw = kind == "rate" ? "{\"error\":{\"type\":\"rate_limit_error\",\"message\":\"Rate limit reached\"},\"request_id\":\"req_preview_01\"}" : overload
        guard let data = raw.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: pretty, encoding: .utf8) else { return raw }
        return text
    }
}

#endif
