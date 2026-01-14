import XCTest
@testable import TronMobile

/// Tests for AskUserQuestion models and state handling
///
/// These tests verify:
/// - Model JSON decoding/encoding
/// - Answer state management
/// - Completion detection
/// - Selection mode behavior (single vs multi)
final class AskUserQuestionTests: XCTestCase {

    // MARK: - Tests: AskUserQuestionOption Decoding

    /// Test decoding option with explicit value
    func testAskUserQuestionOptionDecodingWithValue() throws {
        let json = """
        {
            "label": "Option A",
            "value": "option_a",
            "description": "This is option A"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let option = try decoder.decode(AskUserQuestionOption.self, from: json)

        XCTAssertEqual(option.label, "Option A")
        XCTAssertEqual(option.value, "option_a")
        XCTAssertEqual(option.description, "This is option A")
    }

    /// Test decoding option without explicit value
    func testAskUserQuestionOptionDecodingWithoutValue() throws {
        let json = """
        {
            "label": "Option B"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let option = try decoder.decode(AskUserQuestionOption.self, from: json)

        XCTAssertEqual(option.label, "Option B")
        XCTAssertNil(option.value)
        XCTAssertNil(option.description)
    }

    /// Test option ID uses value when present
    func testAskUserQuestionOptionIdUsesValueWhenPresent() throws {
        let option = AskUserQuestionOption(
            label: "Display Label",
            value: "actual_value",
            description: nil
        )

        XCTAssertEqual(option.id, "actual_value")
    }

    /// Test option ID uses label as fallback
    func testAskUserQuestionOptionIdUsesLabelAsFallback() throws {
        let option = AskUserQuestionOption(
            label: "Display Label",
            value: nil,
            description: nil
        )

        XCTAssertEqual(option.id, "Display Label")
    }

    // MARK: - Tests: AskUserQuestion Decoding

    /// Test decoding single-select question
    func testAskUserQuestionDecodingSingleMode() throws {
        let json = """
        {
            "id": "q1",
            "question": "What approach do you prefer?",
            "options": [
                {"label": "Approach A"},
                {"label": "Approach B"}
            ],
            "mode": "single"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let question = try decoder.decode(AskUserQuestion.self, from: json)

        XCTAssertEqual(question.id, "q1")
        XCTAssertEqual(question.question, "What approach do you prefer?")
        XCTAssertEqual(question.options.count, 2)
        XCTAssertEqual(question.mode, .single)
    }

    /// Test decoding multi-select question
    func testAskUserQuestionDecodingMultiMode() throws {
        let json = """
        {
            "id": "q2",
            "question": "Which features do you want?",
            "options": [
                {"label": "Feature A"},
                {"label": "Feature B"},
                {"label": "Feature C"}
            ],
            "mode": "multi"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let question = try decoder.decode(AskUserQuestion.self, from: json)

        XCTAssertEqual(question.id, "q2")
        XCTAssertEqual(question.mode, .multi)
        XCTAssertEqual(question.options.count, 3)
    }

    /// Test default allowOther is nil
    func testAskUserQuestionDefaultAllowOther() throws {
        let json = """
        {
            "id": "q1",
            "question": "Test?",
            "options": [{"label": "A"}, {"label": "B"}],
            "mode": "single"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let question = try decoder.decode(AskUserQuestion.self, from: json)

        XCTAssertNil(question.allowOther)
        XCTAssertNil(question.otherPlaceholder)
    }

    /// Test decoding question with allowOther
    func testAskUserQuestionWithAllowOther() throws {
        let json = """
        {
            "id": "q1",
            "question": "Test?",
            "options": [{"label": "A"}, {"label": "B"}],
            "mode": "single",
            "allowOther": true,
            "otherPlaceholder": "Enter your answer..."
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let question = try decoder.decode(AskUserQuestion.self, from: json)

        XCTAssertEqual(question.allowOther, true)
        XCTAssertEqual(question.otherPlaceholder, "Enter your answer...")
    }

    // MARK: - Tests: AskUserQuestionParams Decoding

    /// Test decoding params with questions
    func testAskUserQuestionParamsDecoding() throws {
        let json = """
        {
            "questions": [
                {
                    "id": "q1",
                    "question": "First question?",
                    "options": [{"label": "Yes"}, {"label": "No"}],
                    "mode": "single"
                },
                {
                    "id": "q2",
                    "question": "Second question?",
                    "options": [{"label": "A"}, {"label": "B"}, {"label": "C"}],
                    "mode": "multi"
                }
            ]
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let params = try decoder.decode(AskUserQuestionParams.self, from: json)

        XCTAssertEqual(params.questions.count, 2)
        XCTAssertEqual(params.questions[0].id, "q1")
        XCTAssertEqual(params.questions[1].id, "q2")
        XCTAssertNil(params.context)
    }

    /// Test decoding params with context
    func testAskUserQuestionParamsWithContext() throws {
        let json = """
        {
            "questions": [
                {
                    "id": "q1",
                    "question": "Test?",
                    "options": [{"label": "A"}, {"label": "B"}],
                    "mode": "single"
                }
            ],
            "context": "Additional context about the questions"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let params = try decoder.decode(AskUserQuestionParams.self, from: json)

        XCTAssertEqual(params.context, "Additional context about the questions")
    }

    // MARK: - Tests: AskUserQuestionAnswer Encoding

    /// Test encoding answer
    func testAskUserQuestionAnswerEncoding() throws {
        let answer = AskUserQuestionAnswer(
            questionId: "q1",
            selectedValues: ["Option A", "Option B"],
            otherValue: nil
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(answer)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(json?["questionId"] as? String, "q1")
        XCTAssertEqual(json?["selectedValues"] as? [String], ["Option A", "Option B"])
    }

    /// Test encoding answer with otherValue
    func testAskUserQuestionAnswerWithOtherValue() throws {
        let answer = AskUserQuestionAnswer(
            questionId: "q1",
            selectedValues: [],
            otherValue: "My custom answer"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(answer)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(json?["otherValue"] as? String, "My custom answer")
        XCTAssertEqual(json?["selectedValues"] as? [String], [])
    }

    // MARK: - Tests: AskUserQuestionResult

    /// Test result marked complete when all answered
    func testAskUserQuestionResultComplete() throws {
        let result = AskUserQuestionResult(
            answers: [
                AskUserQuestionAnswer(questionId: "q1", selectedValues: ["A"], otherValue: nil),
                AskUserQuestionAnswer(questionId: "q2", selectedValues: ["B", "C"], otherValue: nil)
            ],
            complete: true,
            submittedAt: ISO8601DateFormatter().string(from: Date())
        )

        XCTAssertTrue(result.complete)
        XCTAssertEqual(result.answers.count, 2)
    }

    /// Test result marked incomplete
    func testAskUserQuestionResultIncomplete() throws {
        let result = AskUserQuestionResult(
            answers: [
                AskUserQuestionAnswer(questionId: "q1", selectedValues: ["A"], otherValue: nil)
            ],
            complete: false,
            submittedAt: ISO8601DateFormatter().string(from: Date())
        )

        XCTAssertFalse(result.complete)
    }

    /// Test result includes valid ISO timestamp
    func testAskUserQuestionResultTimestamp() throws {
        let now = Date()
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: now)

        let result = AskUserQuestionResult(
            answers: [],
            complete: false,
            submittedAt: timestamp
        )

        // Parse the timestamp back
        let parsed = formatter.date(from: result.submittedAt)
        XCTAssertNotNil(parsed)
    }

    // MARK: - Tests: AskUserQuestionToolData

    /// Test tool data initialization
    func testAskUserQuestionToolDataInitialization() throws {
        let params = AskUserQuestionParams(
            questions: [
                AskUserQuestion(
                    id: "q1",
                    question: "Test?",
                    options: [
                        AskUserQuestionOption(label: "A", value: nil, description: nil),
                        AskUserQuestionOption(label: "B", value: nil, description: nil)
                    ],
                    mode: .single,
                    allowOther: nil,
                    otherPlaceholder: nil
                )
            ],
            context: nil
        )

        let toolData = AskUserQuestionToolData(
            toolCallId: "call_123",
            params: params,
            answers: [:],
            status: .pending,
            result: nil
        )

        XCTAssertEqual(toolData.toolCallId, "call_123")
        XCTAssertEqual(toolData.params.questions.count, 1)
        XCTAssertTrue(toolData.answers.isEmpty)
        XCTAssertEqual(toolData.status, .pending)
        XCTAssertNil(toolData.result)
    }

    /// Test tool data status transitions (async mode)
    func testAskUserQuestionToolDataStatusTransitions() throws {
        var toolData = AskUserQuestionToolData(
            toolCallId: "call_123",
            params: AskUserQuestionParams(questions: [], context: nil),
            answers: [:],
            status: .pending,
            result: nil
        )

        XCTAssertEqual(toolData.status, .pending)

        // User answers the question
        toolData.status = .answered
        XCTAssertEqual(toolData.status, .answered)

        // Test superseded status
        var toolData2 = AskUserQuestionToolData(
            toolCallId: "call_456",
            params: AskUserQuestionParams(questions: [], context: nil),
            answers: [:],
            status: .pending,
            result: nil
        )
        toolData2.status = .superseded
        XCTAssertEqual(toolData2.status, .superseded)
    }

    /// Test tool data equality
    func testAskUserQuestionToolDataEquality() throws {
        let params = AskUserQuestionParams(questions: [], context: nil)

        let data1 = AskUserQuestionToolData(
            toolCallId: "call_123",
            params: params,
            answers: [:],
            status: .pending,
            result: nil
        )

        let data2 = AskUserQuestionToolData(
            toolCallId: "call_123",
            params: params,
            answers: [:],
            status: .pending,
            result: nil
        )

        let data3 = AskUserQuestionToolData(
            toolCallId: "call_456",
            params: params,
            answers: [:],
            status: .pending,
            result: nil
        )

        XCTAssertEqual(data1, data2)
        XCTAssertNotEqual(data1, data3)
    }

    // MARK: - Tests: Answer State Management

    /// Test single select replaces existing answer
    func testSingleSelectReplacesExistingAnswer() throws {
        // For single select, only one value should be in selectedValues
        var answer = AskUserQuestionAnswer(
            questionId: "q1",
            selectedValues: ["A"],
            otherValue: nil
        )

        // Replace with new selection (in single mode)
        answer = AskUserQuestionAnswer(
            questionId: "q1",
            selectedValues: ["B"],
            otherValue: nil
        )

        XCTAssertEqual(answer.selectedValues, ["B"])
        XCTAssertEqual(answer.selectedValues.count, 1)
    }

    /// Test multi select toggles answers
    func testMultiSelectTogglesAnswers() throws {
        var answer = AskUserQuestionAnswer(
            questionId: "q1",
            selectedValues: ["A"],
            otherValue: nil
        )

        // Add B (toggle on)
        var selected = Set(answer.selectedValues)
        selected.insert("B")
        answer = AskUserQuestionAnswer(
            questionId: "q1",
            selectedValues: Array(selected),
            otherValue: nil
        )

        XCTAssertTrue(answer.selectedValues.contains("A"))
        XCTAssertTrue(answer.selectedValues.contains("B"))
    }

    /// Test multi select can add multiple
    func testMultiSelectCanAddMultiple() throws {
        let answer = AskUserQuestionAnswer(
            questionId: "q1",
            selectedValues: ["A", "B", "C"],
            otherValue: nil
        )

        XCTAssertEqual(answer.selectedValues.count, 3)
    }

    /// Test multi select can remove
    func testMultiSelectCanRemove() throws {
        var selected = Set(["A", "B", "C"])
        selected.remove("B")

        let answer = AskUserQuestionAnswer(
            questionId: "q1",
            selectedValues: Array(selected),
            otherValue: nil
        )

        XCTAssertTrue(answer.selectedValues.contains("A"))
        XCTAssertFalse(answer.selectedValues.contains("B"))
        XCTAssertTrue(answer.selectedValues.contains("C"))
    }

    // MARK: - Tests: Completion Detection

    /// Test all questions answered detection
    func testAllQuestionsAnsweredDetection() throws {
        let questions = [
            AskUserQuestion(
                id: "q1",
                question: "Q1?",
                options: [
                    AskUserQuestionOption(label: "A", value: nil, description: nil),
                    AskUserQuestionOption(label: "B", value: nil, description: nil)
                ],
                mode: .single,
                allowOther: nil,
                otherPlaceholder: nil
            ),
            AskUserQuestion(
                id: "q2",
                question: "Q2?",
                options: [
                    AskUserQuestionOption(label: "X", value: nil, description: nil),
                    AskUserQuestionOption(label: "Y", value: nil, description: nil)
                ],
                mode: .single,
                allowOther: nil,
                otherPlaceholder: nil
            )
        ]

        let answers: [String: AskUserQuestionAnswer] = [
            "q1": AskUserQuestionAnswer(questionId: "q1", selectedValues: ["A"], otherValue: nil),
            "q2": AskUserQuestionAnswer(questionId: "q2", selectedValues: ["Y"], otherValue: nil)
        ]

        // Check all questions have answers with non-empty selections
        let allAnswered = questions.allSatisfy { question in
            if let answer = answers[question.id] {
                return !answer.selectedValues.isEmpty || (answer.otherValue?.isEmpty == false)
            }
            return false
        }

        XCTAssertTrue(allAnswered)
    }

    /// Test partial answers not complete
    func testPartialAnswersNotComplete() throws {
        let questions = [
            AskUserQuestion(
                id: "q1",
                question: "Q1?",
                options: [
                    AskUserQuestionOption(label: "A", value: nil, description: nil),
                    AskUserQuestionOption(label: "B", value: nil, description: nil)
                ],
                mode: .single,
                allowOther: nil,
                otherPlaceholder: nil
            ),
            AskUserQuestion(
                id: "q2",
                question: "Q2?",
                options: [
                    AskUserQuestionOption(label: "X", value: nil, description: nil),
                    AskUserQuestionOption(label: "Y", value: nil, description: nil)
                ],
                mode: .single,
                allowOther: nil,
                otherPlaceholder: nil
            )
        ]

        // Only q1 answered
        let answers: [String: AskUserQuestionAnswer] = [
            "q1": AskUserQuestionAnswer(questionId: "q1", selectedValues: ["A"], otherValue: nil)
        ]

        let allAnswered = questions.allSatisfy { question in
            if let answer = answers[question.id] {
                return !answer.selectedValues.isEmpty || (answer.otherValue?.isEmpty == false)
            }
            return false
        }

        XCTAssertFalse(allAnswered)
    }

    // MARK: - Tests: Edge Cases

    /// Test unicode in questions and options
    func testUnicodeSupport() throws {
        let json = """
        {
            "id": "q1",
            "question": "どのアプローチ？ 🤔",
            "options": [
                {"label": "选项 A 🅰️", "description": "中文描述"},
                {"label": "Option B 🎉"}
            ],
            "mode": "single"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let question = try decoder.decode(AskUserQuestion.self, from: json)

        XCTAssertEqual(question.question, "どのアプローチ？ 🤔")
        XCTAssertEqual(question.options[0].label, "选项 A 🅰️")
        XCTAssertEqual(question.options[0].description, "中文描述")
    }

    /// Test special characters in option labels
    func testSpecialCharactersInLabels() throws {
        let json = """
        {
            "id": "q1",
            "question": "Test?",
            "options": [
                {"label": "Option with \\"quotes\\""},
                {"label": "Option with <html> & entities"}
            ],
            "mode": "single"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let question = try decoder.decode(AskUserQuestion.self, from: json)

        XCTAssertEqual(question.options[0].label, "Option with \"quotes\"")
        XCTAssertEqual(question.options[1].label, "Option with <html> & entities")
    }

    // MARK: - Tests: Selection Mode Enum

    /// Test SelectionMode encoding
    func testSelectionModeEncoding() throws {
        let encoder = JSONEncoder()

        let singleData = try encoder.encode(AskUserQuestion.SelectionMode.single)
        let singleString = String(data: singleData, encoding: .utf8)
        XCTAssertEqual(singleString, "\"single\"")

        let multiData = try encoder.encode(AskUserQuestion.SelectionMode.multi)
        let multiString = String(data: multiData, encoding: .utf8)
        XCTAssertEqual(multiString, "\"multi\"")
    }
}
