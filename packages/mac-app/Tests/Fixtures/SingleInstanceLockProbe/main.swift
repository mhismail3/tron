import Darwin
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    fputs("usage: SingleInstanceLockProbe <lock-path>\n", stderr)
    exit(EXIT_FAILURE)
}

func emit(_ marker: String) {
    print(marker)
    fflush(stdout)
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
