import Darwin
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    fputs("usage: SingleInstanceLockProbe <lock-path>\n", stderr)
    exit(EXIT_FAILURE)
}

func emit(_ marker: String) {
    // A pipe is a byte stream, not a marker transport. Force two reads so the
    // real lock journey also catches readers that mistake one chunk for a line.
    let bytes = Data("\(marker)\n".utf8)
    FileHandle.standardOutput.write(bytes.prefix(1))
    usleep(20_000)
    FileHandle.standardOutput.write(bytes.dropFirst())
}

let lock = SingleInstanceLock(lockFileURL: URL(fileURLWithPath: arguments[1], isDirectory: false))
guard lock.acquire() else {
    emit("rejected")
    exit(2)
}

emit("acquired")
let input = FileHandle.standardInput
while true {
    guard let data = try? input.read(upToCount: 4096), !data.isEmpty else { break }
}
lock.release()
emit("released")
