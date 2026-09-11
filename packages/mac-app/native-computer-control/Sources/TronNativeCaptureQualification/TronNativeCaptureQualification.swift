import AppKit
import Darwin
import Foundation

@main
@MainActor
struct TronNativeCaptureQualification {
    static func main() {
        let status = CaptureQualificationEntry.run(arguments: Array(CommandLine.arguments.dropFirst()),
            emit: { print($0) }, preflight: {
                publish(CaptureQualificationLifecycle.preflight())
            }, capture: { writeImages in
                capture(writeImages: writeImages)
            })
        exit(status)
    }

    private static func publish(_ report: CaptureQualificationReport) -> Int32 {
        do {
            FileHandle.standardOutput.write(try report.json())
            return report.passed ? 0 : 1
        } catch {
            FileHandle.standardError.write(Data("Qualification report encoding failed.\n".utf8))
            return 1
        }
    }

    private static func capture(writeImages: Bool) -> Int32 {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let lifecycle = CaptureQualificationLifecycle()
        let operation = Task { @MainActor in
            let report = await lifecycle.run(writeImages: writeImages)
            let status = publish(report)
            // Failed output removal is not permission to abandon its exact owner.
            // Keep the app and lifecycle alive for parent-directed containment.
            if !report.containmentRequired { exit(status) }
        }
        let signals = [SIGINT, SIGTERM].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { operation.cancel() }
            source.resume()
            return source
        }
        return withExtendedLifetime((signals, lifecycle)) {
            // No menu, delegate or command stops this run loop. Even an unexpected
            // stop must not drop a native owner whose joined cleanup is pending.
            while true { application.run() }
        }
    }
}
