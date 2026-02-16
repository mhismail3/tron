import Testing
import Foundation
@testable import TronMobile

// MARK: - OpenURLDetailParser Tests

@Suite("OpenURLDetailParser")
struct OpenURLDetailParserTests {

    // MARK: - Error Detection

    @Test("Detects error in invalid URL result")
    func testIsErrorInvalidURL() {
        #expect(OpenURLDetailParser.isError("Invalid URL format: \"not a url\"") == true)
    }

    @Test("Detects error in failed result")
    func testIsErrorFailed() {
        #expect(OpenURLDetailParser.isError("Failed to open URL: timeout") == true)
    }

    @Test("Detects error in missing param result")
    func testIsErrorMissing() {
        #expect(OpenURLDetailParser.isError("Missing required parameter: url") == true)
    }

    @Test("Returns false for success result")
    func testIsErrorSuccess() {
        #expect(OpenURLDetailParser.isError("Opening https://example.com in Safari") == false)
    }

    // MARK: - Error Extraction

    @Test("Extracts error from 'Error:' prefix")
    func testExtractErrorPrefix() {
        let error = OpenURLDetailParser.extractError(from: "Error: Something went wrong")
        #expect(error == "Something went wrong")
    }

    @Test("Returns raw string for non-Error: format")
    func testExtractErrorFallback() {
        let msg = "Invalid URL format: bad"
        let error = OpenURLDetailParser.extractError(from: msg)
        #expect(error == msg)
    }

    // MARK: - Error Classification

    @Test("Classifies invalid URL format")
    func testClassifyInvalidFormat() {
        let info = OpenURLDetailParser.classifyError("Invalid URL format: \"not a url\"")
        #expect(info.title == "Invalid URL")
        #expect(info.code == "INVALID_FORMAT")
    }

    @Test("Classifies invalid scheme")
    func testClassifyInvalidScheme() {
        let info = OpenURLDetailParser.classifyError("Invalid URL scheme: \"ftp\". Only http:// and https:// URLs are allowed.")
        #expect(info.title == "Invalid Scheme")
        #expect(info.code == "INVALID_SCHEME")
    }

    @Test("Classifies missing URL parameter")
    func testClassifyMissingURL() {
        let info = OpenURLDetailParser.classifyError("Missing required parameter: url")
        #expect(info.title == "Missing URL")
        #expect(info.code == "MISSING_PARAM")
    }

    @Test("Classifies failed to open")
    func testClassifyFailedToOpen() {
        let info = OpenURLDetailParser.classifyError("Failed to open URL: browser unavailable")
        #expect(info.title == "Failed to Open")
        #expect(info.code == nil)
    }

    @Test("Classifies generic error")
    func testClassifyGeneric() {
        let info = OpenURLDetailParser.classifyError("Something unexpected happened")
        #expect(info.title == "Open Failed")
        #expect(info.code == nil)
    }
}
