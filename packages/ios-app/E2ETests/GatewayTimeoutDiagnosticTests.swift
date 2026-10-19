import Foundation
@testable import TronMobileCore
import XCTest

final class GatewayTimeoutDiagnosticTests: XCTestCase {
    private struct FailedSocket: GatewaySocketConnection {
        let code: String
        func send(_ data: Data) async throws {
            throw GatewayFailure(code: code, message: "Transport deadline elapsed", retryable: true, details: nil)
        }
        func receive() async throws -> Data { throw CancellationError() }
        func ping() async throws { throw CancellationError() }
        func close() async {}
    }

    func testBothRawTimeoutNamesProduceTheSameTransportDiagnostic() async throws {
        let profile = GatewayProfile(id: "timeout-contract", label: "Timeout contract", host: "127.0.0.1",
                                     port: 9848, machineId: "timeout-contract")
        for code in ["pong_timeout", "ping_timeout"] {
            let client = GatewayClient(socketFactory: GatewaySocketFactory { _ in FailedSocket(code: code) })
            do {
                _ = try await client.connectForLifecycle(profile: profile, token: "fixture-token")
                XCTFail("The failed transport must not connect: \(code)")
            } catch let failure as GatewayFailure {
                XCTAssertEqual(failure.code, code)
            }
            let diagnostics = await client.diagnostics()
            let failure = try XCTUnwrap(diagnostics.last { $0.outcome == .failure }, code)
            XCTAssertEqual(failure.reason, .pingTimeout, code)
            await client.close()
        }
    }
}
