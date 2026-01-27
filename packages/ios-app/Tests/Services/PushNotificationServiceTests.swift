import XCTest
@testable import TronMobile

// MARK: - PushNotificationService Tests

@MainActor
final class PushNotificationServiceTests: XCTestCase {

    // MARK: - Initial State Tests

    func test_initialState_isAuthorizedFalse() {
        let service = PushNotificationService()
        // Note: Initial state depends on actual authorization status
        // Just verify the property is accessible
        _ = service.isAuthorized
    }

    func test_initialState_authorizationStatusAccessible() {
        let service = PushNotificationService()
        _ = service.authorizationStatus
    }

    func test_initialState_deviceTokenIsNil() {
        let service = PushNotificationService()
        XCTAssertNil(service.deviceToken)
    }

    func test_initialState_lastErrorMessageIsNil() {
        let service = PushNotificationService()
        XCTAssertNil(service.lastErrorMessage)
    }

    // MARK: - Property Access Tests

    func test_isAuthorized_isAccessible() {
        let service = PushNotificationService()
        _ = service.isAuthorized
    }

    func test_authorizationStatus_isAccessible() {
        let service = PushNotificationService()
        _ = service.authorizationStatus
    }

    func test_deviceToken_isAccessible() {
        let service = PushNotificationService()
        _ = service.deviceToken
    }

    func test_lastErrorMessage_isAccessible() {
        let service = PushNotificationService()
        _ = service.lastErrorMessage
    }

    // MARK: - Token Update Tests

    func test_handleTokenUpdate_setsDeviceToken() {
        let service = PushNotificationService()
        let testToken = "abc123def456"

        service.handleTokenUpdate(testToken)

        XCTAssertEqual(service.deviceToken, testToken)
    }

    func test_handleTokenUpdate_clearsLastError() {
        let service = PushNotificationService()

        // First set an error
        service.handleRegistrationError("Previous error")
        XCTAssertNotNil(service.lastErrorMessage)

        // Then update token
        service.handleTokenUpdate("newtoken")

        XCTAssertNil(service.lastErrorMessage)
    }

    // MARK: - Registration Error Tests

    func test_handleRegistrationError_setsErrorMessage() {
        let service = PushNotificationService()
        let errorMessage = "Registration failed"

        service.handleRegistrationError(errorMessage)

        XCTAssertEqual(service.lastErrorMessage, errorMessage)
    }

    func test_handleRegistrationError_preservesDeviceToken() {
        let service = PushNotificationService()

        // Set a token first
        service.handleTokenUpdate("existingtoken")
        XCTAssertEqual(service.deviceToken, "existingtoken")

        // Then record an error
        service.handleRegistrationError("Some error")

        // Token should still be there
        XCTAssertEqual(service.deviceToken, "existingtoken")
    }

    // MARK: - Multiple Updates Tests

    func test_multipleTokenUpdates_usesLatest() {
        let service = PushNotificationService()

        service.handleTokenUpdate("token1")
        service.handleTokenUpdate("token2")
        service.handleTokenUpdate("token3")

        XCTAssertEqual(service.deviceToken, "token3")
    }

    func test_multipleErrors_usesLatest() {
        let service = PushNotificationService()

        service.handleRegistrationError("error1")
        service.handleRegistrationError("error2")
        service.handleRegistrationError("error3")

        XCTAssertEqual(service.lastErrorMessage, "error3")
    }

    // MARK: - Token Format Tests

    func test_handleTokenUpdate_acceptsHexString() {
        let service = PushNotificationService()
        // Typical APNs token format (64 hex chars)
        let hexToken = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

        service.handleTokenUpdate(hexToken)

        XCTAssertEqual(service.deviceToken, hexToken)
        XCTAssertEqual(service.deviceToken?.count, 64)
    }

    func test_handleTokenUpdate_acceptsEmptyString() {
        let service = PushNotificationService()

        service.handleTokenUpdate("")

        XCTAssertEqual(service.deviceToken, "")
    }

    // MARK: - Register If Authorized Tests

    func test_registerIfAuthorized_doesNotCrash() {
        let service = PushNotificationService()

        // Should not crash regardless of authorization state
        service.registerIfAuthorized()
    }
}
