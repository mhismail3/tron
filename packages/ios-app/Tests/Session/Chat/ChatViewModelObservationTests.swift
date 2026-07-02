import Observation
import XCTest
@testable import TronMobile

@MainActor
final class ChatViewModelObservationTests: XCTestCase {

    func testObserveLoopCancelsWhileWaitingForObservedChange() async {
        let probe = ChatViewModelObservationProbe()
        let observationInstalled = expectation(description: "observation installed")
        let taskCancelled = expectation(description: "task cancelled")
        var readCount = 0

        let task = ChatViewModel.observeLoop({
            readCount += 1
            if readCount == 2 {
                observationInstalled.fulfill()
            }
            return probe.value
        }) { _ in
            XCTFail("No value change was expected")
        }

        await fulfillment(of: [observationInstalled], timeout: 1.0)
        task.cancel()

        Task { @MainActor in
            await task.value
            taskCancelled.fulfill()
        }

        await fulfillment(of: [taskCancelled], timeout: 1.0)
    }
}

@Observable
final class ChatViewModelObservationProbe {
    var value = 0
}
