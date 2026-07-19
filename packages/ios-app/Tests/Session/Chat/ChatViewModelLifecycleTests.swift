import Testing
import Foundation
import PhotosUI
import SwiftUI
import UIKit
@testable import TronMobile

// MARK: - ChatViewModel Lifecycle Tests

@Suite("ChatViewModel Lifecycle")
@MainActor
struct ChatViewModelLifecycleTests {

    @Test("Session tasks release their owning view model")
    func testSessionTasksReleaseOwner() async {
        let mockURL = URL(string: "ws://localhost:8080/engine")!
        let engineClient = EngineClient(serverURL: mockURL)
        var viewModel: ChatViewModel? = ChatViewModel(engineClient: engineClient, sessionId: "test-session")
        weak let retainedViewModel = viewModel
        viewModel?.startLiveEventStream()

        // Let the observation and live-event tasks install their idle
        // continuations. This distinguishes genuine owner release from a task
        // that never started.
        for _ in 0..<10 {
            await Task.yield()
        }
        #expect(retainedViewModel != nil)

        viewModel = nil

        // Deinit cancels the tasks; the cancellation-aware observation waiter
        // must then release every retained source without another state change.
        for _ in 0..<10 {
            await Task.yield()
        }
        #expect(retainedViewModel == nil)
    }

    @Test("Suspended photo loading does not retain its owning view model")
    func testSuspendedPhotoLoadingReleasesOwner() async {
        let loadStarted = ManualExpectation()
        let dataLoader = PhotoPickerDataLoader { _ in
            await loadStarted.fulfill()
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                // Owner teardown cancels the selected-image task.
            }
            return nil
        }
        let mockURL = URL(string: "ws://localhost:8080/engine")!
        let engineClient = EngineClient(serverURL: mockURL)
        var viewModel: ChatViewModel? = ChatViewModel(
            engineClient: engineClient,
            sessionId: "test-session",
            photoPickerDataLoader: dataLoader
        )
        weak let retainedViewModel = viewModel

        // Install the selection observer before publishing a picker item.
        for _ in 0..<10 {
            await Task.yield()
        }
        viewModel?.selectedImages = [PhotosPickerItem(itemIdentifier: "lifecycle-test-image")]
        await loadStarted.waitForFulfillment(timeout: .seconds(1))
        #expect(await loadStarted.wasFulfilled)

        viewModel = nil

        for _ in 0..<10 {
            await Task.yield()
        }
        #expect(retainedViewModel == nil)
    }

    @Test("Photo loading appends an attachment and clears picker state")
    func testPhotoLoadingCommitsPreparedAttachment() async throws {
        let sourceImage = UIGraphicsImageRenderer(
            size: CGSize(width: 8, height: 8)
        ).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let sourceData = try #require(sourceImage.pngData())
        let dataLoader = PhotoPickerDataLoader { _ in sourceData }
        let mockURL = URL(string: "ws://localhost:8080/engine")!
        let engineClient = EngineClient(serverURL: mockURL)
        let viewModel = ChatViewModel(
            engineClient: engineClient,
            sessionId: "test-session",
            photoPickerDataLoader: dataLoader
        )

        for _ in 0..<10 {
            await Task.yield()
        }
        viewModel.selectedImages = [PhotosPickerItem(itemIdentifier: "prepared-image")]

        let deadline = ContinuousClock.now + .seconds(1)
        while viewModel.attachments.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(viewModel.attachments.count == 1)
        #expect(viewModel.selectedImages.isEmpty)
    }

    @Test("A replaced photo selection cannot commit its suspended result")
    func testReplacementRejectsSuspendedPhotoResult() async throws {
        let firstStarted = ManualExpectation()
        let secondStarted = ManualExpectation()
        let gate = PhotoDataGate()
        let firstData = try makeImageData(size: CGSize(width: 8, height: 8), color: .systemRed)
        let secondData = try makeImageData(size: CGSize(width: 12, height: 8), color: .systemGreen)
        let dataLoader = PhotoPickerDataLoader { item in
            let identifier = item.itemIdentifier ?? "missing"
            if identifier == "first" {
                await firstStarted.fulfill()
            } else if identifier == "second" {
                await secondStarted.fulfill()
            }
            return await gate.wait(for: identifier)
        }
        let engineClient = EngineClient(serverURL: URL(string: "ws://localhost:8080/engine")!)
        let viewModel = ChatViewModel(
            engineClient: engineClient,
            sessionId: "test-session",
            photoPickerDataLoader: dataLoader
        )

        for _ in 0..<10 { await Task.yield() }
        viewModel.selectedImages = [PhotosPickerItem(itemIdentifier: "first")]
        await firstStarted.waitForFulfillment(timeout: .seconds(1))
        #expect(await firstStarted.wasFulfilled)
        let firstTask = viewModel.selectedImageTask

        viewModel.selectedImages = [PhotosPickerItem(itemIdentifier: "second")]
        await gate.resume("first", with: firstData)
        await firstTask?.value
        await secondStarted.waitForFulfillment(timeout: .seconds(1))
        #expect(await secondStarted.wasFulfilled)
        let secondTask = viewModel.selectedImageTask

        await gate.resume("second", with: secondData)
        await secondTask?.value

        #expect(viewModel.attachments.count == 1)
        #expect(viewModel.attachments.first?.originalSize == secondData.count)
        #expect(viewModel.selectedImages.isEmpty)
    }

    @Test("Clearing selection cancels and rejects a suspended photo result")
    func testClearRejectsSuspendedPhotoResult() async throws {
        let loadStarted = ManualExpectation()
        let gate = PhotoDataGate()
        let sourceData = try makeImageData(size: CGSize(width: 8, height: 8), color: .systemOrange)
        let dataLoader = PhotoPickerDataLoader { item in
            await loadStarted.fulfill()
            return await gate.wait(for: item.itemIdentifier ?? "missing")
        }
        let engineClient = EngineClient(serverURL: URL(string: "ws://localhost:8080/engine")!)
        let viewModel = ChatViewModel(
            engineClient: engineClient,
            sessionId: "test-session",
            photoPickerDataLoader: dataLoader
        )

        for _ in 0..<10 { await Task.yield() }
        viewModel.selectedImages = [PhotosPickerItem(itemIdentifier: "clear")]
        await loadStarted.waitForFulfillment(timeout: .seconds(1))
        #expect(await loadStarted.wasFulfilled)
        let selectedImageTask = viewModel.selectedImageTask

        viewModel.selectedImages = []
        for _ in 0..<10 { await Task.yield() }
        #expect(selectedImageTask?.isCancelled == true)

        await gate.resume("clear", with: sourceData)
        await selectedImageTask?.value

        #expect(viewModel.attachments.isEmpty)
        #expect(viewModel.selectedImages.isEmpty)
    }

    @Test("ChatViewModel initializes with idle agent phase")
    func testInitialState() {
        let mockURL = URL(string: "ws://localhost:8080/engine")!
        let engineClient = EngineClient(serverURL: mockURL)
        let viewModel = ChatViewModel(engineClient: engineClient, sessionId: "test-session")

        #expect(viewModel.agentPhase == .idle)
        #expect(viewModel.isCompacting == false)
        #expect(viewModel.messages.isEmpty)
    }

    private func makeImageData(size: CGSize, color: UIColor) throws -> Data {
        let image = UIGraphicsImageRenderer(size: size).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return try #require(image.pngData())
    }
}

private actor PhotoDataGate {
    private var waiters: [String: CheckedContinuation<Data, Never>] = [:]
    private var queuedData: [String: Data] = [:]

    func wait(for identifier: String) async -> Data {
        if let data = queuedData.removeValue(forKey: identifier) {
            return data
        }
        return await withCheckedContinuation { continuation in
            waiters[identifier] = continuation
        }
    }

    func resume(_ identifier: String, with data: Data) {
        if let continuation = waiters.removeValue(forKey: identifier) {
            continuation.resume(returning: data)
        } else {
            queuedData[identifier] = data
        }
    }
}
