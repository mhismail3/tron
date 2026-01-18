import XCTest
import UIKit
@testable import TronMobile

@MainActor
final class BrowserStateTests: XCTestCase {

    func testBrowserFrameUpdate() {
        let state = BrowserState()
        XCTAssertNil(state.browserFrame)

        let testImage = UIImage()
        state.browserFrame = testImage
        XCTAssertNotNil(state.browserFrame)
    }

    func testUserDismissedBrowserThisTurn() {
        let state = BrowserState()
        XCTAssertFalse(state.userDismissedBrowserThisTurn)

        state.userDismissedBrowserThisTurn = true
        XCTAssertTrue(state.userDismissedBrowserThisTurn)
    }

    func testBrowserStatusTracking() {
        let state = BrowserState()
        XCTAssertNil(state.browserStatus)

        let status = BrowserGetStatusResult(hasBrowser: true, isStreaming: true, currentUrl: "https://example.com")
        state.browserStatus = status
        XCTAssertNotNil(state.browserStatus)
        XCTAssertEqual(state.browserStatus?.hasBrowser, true)
        XCTAssertEqual(state.browserStatus?.isStreaming, true)
    }

    func testShowBrowserWindow() {
        let state = BrowserState()
        XCTAssertFalse(state.showBrowserWindow)

        state.showBrowserWindow = true
        XCTAssertTrue(state.showBrowserWindow)
    }

    func testSafariURL() {
        let state = BrowserState()
        XCTAssertNil(state.safariURL)

        let url = URL(string: "https://apple.com")!
        state.safariURL = url
        XCTAssertEqual(state.safariURL, url)
    }

    func testHasBrowserSession() {
        let state = BrowserState()
        XCTAssertFalse(state.hasBrowserSession)

        // Has browser frame
        state.browserFrame = UIImage()
        XCTAssertTrue(state.hasBrowserSession)

        // Clear frame, add status
        state.browserFrame = nil
        state.browserStatus = BrowserGetStatusResult(hasBrowser: true, isStreaming: false, currentUrl: nil)
        XCTAssertTrue(state.hasBrowserSession)
    }

    func testResetForNewTurn() {
        let state = BrowserState()
        state.userDismissedBrowserThisTurn = true
        state.resetForNewTurn()
        XCTAssertFalse(state.userDismissedBrowserThisTurn)
    }

    func testClearAll() {
        let state = BrowserState()
        state.browserFrame = UIImage()
        state.browserStatus = BrowserGetStatusResult(hasBrowser: true, isStreaming: true, currentUrl: nil)
        state.showBrowserWindow = true
        state.safariURL = URL(string: "https://example.com")
        state.userDismissedBrowserThisTurn = true

        state.clearAll()

        XCTAssertNil(state.browserFrame)
        XCTAssertNil(state.browserStatus)
        XCTAssertFalse(state.showBrowserWindow)
        XCTAssertNil(state.safariURL)
        XCTAssertFalse(state.userDismissedBrowserThisTurn)
    }
}
