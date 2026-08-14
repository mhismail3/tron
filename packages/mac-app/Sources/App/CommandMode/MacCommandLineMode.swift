import Foundation

enum MacCommandLineMode: Equatable, Sendable {
    case normal
    case startGatewayAndQuit

    static let startGatewayAndQuitFlag = "--tron-start-gateway-and-quit"

    static var current: MacCommandLineMode {
        parse(ProcessInfo.processInfo.arguments)
    }

    var isCommand: Bool {
        self != .normal
    }

    static func parse(_ arguments: [String]) -> MacCommandLineMode {
        if arguments.contains(startGatewayAndQuitFlag) {
            return .startGatewayAndQuit
        }
        return .normal
    }
}
