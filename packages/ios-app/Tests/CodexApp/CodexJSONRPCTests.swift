import Foundation
import Testing
@testable import TronMobile

@Suite("Codex JSON-RPC")
struct CodexJSONRPCTests {
    @Test("request encoding omits jsonrpc header and includes method id params")
    func encodesRequest() throws {
        let request = CodexJSONRPCRequest(id: .int(7), method: "thread/start", params: ["model": AnyCodable("gpt-5.4")])
        let data = try JSONEncoder().encode(request)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["jsonrpc"] == nil)
        #expect(json["method"] as? String == "thread/start")
        #expect(json["id"] as? Int == 7)
        let params = try #require(json["params"] as? [String: Any])
        #expect(params["model"] as? String == "gpt-5.4")
    }

    @Test("response decoder handles success and error responses")
    func decodesResponses() throws {
        let success = try CodexInboundMessage.decode(Data(#"{ "id": 7, "result": { "ok": true } }"#.utf8))
        let failure = try CodexInboundMessage.decode(Data(#"{ "id": 8, "error": { "code": -32001, "message": "Server overloaded; retry later." } }"#.utf8))

        guard case .response(let successResponse) = success else {
            Issue.record("expected success response")
            return
        }
        #expect(successResponse.id == .int(7))
        #expect(successResponse.result?["ok"]?.boolValue == true)

        guard case .response(let errorResponse) = failure else {
            Issue.record("expected error response")
            return
        }
        #expect(errorResponse.id == .int(8))
        #expect(errorResponse.error?.code == -32001)
    }

    @Test("notification decoder routes by method")
    func decodesNotification() throws {
        let message = try CodexInboundMessage.decode(Data(#"{ "method": "turn/started", "params": { "threadId": "thr", "turn": { "id": "turn" } } }"#.utf8))

        guard case .notification(let notification) = message else {
            Issue.record("expected notification")
            return
        }
        #expect(notification.method == "turn/started")
        #expect(notification.params?["threadId"]?.stringValue == "thr")
    }

    @Test("server request decoder preserves id for approval response")
    func decodesServerRequest() throws {
        let message = try CodexInboundMessage.decode(Data(#"{ "id": "approval-1", "method": "item/commandExecution/requestApproval", "params": { "threadId": "thr", "turnId": "turn", "itemId": "item" } }"#.utf8))

        guard case .serverRequest(let request) = message else {
            Issue.record("expected server request")
            return
        }
        #expect(request.id == .string("approval-1"))
        #expect(request.method == "item/commandExecution/requestApproval")
    }

    @Test("typed client payloads match Codex App Server protocol names")
    func typedPayloads() throws {
        let start = CodexTurnStartParams(
            threadId: "thr",
            input: [.text("hello")],
            cwd: "/repo",
            approvalPolicy: .onRequest,
            sandboxPolicy: CodexSandboxPolicy(type: .workspaceWrite, writableRoots: ["/repo"], networkAccess: true),
            model: "gpt-5.4",
            effort: "medium",
            summary: nil
        )
        let data = try JSONEncoder().encode(start)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["threadId"] as? String == "thr")
        #expect(json["approvalPolicy"] as? String == "onRequest")
        let sandbox = try #require(json["sandboxPolicy"] as? [String: Any])
        #expect(sandbox["type"] as? String == "workspaceWrite")
        #expect(sandbox["writableRoots"] as? [String] == ["/repo"])
        #expect(sandbox["networkAccess"] as? Bool == true)
        let input = try #require(json["input"] as? [[String: Any]])
        #expect(input.first?["type"] as? String == "text")
        #expect(input.first?["text"] as? String == "hello")
    }

    @Test("initialize payload includes app metadata")
    func initializePayloadIncludesClientInfo() throws {
        let params = CodexInitializeParams(version: "1.2.3")
        let data = try JSONEncoder().encode(params)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let clientInfo = try #require(json["clientInfo"] as? [String: Any])

        #expect(clientInfo["name"] as? String == "tron_ios")
        #expect(clientInfo["title"] as? String == "Tron iOS")
        #expect(clientInfo["version"] as? String == "1.2.3")
    }

    @Test("approval policy codec uses current names and accepts legacy names")
    func approvalPolicyCodecAcceptsLegacyNames() throws {
        let encoded = try JSONEncoder().encode(CodexApprovalPolicy.onRequest)
        #expect(String(data: encoded, encoding: .utf8) == #""onRequest""#)

        let legacy = try JSONDecoder().decode(CodexApprovalPolicy.self, from: Data(#""on-request""#.utf8))
        let oldUntrusted = try JSONDecoder().decode(CodexApprovalPolicy.self, from: Data(#""untrusted""#.utf8))

        #expect(legacy == .onRequest)
        #expect(oldUntrusted == .unlessTrusted)
    }

    @Test("config and account wrappers match current protocol fields")
    func configAndAccountPayloadsUseCurrentFields() throws {
        let configWrite = CodexConfigWriteParams(
            keyPath: "apps.google_drive.default_tools_approval_mode",
            value: AnyCodable("prompt"),
            mergeStrategy: .replace
        )
        let configData = try JSONEncoder().encode(configWrite)
        let configJSON = try #require(JSONSerialization.jsonObject(with: configData) as? [String: Any])
        #expect(configJSON["keyPath"] as? String == "apps.google_drive.default_tools_approval_mode")
        #expect(configJSON["mergeStrategy"] as? String == "replace")
        #expect(configJSON["value"] as? String == "prompt")

        let accountRead = CodexAccountReadParams(refreshToken: false)
        let accountData = try JSONEncoder().encode(accountRead)
        let accountJSON = try #require(JSONSerialization.jsonObject(with: accountData) as? [String: Any])
        #expect(accountJSON["refreshToken"] as? Bool == false)

        let loginStart = CodexAccountLoginStartParams(type: .chatgptDeviceCode)
        let loginData = try JSONEncoder().encode(loginStart)
        let loginJSON = try #require(JSONSerialization.jsonObject(with: loginData) as? [String: Any])
        #expect(loginJSON["type"] as? String == "chatgptDeviceCode")
    }

    @Test("thread list decoder accepts current data array and numeric timestamps")
    func decodesCurrentThreadListShape() throws {
        let payload = Data(#"""
        {
          "data": [
            {
              "id": "thr_a",
              "name": "TUI prototype",
              "preview": "Create a TUI",
              "ephemeral": false,
              "modelProvider": "openai",
              "createdAt": 1730831111,
              "updatedAt": 1730832222,
              "status": { "type": "notLoaded" }
            }
          ],
          "nextCursor": null
        }
        """#.utf8)

        let decoded = try JSONDecoder().decode(CodexThreadListResponse.self, from: payload)

        #expect(decoded.threads.count == 1)
        #expect(decoded.threads[0].createdAt == "1730831111")
        #expect(decoded.threads[0].summary.title == "TUI prototype")
        #expect(decoded.threads[0].summary.createdAt == "1730832222")
    }
}
