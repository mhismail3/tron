import Darwin
import Foundation

struct MacReplacementQuit: Decodable, Sendable {
    let version: Int
    let id: UUID
    let appPID: Int
    let appStart: String
    let createdAt: Double

    static func current(directory: URL, pid: Int, start: String?) -> Self? {
        guard let request: Self = readPrivate(directory.appendingPathComponent("request.json")),
              request.version == 1, request.appPID == pid,
              (0...60).contains(Date().timeIntervalSince1970 - request.createdAt),
              start == request.appStart else { return nil }
        return request
    }

    func publish(directory: URL, state: String, detail: String) throws {
        guard let current: Self = Self.readPrivate(directory.appendingPathComponent("request.json")),
              current.id == id else { return }
        let data = try JSONSerialization.data(withJSONObject: [
                "version": 1, "id": id.uuidString.lowercased(), "appPID": appPID,
                "appStart": appStart, "state": state, "detail": detail,
            ])
        try AtomicFileWriter.write(data, to: directory.appendingPathComponent("result.json"))
    }

    private static func readPrivate<T: Decodable>(_ url: URL) -> T? {
        for parent in [url.deletingLastPathComponent(), url.deletingLastPathComponent().deletingLastPathComponent(),
                       url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()] {
            var info = stat()
            guard lstat(parent.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { return nil }
        }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_size <= 4096,
              let data = try? handle.read(upToCount: 4097), data.count <= 4096 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
