import Testing
import Foundation
@testable import TronMobile

@Suite("SessionInfo Tests")
struct SessionInfoTests {

    private func makeSessionInfo(
        sessionId: String = "sess_abc123def456789012345",
        inputTokens: Int? = 1000,
        outputTokens: Int? = 500,
        cacheReadTokens: Int? = 200,
        cacheCreationTokens: Int? = 100,
        cost: Double? = 1.23,
        parentSessionId: String? = nil
    ) -> SessionInfo {
        let json: [String: Any] = [
            "sessionId": sessionId,
            "model": "claude-sonnet-4-6",
            "createdAt": "2026-04-01T00:00:00Z",
            "messageCount": 10,
            "inputTokens": inputTokens as Any,
            "outputTokens": outputTokens as Any,
            "cacheReadTokens": cacheReadTokens as Any,
            "cacheCreationTokens": cacheCreationTokens as Any,
            "cost": cost as Any,
            "isActive": true,
            "parentSessionId": parentSessionId as Any,
        ].compactMapValues { $0 is NSNull ? nil : $0 }

        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(SessionInfo.self, from: data)
    }

    // MARK: - displayName

    @Test("displayName truncates to 20 chars")
    func displayNameTruncated() {
        let info = makeSessionInfo(sessionId: "sess_abc123def456789012345")
        #expect(info.displayName == "sess_abc123def456789") // First 20 chars
        #expect(info.displayName.count == 20)
    }

    @Test("displayName short sessionId returns full string")
    func displayNameShort() {
        let info = makeSessionInfo(sessionId: "short")
        #expect(info.displayName == "short")
    }

    // MARK: - totalInputTokens

    @Test("totalInputTokens sums input and cache read")
    func totalInputTokensSum() {
        let info = makeSessionInfo(inputTokens: 1000, cacheReadTokens: 500)
        #expect(info.totalInputTokens == 1500)
    }

    @Test("totalInputTokens with nil inputTokens")
    func totalInputTokensNilInput() {
        let info = makeSessionInfo(inputTokens: nil, cacheReadTokens: 500)
        #expect(info.totalInputTokens == 500)
    }

    @Test("totalInputTokens with nil cacheRead")
    func totalInputTokensNilCache() {
        let info = makeSessionInfo(inputTokens: 1000, cacheReadTokens: nil)
        #expect(info.totalInputTokens == 1000)
    }

    @Test("totalInputTokens both nil")
    func totalInputTokensBothNil() {
        let info = makeSessionInfo(inputTokens: nil, cacheReadTokens: nil)
        #expect(info.totalInputTokens == 0)
    }

    // MARK: - formattedCacheTokens

    @Test("formattedCacheTokens both zero returns nil")
    func cacheTokensBothZero() {
        let info = makeSessionInfo(cacheReadTokens: 0, cacheCreationTokens: 0)
        #expect(info.formattedCacheTokens == nil)
    }

    @Test("formattedCacheTokens both nil returns nil")
    func cacheTokensBothNil() {
        let info = makeSessionInfo(cacheReadTokens: nil, cacheCreationTokens: nil)
        #expect(info.formattedCacheTokens == nil)
    }

    @Test("formattedCacheTokens one non-zero returns formatted string")
    func cacheTokensOneNonZero() {
        let info = makeSessionInfo(cacheReadTokens: 1000, cacheCreationTokens: 0)
        let result = info.formattedCacheTokens
        #expect(result != nil)
        #expect(result!.contains("read"))
        #expect(result!.contains("write"))
    }

    // MARK: - formattedCost

    @Test("formattedCost nil shows less than penny")
    func costNil() {
        let info = makeSessionInfo(cost: nil)
        #expect(info.formattedCost == "<$0.01")
    }

    @Test("formattedCost zero shows less than penny")
    func costZero() {
        let info = makeSessionInfo(cost: 0)
        #expect(info.formattedCost == "<$0.01")
    }

    @Test("formattedCost sub-penny shows less than penny")
    func costSubPenny() {
        let info = makeSessionInfo(cost: 0.005)
        #expect(info.formattedCost == "<$0.01")
    }

    @Test("formattedCost normal amount")
    func costNormal() {
        let info = makeSessionInfo(cost: 1.23)
        #expect(info.formattedCost == "$1.23")
    }

    @Test("formattedCost exactly one cent")
    func costOneCent() {
        let info = makeSessionInfo(cost: 0.01)
        #expect(info.formattedCost == "$0.01")
    }

    @Test("formattedCost negative — documents edge case")
    func costNegative() {
        // Negative cost < 0.01, so shows "<$0.01" — technically misleading for refunds
        let info = makeSessionInfo(cost: -0.05)
        #expect(info.formattedCost == "<$0.01")
    }

    // MARK: - isFork

    @Test("isFork true when parentSessionId set")
    func isForkTrue() {
        let info = makeSessionInfo(parentSessionId: "parent-sess")
        #expect(info.isFork == true)
    }

    @Test("isFork false when parentSessionId nil")
    func isForkFalse() {
        let info = makeSessionInfo(parentSessionId: nil)
        #expect(info.isFork == false)
    }
}

@Suite("SessionCreateParams useWorktree encoding")
struct SessionCreateParamsUseWorktreeTests {

    private func encode(_ params: SessionCreateParams) -> [String: Any] {
        let data = try! JSONEncoder().encode(params)
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    @Test("useWorktree true encodes as true")
    func encodesTrue() {
        let params = SessionCreateParams(workingDirectory: "/tmp", useWorktree: true)
        let json = encode(params)
        #expect(json["useWorktree"] as? Bool == true)
    }

    @Test("useWorktree false encodes as false")
    func encodesFalse() {
        let params = SessionCreateParams(workingDirectory: "/tmp", useWorktree: false)
        let json = encode(params)
        #expect(json["useWorktree"] as? Bool == false)
    }

    @Test("useWorktree omitted defaults to nil")
    func omittedIsNil() {
        let params = SessionCreateParams(workingDirectory: "/tmp")
        // Server-side opt_bool() handles both `null` and missing identically (returns None).
        // Default Swift JSONEncoder emits explicit `null` for nil optionals — that's accepted.
        let json = encode(params)
        let raw = json["useWorktree"]
        #expect(raw == nil || raw is NSNull)
    }
}

@Suite("SessionInfo useWorktree decoding")
struct SessionInfoUseWorktreeTests {

    private func decodeWith(useWorktree: Any?) -> SessionInfo {
        var json: [String: Any] = [
            "sessionId": "sess_x",
            "model": "claude-sonnet-4-6",
            "createdAt": "2026-04-01T00:00:00Z",
            "messageCount": 0,
            "isActive": true,
        ]
        if let v = useWorktree { json["useWorktree"] = v }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(SessionInfo.self, from: data)
    }

    @Test("decodes useWorktree=true")
    func decodesTrue() {
        let info = decodeWith(useWorktree: true)
        #expect(info.useWorktree == true)
    }

    @Test("decodes useWorktree=false")
    func decodesFalse() {
        let info = decodeWith(useWorktree: false)
        #expect(info.useWorktree == false)
    }

    @Test("decodes missing useWorktree as nil")
    func decodesMissingAsNil() {
        let info = decodeWith(useWorktree: nil)
        #expect(info.useWorktree == nil)
    }
}
