import Foundation

/// Minimal path shim for the probe target; the production lock's default is
/// not used because every probe invocation receives an explicit disposable path.
enum TronPaths {
    static let macWrapperLockPath = URL(fileURLWithPath: "/tmp/tron-lock-probe-unused.lock")
}
