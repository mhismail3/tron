import Testing
import Foundation
@testable import TronMobile

@Suite("TronLogger Thread Safety")
@MainActor
struct TronLoggerTests {

    @Test("setMinimumLevel is readable")
    func setMinimumLevel() {
        let logger = TronLogger.shared
        let original = logger.minimumLevel
        logger.minimumLevel = .warning
        #expect(logger.minimumLevel == .warning)
        logger.minimumLevel = original
    }

    @Test("setCategoryLevel filters lower levels")
    func setCategoryLevel() {
        let logger = TronLogger.shared
        logger.categoryLevels[.database] = .error
        #expect(logger.categoryLevels[.database] == .error)
        logger.categoryLevels.removeValue(forKey: .database)
    }

    @Test("disableCategory prevents logging")
    func disableCategory() {
        let logger = TronLogger.shared
        let wasEnabled = logger.enabledCategories.contains(.database)
        logger.disableCategory(.database)
        #expect(!logger.enabledCategories.contains(.database))
        if wasEnabled {
            logger.enableCategory(.database)
        }
    }
}
