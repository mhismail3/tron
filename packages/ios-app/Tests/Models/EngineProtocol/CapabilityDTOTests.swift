import Foundation
import Testing
@testable import TronMobile

@Suite("Capability DTOs")
struct CapabilityDTOTests {
    @Test("status decodes vector index state")
    func statusDecodesVectorIndexState() throws {
        let data = """
        {
          "catalogRevision": 12,
          "plugins": 3,
          "implementations": 9,
          "indexStatus": {
            "state": "ready",
            "vectorStore": "sqlite-vec",
            "embeddingModel": "fastembed:bge-small"
          },
          "serverProfile": {
            "profileName": "default",
            "profileHash": "abc"
          }
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(CapabilityStatusDTO.self, from: data)

        #expect(decoded.catalogRevision == 12)
        #expect(decoded.indexStatus?.state == "ready")
        #expect(decoded.indexStatus?.vectorStore == "sqlite-vec")
        #expect(decoded.serverProfile?.profileHash == "abc")
    }

    @Test("inspection decodes handle and implementation identity")
    func inspectionDecodesIdentity() throws {
        let data = """
        {
          "contract": {"contractId": "filesystem::read_file"},
          "implementation": {
            "implementationId": "runtime.filesystem.v1.read_file",
            "functionId": "filesystem::read_file",
            "schemaDigest": "sha"
          },
          "inspectionHandle": {
            "handle": "capability-inspection:v1:abc",
            "catalogRevision": 5,
            "functionRevision": 1,
            "schemaDigest": "sha"
          }
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(CapabilityInspectionDTO.self, from: data)

        #expect(decoded.contract?.contractId == "filesystem::read_file")
        #expect(decoded.implementation?.implementationId == "runtime.filesystem.v1.read_file")
        #expect(decoded.inspectionHandle?.handle == "capability-inspection:v1:abc")
    }
}
