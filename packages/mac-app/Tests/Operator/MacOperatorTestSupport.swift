import Darwin
import Foundation

actor OperatorTestSignal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        signalled = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }

    func wait() async {
        if signalled {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

enum MacOperatorTestSocket {
    static func call(
        at path: String,
        value: [String: Any]
    ) throws -> Data {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let length = MemoryLayout<sa_family_t>.size + path.utf8.count + 1
        address.sun_len = UInt8(length)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                path.withCString {
                    _ = strlcpy(destination, $0, capacity)
                }
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(length))
            }
        }
        guard connected == 0 else { throw CocoaError(.fileReadUnknown) }
        let request = try JSONSerialization.data(withJSONObject: value)
        try request.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress,
                  Darwin.send(descriptor, base, request.count, 0) == request.count
            else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        Darwin.shutdown(descriptor, SHUT_WR)
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
            if count == 0 { break }
            guard count > 0 else { throw CocoaError(.fileReadUnknown) }
            response.append(buffer, count: count)
        }
        return response
    }
}
