#if HOSTED_TEST
import SwiftUI
import TronMobileCore

/// Synthetic wire data rendered by the shipping pill/sheet components. The
/// fixture supplies already-classified labels; it never classifies errors.
struct HostedChatErrorsFixture: View {
    @State private var routes = ChatTranscriptSheetRouteOwner()
    @State private var detailID = UUID()
    private var dark: Bool { ProcessInfo.processInfo.arguments.contains("-error-preview-dark") }
    private var surface: String {
        guard let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-error-preview-surface"),
              ProcessInfo.processInfo.arguments.indices.contains(i + 1) else { return "pills" }
        return ProcessInfo.processInfo.arguments[i + 1]
    }

    var body: some View {
        Group {
            if surface == "pills" {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            caption("Design preview · Synthetic errors")
                            caption("Single provider error")
                            pill("single")
                            caption("Four adjacent failures → one pill")
                            pill("grouped")
                            HStack { Spacer(); Text("Continue").padding(12).tronGlassSurface(accent: .tronEmerald) }
                            pill("second")
                            TranscriptNotice(title: "Model changed", value: "OpenAI · GPT", icon: "arrow.triangle.2.circlepath", tone: .information)
                            caption("Mixed adjacent failures → one run")
                            pill("mixed")
                            caption("Non-JSON fallback")
                            pill("text")
                            caption("User messages and model changes split runs. Mixed failures stay together; the sheet breaks them down.")
                        }.padding(18)
                    }.navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .principal) { Text("Error pill design canvas") } }
                }
            } else {
                ChatNotificationDetailSheet(presentation: run(surface).notification, detailID: detailID)
            }
        }
        .tronPresentation()
        .environment(\.chatTranscriptSheetRoutes, routes)
        .modifier(ChatTranscriptSheetHost(routes: routes, resolveNotificationDetail: { id in
            ["single", "grouped", "second", "mixed", "text"].map { run($0).notification }.first { $0.id == id }
        }))
        .preferredColorScheme(dark ? .dark : .light)
    }

    private func caption(_ value: String) -> some View {
        Text(value).font(TronTypography.settingsRowSubtext).foregroundStyle(Color.tronTextMuted)
    }
    private func pill(_ kind: String) -> some View { ChatNotificationView(presentation: run(kind).notification) }
    private func run(_ kind: String) -> ChatProviderErrorRun {
        let count = kind == "grouped" || kind == "second" ? 4 : (kind == "mixed" ? 3 : 1)
        return ChatProviderErrorRun(occurrences: (0..<count).map { index in
            var fields: [String: JSONValue] = [
                "id": .string("\(kind)-\(index)"), "presentationId": .string("\(kind)-\(index)"),
                "timestamp": .string("2026-10-25T10:42:\(String(format: "%02d", 3 + index * 5))Z"),
                "kind": .string("message"), "role": .string("assistant"), "content": .array([]),
                "provider": .string("anthropic"), "modelId": .string("Claude Sonnet"), "stopReason": .string("error")]
            let rate = kind == "mixed" && index == 2
            let text = kind == "text"
            let message = rate ? "Rate limited by OpenAI" : (text ? "The connection to Anthropic timed out" : "Anthropic is overloaded")
            let type = rate ? "rate_limit_error" : "overloaded_error"
            let providerMessage = rate ? "Rate limit reached" : "Overloaded"
            let requestID = "req_preview_\(index + 1)"
            fields["errorMessage"] = .string(text ? "Request timed out after 60 seconds. The connection was closed before a response was received."
                : "{\"type\":\"error\",\"error\":{\"details\":null,\"type\":\"\(type)\",\"message\":\"\(providerMessage)\"},\"request_id\":\"\(requestID)\"}")
            var info: [String: JSONValue] = ["message": .string(message), "providerMessage": .string(text ? "Request timed out after 60 seconds" : providerMessage),
                                           "category": .string(rate ? "rate-limit" : (text ? "timeout" : "overloaded"))]
            if !text { info["type"] = .string(type); info["requestId"] = .string(requestID) }
            fields["errorInfo"] = .object(info)
            if rate { fields["provider"] = .string("openai"); fields["modelId"] = .string("GPT") }
            let item = try! JSONDecoder.gateway.decode(TranscriptItem.self, from: JSONEncoder.gateway.encode(JSONValue.object(fields)))
            return ChatProviderErrorOccurrence(item)!
        })
    }
}
#endif
