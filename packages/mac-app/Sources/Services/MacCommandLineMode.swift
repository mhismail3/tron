import Foundation

enum MacCommandLineMode: Equatable, Sendable {
    case normal
    case startServerAndQuit
    case uninstallAndQuit
    case probeScreenRecordingAndQuit(resultPath: String?)

    static let startServerAndQuitFlag = "--tron-start-server-and-quit"
    static let uninstallAndQuitFlag = "--tron-uninstall-and-quit"
    static let probeScreenRecordingAndQuitFlag = "--tron-probe-screen-recording-and-quit"
    static let probeResultPathFlag = "--tron-probe-result-path"

    static var current: MacCommandLineMode {
        parse(ProcessInfo.processInfo.arguments)
    }

    var isCommand: Bool {
        self != .normal
    }

    static func parse(_ arguments: [String]) -> MacCommandLineMode {
        if arguments.contains(uninstallAndQuitFlag) {
            return .uninstallAndQuit
        }
        if arguments.contains(probeScreenRecordingAndQuitFlag) {
            return .probeScreenRecordingAndQuit(
                resultPath: value(after: probeResultPathFlag, in: arguments)
            )
        }
        if arguments.contains(startServerAndQuitFlag) {
            return .startServerAndQuit
        }
        return .normal
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let valueIndex = arguments.index(after: index)
        guard arguments.indices.contains(valueIndex) else { return nil }
        return arguments[valueIndex]
    }
}
