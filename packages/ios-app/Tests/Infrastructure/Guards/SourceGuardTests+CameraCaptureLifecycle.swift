import Foundation
import Testing

extension SourceGuardTests {
    @Test("Camera presentation remains composer-owned")
    func testCameraPresentationRemainsComposerOwned() throws {
        let root = iosAppRoot()
        let sources: [(path: String, contents: String)] = try swiftFiles(
            in: root.appendingPathComponent("Sources")
        ).map { file in
            (
                file.path.replacingOccurrences(of: root.path + "/", with: ""),
                try String(contentsOf: file, encoding: .utf8)
            )
        }
        let inputBar = try #require(
            sources.first { $0.path == "Sources/UI/Chat/Composer/InputBar.swift" }?.contents
        )

        #expect(inputBar.contains(".sheet(isPresented: $showCamera)"))
        #expect(inputBar.contains("CameraCaptureSheet(onImageCaptured: addCameraImageAttachment)"))
        let presenters = sources
            .filter { $0.contents.contains("CameraCaptureSheet(") }
            .map(\.path)
            .sorted()
        #expect(presenters == ["Sources/UI/Chat/Composer/InputBar.swift"])
        let productionSources = sources.map(\.contents).joined(separator: "\n")
        #expect(!productionSources.contains("--tron-debug-camera"))
        #expect(!productionSources.contains("CameraDebugSurface"))
    }

    @Test("Camera captured-photo preview pauses session until retake")
    func testCameraCapturedPhotoPreviewPausesSessionUntilRetake() throws {
        let source = try String(
            contentsOf: iosAppRoot().appendingPathComponent("Sources/UI/Chat/Composer/CameraCaptureSheet.swift"),
            encoding: .utf8
        )

        #expect(
            source.contains("showingPreview = true\n            }\n            cameraModel.stopSession()"),
            "camera capture should pause the AVCaptureSession immediately after entering captured-photo preview"
        )
        #expect(
            source.contains("showingPreview = false\n        }\n        cameraModel.startSession()"),
            "camera retake should restart the AVCaptureSession only after leaving preview state"
        )

        let previewEntryRange = try #require(
            source.range(of: "showingPreview = true"),
            "camera capture should enter preview after a successful photo"
        )
        let previewPauseRange = try #require(
            source.range(of: "showingPreview = true\n            }\n            cameraModel.stopSession()"),
            "camera preview should stop the live AVCaptureSession"
        )
        let retakeRange = try #require(
            source.range(of: "private func retake()"),
            "camera sheet should keep a dedicated retake path"
        )
        let retakeRestartRange = try #require(
            source.range(of: "cameraModel.startSession()"),
            "camera retake should restart the live AVCaptureSession"
        )

        #expect(
            previewEntryRange.lowerBound >= previewPauseRange.lowerBound
                && previewEntryRange.upperBound <= previewPauseRange.upperBound,
            "camera session stop should happen after preview state is entered"
        )
        #expect(
            previewPauseRange.upperBound < retakeRange.lowerBound,
            "camera preview stop should be part of capture success, not delayed until retake/dismiss"
        )
        #expect(
            retakeRange.lowerBound < retakeRestartRange.lowerBound,
            "camera session restart should remain inside the retake path"
        )
    }
}
