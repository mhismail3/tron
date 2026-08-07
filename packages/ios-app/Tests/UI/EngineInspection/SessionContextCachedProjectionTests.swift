import Foundation
import Testing
@testable import TronMobile

@Suite("Session context cached projection")
struct SessionContextCachedProjectionTests {
    @Test("Cached provider audit renders its overview before exact detail decoding")
    func cachedProviderAuditProjectsOverviewAndDetail() async throws {
        let data = Data(#"""
        {
          "id":"event-request-cached",
          "parentId":null,
          "sessionId":"session-one",
          "workspaceId":"workspace-one",
          "type":"model.provider_request",
          "timestamp":"2026-08-07T12:00:00Z",
          "sequence":42,
          "payload":{
            "format":"tron.model_provider_request.v4",
            "turn":9,
            "providerType":"openai",
            "providerName":"OpenAI",
            "model":"gpt-5.6-sol",
            "requestClassification":"interactive",
            "messageCount":2,
            "toolCount":23,
            "contextManifest":{
              "systemContributions":[{
                "kind":"base_instructions",
                "label":"Agent instructions",
                "content":"Follow the request.",
                "byteCount":19,
                "sha256":"sha256:system"
              }],
              "messages":[{
                "ordinal":0,
                "role":"user",
                "contentKinds":["text"],
                "byteCount":12,
                "sha256":"sha256:text",
                "projection":"provider_visible"
              },{
                "ordinal":1,
                "role":"user",
                "contentKinds":["image","text"],
                "byteCount":24,
                "sha256":"sha256:image",
                "projection":"provider_visible"
              }],
              "toolSurface":{"fixedTools":[],"availableWorkers":[]},
              "automaticContext":[{
                "kind":"continuity",
                "outcome":"injected",
                "mechanism":"engine_hook",
                "deliveryChannel":"reference"
              }],
              "agentDeliveries":[{
                "deliveryId":"delivery-one",
                "sourceKind":"worker_result",
                "wakePolicy":"passive",
                "boundary":"next_turn",
                "redelivery":false,
                "provenance":{},
                "content":"Research is ready."
              }],
              "environment":{
                "workingDirectory":"/workspace",
                "serverOrigin":"local",
                "sha256":"sha256:environment"
              },
              "systemPromptSha256":"sha256:system",
              "messagesSha256":"sha256:messages",
              "toolsSha256":"sha256:tools",
              "contextSha256":"sha256:context"
            },
            "providerAdditions":[{
              "kind":"provider_system_prefix",
              "label":"Provider instructions",
              "content":"Use the provider contract.",
              "byteCount":26,
              "sha256":"sha256:provider"
            }]
          }
        }
        """#.utf8)
        let event = try JSONDecoder().decode(RawEvent.self, from: data)
        let cached = CachedSessionContextEvent(event)

        let summary = cached.summary
        #expect(summary.eventId == "event-request-cached")
        #expect(summary.turn == 9)
        #expect(summary.model == "gpt-5.6-sol")
        #expect(summary.messageCount == 2)
        #expect(summary.toolCount == 23)
        #expect(summary.instructionCount == 2)
        #expect(summary.attachmentMessageCount == 1)
        #expect(summary.agentDeliveryCount == 1)
        #expect(summary.automaticContextCount == 1)
        #expect(summary.environmentAvailable == true)
        #expect(summary.manifestAvailable)

        let detail = await cached.decodeDetail()
        #expect(detail.eventId == summary.eventId)
        #expect(detail.contextManifest?.messages.count == 2)
        #expect(detail.contextManifest?.agentDeliveries.first?.deliveryId == "delivery-one")
        #expect(detail.providerAdditions?.first?.kind == "provider_system_prefix")
        #expect(detail.provenanceAvailability == "complete")
    }
}
