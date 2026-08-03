import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

extension MacOperatorActuator {
    func screenshot(
        bundleIdentifier: String,
        observationID: String
    ) async throws -> [String: Any] {
        guard CGPreflightScreenCaptureAccess() else {
            throw MacOperatorActuatorError.screenRecordingPermissionRequired
        }
        let observation = try currentObservation(
            bundleIdentifier: bundleIdentifier,
            observationID: observationID
        )
        try validateFocus(observation)
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            )
        } catch {
            throw MacOperatorActuatorError.screenshotUnavailable
        }
        guard !Task.isCancelled,
              safety.snapshot().generation == observation.safetyGeneration,
              let window = content.windows.first(where: {
                  $0.windowID == observation.windowNumber
              })
        else {
            throw MacOperatorActuatorError.staleObservation
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = min(max(Int(window.frame.width * 2), 1), 2_400)
        configuration.height = min(max(Int(window.frame.height * 2), 1), 2_400)
        configuration.showsCursor = true
        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        } catch {
            throw MacOperatorActuatorError.screenshotUnavailable
        }
        guard !Task.isCancelled,
              safety.snapshot().generation == observation.safetyGeneration
        else {
            throw MacOperatorActuatorError.staleObservation
        }
        let encoded = try encodeJPEG(image)
        sequence &+= 1
        let screenshotID = "mac-screenshot-\(sequence)"
        latestScreenshotID = screenshotID
        return [
            "screenshotId": screenshotID,
            "mediaType": "image/jpeg",
            "width": image.width,
            "height": image.height,
            "dataBase64": encoded.base64EncodedString(),
        ]
    }

    func encodeJPEG(_ image: CGImage) throws -> Data {
        for quality in [0.72, 0.5, 0.32] {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                data,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            ) else {
                continue
            }
            CGImageDestinationAddImage(
                destination,
                image,
                [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
            )
            guard CGImageDestinationFinalize(destination) else { continue }
            if data.length <= 2_000_000 {
                return data as Data
            }
        }
        throw MacOperatorActuatorError.responseOversized
    }
}
