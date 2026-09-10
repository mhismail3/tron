import Foundation
import Testing
@testable import TronMac

@Suite("Native host reply ownership")
struct NativeHostReplyTests {
    @Test("the built app contains the declared Aqua Mach service and executable")
    func bundledMachService() throws {
        let app = Bundle.main.bundleURL
        let url = app.appendingPathComponent("Contents/Library/LaunchAgents/" + NativeHostTrust.launchAgentPlistName)
        let values = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        #expect(values["Label"] as? String == NativeHostTrust.machServiceName)
        #expect(values["LimitLoadToSessionType"] as? String == "Aqua")
        #expect((values["MachServices"] as? [String: Bool]) == [NativeHostTrust.machServiceName: true])
        #expect((values["AssociatedBundleIdentifiers"] as? [String]) == ["com.tron.mac"])
        let executable = NativeHostTrust.relativeBundlePath + "/Contents/MacOS/TronNativeHost"
        #expect(values["BundleProgram"] as? String == executable)
        #expect(FileManager.default.isExecutableFile(atPath: app.appendingPathComponent(executable).path))
    }

    @Test("an early reply is retained and later errors cannot replace it")
    func earlyReply() async {
        let reply = NativeHostReply<Int>()
        #expect(reply.resolve(7))
        #expect(!reply.resolve(99))
        #expect(await reply.value() == 7)
    }

    @Test("permission command receipts reject conflicting replays and remain bounded")
    func commandReceipts() {
        var receipts = NativePermissionRequestReceipts()
        let id = UUID()
        #expect(receipts.cachedStatus(for: .accessibility, id: id) == nil)
        receipts.record("granted", for: .accessibility, id: id)
        receipts.record("notDetermined", for: .accessibility, id: id)
        #expect(receipts.cachedStatus(for: .accessibility, id: id) == "granted")
        #expect(receipts.cachedStatus(for: .screenRecording, id: id) == "probeUnavailable")
        for _ in 0..<16 { receipts.record("notDetermined", for: .inputMonitoring, id: UUID()) }
        #expect(receipts.cachedStatus(for: .accessibility, id: id) == nil)
    }

    @Test("concurrent reply, timeout and error paths have exactly one winner")
    func oneWinner() async {
        let reply = NativeHostReply<Int>()
        let waiter = Task { await reply.value() }
        let winners = await withTaskGroup(of: Int?.self, returning: [Int].self) { group in
            for value in 0..<32 { group.addTask { reply.resolve(value) ? value : nil } }
            var values: [Int] = []
            for await value in group { if let value { values.append(value) } }
            return values
        }
        #expect(winners.count == 1)
        #expect(winners == [await waiter.value])
    }
}
