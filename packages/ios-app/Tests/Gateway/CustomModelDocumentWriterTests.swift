import Foundation
import Testing
@testable import TronMobile

@Suite("Custom-model document writes")
struct CustomModelDocumentWriterTests {
    private actor Recorder {
        var calls: [(String, JSONValue)] = []
        func append(_ method: String, params: JSONValue) { calls.append((method, params)) }
    }

    @Test("validation precedes the canonical mutation")
    func validatesBeforePut() async throws {
        let recorder = Recorder()
        let document: JSONValue = .object(["providers": .object([:])])
        let writer = CustomModelDocumentWriter(request: { method, params in
            await recorder.append(method, params: params)
            return .null
        }, makeCommandID: { "command-1" })

        try await writer.replace(document)

        let calls = await recorder.calls
        #expect(calls.map(\.0) == ["models.custom.validate", "models.custom.put"])
        #expect(calls[0].1.objectValue?["document"] == document)
        #expect(calls[1].1.objectValue?["document"] == document)
        #expect(calls[1].1.objectValue?["commandId"] == .string("command-1"))
    }

    @Test("validation failure never mutates the canonical document")
    func validationFailureStopsWrite() async {
        struct InvalidDocument: Error {}
        let recorder = Recorder()
        let writer = CustomModelDocumentWriter { method, params in
            await recorder.append(method, params: params)
            throw InvalidDocument()
        }

        await #expect(throws: InvalidDocument.self) {
            try await writer.replace(.object([:]))
        }
        #expect(await recorder.calls.map(\.0) == ["models.custom.validate"])
    }
}
