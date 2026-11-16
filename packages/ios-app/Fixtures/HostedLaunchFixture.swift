#if HOSTED_TEST
import Foundation
import Synchronization

enum HostedLaunch {
    private static let storage = Mutex(ProcessInfo.processInfo.arguments)

    static var arguments: [String] {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}
#endif
