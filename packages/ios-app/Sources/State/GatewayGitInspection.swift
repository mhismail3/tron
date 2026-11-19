import Foundation
import TronMobileCore

struct GatewayGitInspection: Sendable {
    private let client: GatewayClient

    init(client: GatewayClient) {
        self.client = client
    }

    func inspectGit(path: String) async throws -> GitInspection {
        let value = try await client.requestValue("git.inspect", JSONValue.object(["path": .string(path)]))
        let object = value.objectValue
        return GitInspection(
            isRepository: object?["isRepository"]?.boolValue == true,
            branch: object?["branch"]?.stringValue,
            isDirty: object?["dirty"]?.boolValue ?? false,
            branches: (object?["branches"]?.arrayValue ?? []).compactMap { value in
                guard let name = value.objectValue?["name"]?.stringValue,
                      let checkedOut = value.objectValue?["checkedOut"]?.boolValue else { return nil }
                return GitInspection.Branch(name: name, checkedOut: checkedOut)
            },
            commits: (object?["commits"]?.arrayValue ?? []).compactMap { value in
                guard let oid = value.objectValue?["oid"]?.stringValue,
                      let subject = value.objectValue?["subject"]?.stringValue else { return nil }
                return GitInspection.Commit(oid: oid, subject: subject)
            }
        )
    }
}
