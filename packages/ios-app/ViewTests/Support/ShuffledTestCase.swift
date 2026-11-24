import XCTest

class ShuffledTestCase: XCTestCase {
    override class var defaultTestSuite: XCTestSuite {
        guard self != ShuffledTestCase.self else { return super.defaultTestSuite }
        let seed = ProcessInfo.processInfo.environment["TRON_VIEW_TESTS_SEED"].flatMap(UInt64.init) ?? UInt64.random(in: 1...UInt64(UInt32.max))
        print("TronMobileViewTests order seed \(seed) for \(self)")
        var generator = SplitMix(state: seed)
        let suite = XCTestSuite(name: String(describing: self))
        for test in super.defaultTestSuite.tests.shuffled(using: &generator) { suite.addTest(test) }
        return suite
    }
}

private struct SplitMix: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
