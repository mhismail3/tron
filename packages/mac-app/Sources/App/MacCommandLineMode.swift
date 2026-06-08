import Foundation

enum MacCommandLineMode: Equatable, Sendable {
    case normal
    case startServerAndQuit
    case uninstallAndQuit

    static let startServerAndQuitFlag = "--tron-start-server-and-quit"
    static let uninstallAndQuitFlag = "--tron-uninstall-and-quit"

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
        if arguments.contains(startServerAndQuitFlag) {
            return .startServerAndQuit
        }
        return .normal
    }
}
