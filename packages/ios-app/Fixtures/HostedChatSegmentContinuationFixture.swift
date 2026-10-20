#if HOSTED_TEST
import Foundation

extension HostedChatDisplayFixture {
    /// One tool segment over two assistant messages (#1486). The first holds a
    /// finalized group whose display call splits away from its read call; the
    /// second continues the segment with its own one-call group. Assembly
    /// merges the group back into the display row, leaving the continuation
    /// row behind with only its own call.
    static let segmentContinuationTranscriptData = Data(#"""
        [
          {"id":"segment-request","parentId":null,"presentationId":"segment-request","timestamp":"2026-01-01T00:00:01Z","kind":"message","role":"assistant","content":[{"id":"segment-shot-content","ordinal":0,"type":"toolCall","toolCallId":"segment-shot","name":"display","arguments":{"presentation":{"surface":"inline"}},"toolSegmentId":"segment-1","groupId":"segment-group","groupIndex":0,"groupCount":2,"groupFinalized":true},{"id":"segment-read-content","ordinal":1,"type":"toolCall","toolCallId":"segment-read","name":"read","arguments":{"path":"README.md"},"toolSegmentId":"segment-1","groupId":"segment-group","groupIndex":1,"groupCount":2,"groupFinalized":true}]},
          {"id":"segment-shot-result","parentId":"segment-request","presentationId":"segment-shot-result","timestamp":"2026-01-01T00:00:02Z","kind":"message","role":"toolResult","content":[{"id":"segment-shot-result-text","ordinal":0,"type":"text","text":"Displayed Segment photo."}],"toolCallId":"segment-shot","toolName":"display","isError":false,"display":{"schema":"tron.display.v1","displayId":"display-segment-shot","revision":1,"title":"Segment photo","altText":"Segment photo","kind":"image","presentation":{"requestedSurface":"inline","inlineTapAction":"sheet"},"eligibleSurfaces":["sheet","inline","floating"],"fallbackText":"Segment photo","artifact":{"id":"6ab02a1a-fd63-4196-a2e1-5fe9ebd6bc70","name":"segment-shot.png","mimeType":"image/png","size":1024,"kind":"image"}}},
          {"id":"segment-read-result","parentId":"segment-shot-result","presentationId":"segment-read-result","timestamp":"2026-01-01T00:00:03Z","kind":"message","role":"toolResult","content":[{"id":"segment-read-result-text","ordinal":0,"type":"text","text":"ok"}],"toolCallId":"segment-read","toolName":"read","isError":false},
          {"id":"segment-follow","parentId":"segment-read-result","presentationId":"segment-follow","timestamp":"2026-01-01T00:00:04Z","kind":"message","role":"assistant","content":[{"id":"segment-follow-content","ordinal":0,"type":"toolCall","toolCallId":"segment-follow-bash","name":"bash","arguments":{"command":"true"},"toolSegmentId":"segment-1","groupId":"segment-follow-group","groupIndex":0,"groupCount":1,"groupFinalized":true}]},
          {"id":"segment-follow-result","parentId":"segment-follow","presentationId":"segment-follow-result","timestamp":"2026-01-01T00:00:05Z","kind":"message","role":"toolResult","content":[{"id":"segment-follow-result-text","ordinal":0,"type":"text","text":"ok"}],"toolCallId":"segment-follow-bash","toolName":"bash","isError":false},
          {"id":"segment-summary","parentId":"segment-follow-result","presentationId":"segment-summary","timestamp":"2026-01-01T00:00:06Z","kind":"message","role":"assistant","content":[{"id":"segment-summary-text","ordinal":0,"type":"text","text":"Segment continuation settled."}]}
        ]
        """#.utf8)
}
#endif
