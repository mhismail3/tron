import Foundation
import Testing

extension SourceGuardTests {
    @Test("iOS deployment-target availability annotations are not duplicated")
    func testIOSDeploymentTargetAvailabilityAnnotationsAreNotDuplicated() throws {
        let iosRoot = iosAppRoot()
        let files = try swiftFiles(in: iosRoot.appendingPathComponent("Sources"))
            + swiftFiles(in: iosRoot.appendingPathComponent("Tests"))
        let redundantAvailability = "@available(iOS " + "26.0, *)"
        let redundantAnnotations = try files.compactMap { file -> String? in
            let source = try String(contentsOf: file, encoding: .utf8)
            guard source.contains(redundantAvailability) else { return nil }
            return file.path.replacingOccurrences(of: iosRoot.path + "/", with: "")
        }

        #expect(
            redundantAnnotations.isEmpty,
            "iOS 26 is the deployment target; redundant deployment-target availability annotations remain in \(redundantAnnotations)"
        )
    }
}
