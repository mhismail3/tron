import Testing
import Foundation
@testable import TronMobile

// MARK: - BashOutputHelpers Tests

@Suite("BashOutputHelpers")
struct BashOutputHelpersTests {

    // MARK: - ANSI Code Stripping

    @Test("Strips basic ANSI color codes")
    func testStripBasicAnsi() {
        let input = "\u{1B}[32mSuccess\u{1B}[0m"
        let result = BashOutputHelpers.stripAnsiCodes(input)
        #expect(result == "Success")
    }

    @Test("Strips bold ANSI codes")
    func testStripBoldAnsi() {
        let input = "\u{1B}[1mBold text\u{1B}[0m"
        let result = BashOutputHelpers.stripAnsiCodes(input)
        #expect(result == "Bold text")
    }

    @Test("Strips compound ANSI codes (e.g., bold + color)")
    func testStripCompoundAnsi() {
        let input = "\u{1B}[1;31mError:\u{1B}[0m file not found"
        let result = BashOutputHelpers.stripAnsiCodes(input)
        #expect(result == "Error: file not found")
    }

    @Test("Preserves text without ANSI codes")
    func testNoAnsiCodes() {
        let input = "just plain text"
        let result = BashOutputHelpers.stripAnsiCodes(input)
        #expect(result == "just plain text")
    }

    @Test("Handles empty string")
    func testEmptyStringAnsi() {
        #expect(BashOutputHelpers.stripAnsiCodes("") == "")
    }

    @Test("Strips multiple ANSI sequences in one line")
    func testMultipleAnsiSequences() {
        let input = "\u{1B}[32m+\u{1B}[0m added \u{1B}[31m-\u{1B}[0m removed"
        let result = BashOutputHelpers.stripAnsiCodes(input)
        #expect(result == "+ added - removed")
    }

    // MARK: - Truncation Marker Stripping

    @Test("Strips iOS truncation marker")
    func testStripIOSTruncation() {
        let input = "line 1\nline 2\n\n... [Output truncated for performance]"
        let result = BashOutputHelpers.stripTruncationMarker(input)
        #expect(result == "line 1\nline 2")
    }

    @Test("Strips short truncation marker")
    func testStripShortTruncation() {
        let input = "output here\n... [Output truncated"
        let result = BashOutputHelpers.stripTruncationMarker(input)
        #expect(result == "output here")
    }

    @Test("Preserves text without truncation marker")
    func testNoTruncationMarker() {
        let input = "normal output\nno truncation"
        let result = BashOutputHelpers.stripTruncationMarker(input)
        #expect(result == "normal output\nno truncation")
    }

    // MARK: - Clean For Display

    @Test("cleanForDisplay strips both ANSI and truncation")
    func testCleanForDisplay() {
        let input = "\u{1B}[32mline 1\u{1B}[0m\nline 2\n\n... [Output truncated for performance]"
        let result = BashOutputHelpers.cleanForDisplay(input)
        #expect(result == "line 1\nline 2")
    }

    // MARK: - Trailing Newline Trimming

    @Test("cleanForDisplay trims single trailing newline")
    func testCleanTrimsTrailingNewline() {
        let result = BashOutputHelpers.cleanForDisplay("hello\n")
        #expect(result == "hello")
    }

    @Test("cleanForDisplay trims multiple trailing newlines")
    func testCleanTrimsMultipleTrailingNewlines() {
        let result = BashOutputHelpers.cleanForDisplay("hello\n\n\n")
        #expect(result == "hello")
    }

    @Test("cleanForDisplay preserves internal blank lines")
    func testCleanPreservesInternalBlanks() {
        let result = BashOutputHelpers.cleanForDisplay("hello\n\nworld\n")
        #expect(result == "hello\n\nworld")
    }

    @Test("cleanForDisplay no-ops when no trailing newline")
    func testCleanNoTrailingNewline() {
        let result = BashOutputHelpers.cleanForDisplay("hello\nworld")
        #expect(result == "hello\nworld")
    }

    @Test("cleanForDisplay handles only-newlines string")
    func testCleanOnlyNewlines() {
        let result = BashOutputHelpers.cleanForDisplay("\n\n\n")
        #expect(result == "")
    }

    @Test("cleanForDisplay preserves leading newlines")
    func testCleanPreservesLeadingNewlines() {
        let result = BashOutputHelpers.cleanForDisplay("\nhello\n")
        #expect(result == "\nhello")
    }

    @Test("cleanForDisplay trims CRLF")
    func testCleanTrimsCRLF() {
        let result = BashOutputHelpers.cleanForDisplay("hello\r\n")
        #expect(result == "hello")
    }

    // MARK: - Line Length Capping

    @Test("Caps long lines at max length")
    func testCapLongLine() {
        let longLine = String(repeating: "x", count: 600)
        let result = BashOutputHelpers.capLineLength(longLine)
        #expect(result.count == 504) // 500 + " ..."
        #expect(result.hasSuffix(" ..."))
    }

    @Test("Preserves short lines unchanged")
    func testCapShortLine() {
        let result = BashOutputHelpers.capLineLength("short line")
        #expect(result == "short line")
    }

    @Test("Returns space for empty line")
    func testCapEmptyLine() {
        let result = BashOutputHelpers.capLineLength("")
        #expect(result == " ")
    }

    @Test("Custom max length works")
    func testCapCustomMaxLength() {
        let result = BashOutputHelpers.capLineLength("hello world", maxLength: 5)
        #expect(result == "hello ...")
    }

    // MARK: - Line Number Width

    @Test("Width scales with digit count")
    func testLineNumberWidth() {
        let small = BashOutputHelpers.lineNumberWidth(lineCount: 9)
        let medium = BashOutputHelpers.lineNumberWidth(lineCount: 100)
        let large = BashOutputHelpers.lineNumberWidth(lineCount: 10000)
        #expect(medium > small)
        #expect(large > medium)
    }

    @Test("Minimum width is 14")
    func testLineNumberMinWidth() {
        let width = BashOutputHelpers.lineNumberWidth(lineCount: 1)
        #expect(width >= 14)
    }

    // MARK: - Collapsed Lines

    @Test("Returns all lines when below threshold")
    func testCollapsedBelowThreshold() {
        let lines = (0..<50).map { "line \($0)" }
        let collapsed = BashOutputHelpers.collapsedLines(from: lines)
        #expect(collapsed.count == 50)
    }

    @Test("Collapses lines above threshold")
    func testCollapsedAboveThreshold() {
        let lines = (0..<200).map { "line \($0)" }
        let collapsed = BashOutputHelpers.collapsedLines(from: lines)
        let expected = BashOutputHelpers.headLines + BashOutputHelpers.tailLines
        #expect(collapsed.count == expected)
    }

    @Test("Collapsed lines preserve correct indices")
    func testCollapsedIndicesPreserved() {
        let lines = (0..<200).map { "line \($0)" }
        let collapsed = BashOutputHelpers.collapsedLines(from: lines)

        // First line should be index 0
        #expect(collapsed.first?.index == 0)
        // Last line should be index 199
        #expect(collapsed.last?.index == 199)
    }

    @Test("Head lines match start of input")
    func testCollapsedHeadContent() {
        let lines = (0..<200).map { "line \($0)" }
        let collapsed = BashOutputHelpers.collapsedLines(from: lines)

        #expect(collapsed[0].content == "line 0")
        #expect(collapsed[BashOutputHelpers.headLines - 1].content == "line \(BashOutputHelpers.headLines - 1)")
    }

    @Test("Tail lines match end of input")
    func testCollapsedTailContent() {
        let lines = (0..<200).map { "line \($0)" }
        let collapsed = BashOutputHelpers.collapsedLines(from: lines)

        #expect(collapsed.last?.content == "line 199")
    }
}

// MARK: - Bash Phase 2 Argument Extraction Tests

@Suite("Bash Phase 2 Argument Parsing")
struct BashPhase2ArgumentTests {

    // MARK: - Shell extraction

    @Test("Extracts shell from arguments")
    func testShellFromArgs() {
        let args = "{\"command\": \"echo $0\", \"shell\": \"zsh\"}"
        #expect(ToolArgumentParser.string("shell", from: args) == "zsh")
    }

    @Test("Shell defaults to nil when not specified")
    func testShellDefault() {
        let args = "{\"command\": \"echo test\"}"
        #expect(ToolArgumentParser.string("shell", from: args) == nil)
    }

    // MARK: - Interactive extraction

    @Test("Extracts interactive boolean")
    func testInteractiveTrue() {
        let args = "{\"command\": \"ssh host\", \"interactive\": true}"
        #expect(ToolArgumentParser.boolean("interactive", from: args) == true)
    }

    @Test("Interactive defaults to nil when not specified")
    func testInteractiveDefault() {
        let args = "{\"command\": \"ls\"}"
        #expect(ToolArgumentParser.boolean("interactive", from: args) == nil)
    }

    // MARK: - Stdin extraction

    @Test("Extracts stdin content")
    func testStdinExtraction() {
        let args = "{\"command\": \"cat\", \"stdin\": \"line1\\nline2\"}"
        #expect(ToolArgumentParser.string("stdin", from: args) == "line1\nline2")
    }

    @Test("Stdin nil when not provided")
    func testStdinMissing() {
        let args = "{\"command\": \"ls\"}"
        #expect(ToolArgumentParser.string("stdin", from: args) == nil)
    }

    // MARK: - Env extraction

    @Test("Extracts env dictionary")
    func testEnvExtraction() {
        let args = "{\"command\": \"echo $FOO\", \"env\": {\"FOO\": \"bar\", \"BAZ\": \"qux\"}}"
        let env = ToolArgumentParser.dictionary("env", from: args)
        #expect(env?["FOO"] == "bar")
        #expect(env?["BAZ"] == "qux")
    }

    @Test("Env nil when not provided")
    func testEnvMissing() {
        let args = "{\"command\": \"ls\"}"
        #expect(ToolArgumentParser.dictionary("env", from: args) == nil)
    }

    // MARK: - Sandbox extraction

    @Test("Extracts sandbox boolean true")
    func testSandboxTrue() {
        let args = "{\"command\": \"ls\", \"sandbox\": true}"
        #expect(ToolArgumentParser.boolean("sandbox", from: args) == true)
    }

    @Test("Extracts sandbox string docker")
    func testSandboxDocker() {
        let args = "{\"command\": \"ls\", \"sandbox\": \"docker\"}"
        #expect(ToolArgumentParser.string("sandbox", from: args) == "docker")
    }

    // MARK: - ptyInput extraction

    @Test("Extracts ptyInput pairs")
    func testPtyInputExtraction() {
        let args = "{\"command\": \"ssh\", \"ptyInput\": [{\"wait\": \"password:\", \"send\": \"secret\"}, {\"wait\": \"y/n\", \"send\": \"y\"}]}"
        let pairs = ToolArgumentParser.objectArray("ptyInput", from: args)
        #expect(pairs?.count == 2)
        #expect(pairs?[0]["wait"] == "password:")
        #expect(pairs?[0]["send"] == "secret")
        #expect(pairs?[1]["wait"] == "y/n")
    }

    // MARK: - Details-based exit code

    @Test("Extracts exit code from details")
    func testExitCodeFromDetails() {
        let details: [String: AnyCodable] = ["exitCode": AnyCodable(1)]
        let code = BashDetailsHelper.exitCode(from: details)
        #expect(code == 1)
    }

    @Test("Exit code nil when missing from details")
    func testExitCodeMissingFromDetails() {
        let details: [String: AnyCodable] = ["command": AnyCodable("ls")]
        let code = BashDetailsHelper.exitCode(from: details)
        #expect(code == nil)
    }

    @Test("Extracts shell from details")
    func testShellFromDetails() {
        let details: [String: AnyCodable] = ["shell": AnyCodable("zsh")]
        #expect(BashDetailsHelper.shell(from: details) == "zsh")
    }

    @Test("Extracts interactive from details")
    func testInteractiveFromDetails() {
        let details: [String: AnyCodable] = ["interactive": AnyCodable(true)]
        #expect(BashDetailsHelper.isInteractive(from: details) == true)
    }

    @Test("Interactive false when missing from details")
    func testInteractiveMissingFromDetails() {
        let details: [String: AnyCodable] = [:]
        #expect(BashDetailsHelper.isInteractive(from: details) == false)
    }
}

// MARK: - Bash Chip Summary Tests

@Suite("Bash Chip Summary Phase 2")
struct BashChipSummaryTests {

    @Test("Basic command summary unchanged")
    func testBasicSummary() {
        let args = "{\"command\": \"git status --short\"}"
        let summary = BashSummaryHelper.summary(from: args)
        #expect(summary == "git status --short")
    }

    @Test("Shell prefix when non-bash")
    func testShellPrefix() {
        let args = "{\"command\": \"echo $0\", \"shell\": \"zsh\"}"
        let summary = BashSummaryHelper.summary(from: args)
        #expect(summary.hasPrefix("zsh:"))
    }

    @Test("No shell prefix for bash")
    func testNoShellPrefixForBash() {
        let args = "{\"command\": \"echo test\", \"shell\": \"bash\"}"
        let summary = BashSummaryHelper.summary(from: args)
        #expect(!summary.hasPrefix("bash:"))
    }

    @Test("PTY prefix for interactive")
    func testPtyPrefix() {
        let args = "{\"command\": \"ssh host\", \"interactive\": true}"
        let summary = BashSummaryHelper.summary(from: args)
        #expect(summary.contains("PTY"))
    }

    @Test("Sandbox prefix for sandbox mode")
    func testSandboxPrefix() {
        let args = "{\"command\": \"ls\", \"sandbox\": true}"
        let summary = BashSummaryHelper.summary(from: args)
        #expect(summary.contains("sandbox"))
    }

    @Test("Docker sandbox prefix")
    func testDockerSandboxPrefix() {
        let args = "{\"command\": \"node -v\", \"sandbox\": \"docker\"}"
        let summary = BashSummaryHelper.summary(from: args)
        #expect(summary.contains("docker"))
    }

    @Test("Background does not add text prefix (badge handles it)")
    func testBackgroundNoTextPrefix() {
        let args = "{\"command\": \"sleep 10\", \"background\": true}"
        let summary = BashSummaryHelper.summary(from: args)
        #expect(!summary.hasPrefix("bg: "))
        #expect(summary == "sleep 10")
    }

    @Test("Long command truncated")
    func testLongCommandTruncated() {
        let long = String(repeating: "x", count: 100)
        let args = "{\"command\": \"\(long)\"}"
        let summary = BashSummaryHelper.summary(from: args)
        #expect(summary.count <= 43) // 40 + "..."
    }
}

// MARK: - ptyInput Redaction Tests

@Suite("Bash ptyInput Redaction")
struct BashPtyInputRedactionTests {

    @Test("Normal wait/send not redacted")
    func testNormalNotRedacted() {
        let pairs: [[String: String]] = [["wait": "continue?", "send": "y"]]
        let result = BashDetailsHelper.redactPtyInput(pairs)
        #expect(result[0]["send"] == "y")
    }

    @Test("Password pattern redacted")
    func testPasswordRedacted() {
        let pairs: [[String: String]] = [["wait": "Enter password:", "send": "secret123"]]
        let result = BashDetailsHelper.redactPtyInput(pairs)
        #expect(result[0]["send"] == "[REDACTED]")
        #expect(result[0]["wait"] == "Enter password:")
    }

    @Test("Token pattern redacted")
    func testTokenRedacted() {
        let pairs: [[String: String]] = [["wait": "API token:", "send": "abc123"]]
        let result = BashDetailsHelper.redactPtyInput(pairs)
        #expect(result[0]["send"] == "[REDACTED]")
    }

    @Test("Secret pattern redacted")
    func testSecretRedacted() {
        let pairs: [[String: String]] = [["wait": "Enter secret:", "send": "mysecret"]]
        let result = BashDetailsHelper.redactPtyInput(pairs)
        #expect(result[0]["send"] == "[REDACTED]")
    }

    @Test("Passphrase pattern redacted")
    func testPassphraseRedacted() {
        let pairs: [[String: String]] = [["wait": "SSH passphrase:", "send": "mypass"]]
        let result = BashDetailsHelper.redactPtyInput(pairs)
        #expect(result[0]["send"] == "[REDACTED]")
    }

    @Test("Mixed pairs - only sensitive redacted")
    func testMixedPairs() {
        let pairs: [[String: String]] = [
            ["wait": "continue?", "send": "y"],
            ["wait": "password:", "send": "secret"],
        ]
        let result = BashDetailsHelper.redactPtyInput(pairs)
        #expect(result[0]["send"] == "y")
        #expect(result[1]["send"] == "[REDACTED]")
    }

    @Test("Empty pairs returns empty")
    func testEmptyPairs() {
        let result = BashDetailsHelper.redactPtyInput([])
        #expect(result.isEmpty)
    }
}
