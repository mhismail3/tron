import XCTest
@testable import TronMobile

/// Tests for ErrorEventProjection — focused on I6 (scorched-earth provider-error
/// decoding). `category` is required on `error.provider` events; missing
/// category drops the event entirely (no plain-text recovery). `"unknown"`
/// is a legitimate classification that routes through the generic-pill path,
/// never the retired error-text path (which has been deleted).
final class ErrorEventProjectionTests: XCTestCase {

    private func timestamp() -> Date { Date(timeIntervalSince1970: 1_700_000_000) }

    // MARK: - transformProviderError

    func test_provider_error_missing_category_drops_event() {
        // No category field — strict decoder rejects, projection returns nil.
        // Matches Rust `deny_unknown_fields` on ErrorProviderPayload.
        let payload: [String: AnyCodable] = [
            "provider": AnyCodable("anthropic"),
            "error": AnyCodable("rate limited"),
            "retryable": AnyCodable(true),
        ]
        let msg = ErrorEventProjection.transformProviderError(payload, timestamp: timestamp())
        XCTAssertNil(msg, "missing category must drop the event, never render plain text")
    }

    func test_provider_error_with_real_category_renders_pill() {
        let payload: [String: AnyCodable] = [
            "provider": AnyCodable("anthropic"),
            "error": AnyCodable("rate limited"),
            "category": AnyCodable("rate_limit"),
            "retryable": AnyCodable(true),
        ]
        let msg = ErrorEventProjection.transformProviderError(payload, timestamp: timestamp())
        guard let msg else {
            XCTFail("expected a rendered message")
            return
        }
        XCTAssertEqual(msg.role, .system, "provider errors render as system pill, not assistant text")
        if case .systemEvent(.providerError(let data)) = msg.content {
            XCTAssertEqual(data.category, "rate_limit")
            XCTAssertEqual(data.provider, "anthropic")
            XCTAssertEqual(data.message, "rate limited")
            XCTAssertTrue(data.retryable)
        } else {
            XCTFail("expected .systemEvent(.providerError) content, got \(msg.content)")
        }
    }

    func test_provider_error_prefers_canonical_failure_envelope() {
        let payload: [String: AnyCodable] = [
            "provider": AnyCodable("anthropic"),
            "error": AnyCodable("top-level message"),
            "code": AnyCodable("TOP_LEVEL_CODE"),
            "category": AnyCodable("api"),
            "retryable": AnyCodable(false),
            "details": AnyCodable([
                "failure": [
                    "code": "PROVIDER_RATE_LIMITED",
                    "category": "rate_limit",
                    "message": "canonical rate limit",
                    "retryable": true,
                    "recoverable": true,
                    "origin": "model_provider",
                    "provider": "anthropic",
                    "model": "claude-sonnet-4",
                    "statusCode": 429,
                    "errorType": "rate_limit_error",
                    "retryAfterMs": 1200,
                    "suggestion": "Wait before retrying",
                ] as [String: Any],
            ] as [String: Any]),
        ]

        let msg = ErrorEventProjection.transformProviderError(payload, timestamp: timestamp())

        guard case .systemEvent(.providerError(let data)) = msg?.content else {
            XCTFail("expected provider error content")
            return
        }
        XCTAssertEqual(data.category, "rate_limit")
        XCTAssertEqual(data.message, "canonical rate limit")
        XCTAssertTrue(data.retryable)
        XCTAssertEqual(data.recoverable, true)
        XCTAssertEqual(data.origin, "model_provider")
        XCTAssertEqual(data.statusCode, 429)
        XCTAssertEqual(data.errorType, "rate_limit_error")
        XCTAssertEqual(data.model, "claude-sonnet-4")
        XCTAssertEqual(data.retryAfterMs, 1200)
        XCTAssertEqual(data.failure?.code, "PROVIDER_RATE_LIMITED")
    }

    func test_provider_error_unknown_category_renders_pill_with_generic_icon() {
        // "unknown" is a real classification emitted by the import transformer
        // and any other layer that couldn't narrow further. It MUST flow
        // through the pill path (not the old plain-text recovery) — the
        // ErrorCategoryDisplay.icon default case gives it a generic
        // exclamationmark.triangle.fill icon.
        let payload: [String: AnyCodable] = [
            "provider": AnyCodable("anthropic"),
            "error": AnyCodable("something went wrong"),
            "category": AnyCodable("unknown"),
            "retryable": AnyCodable(false),
        ]
        let msg = ErrorEventProjection.transformProviderError(payload, timestamp: timestamp())
        guard let msg else {
            XCTFail("expected a rendered message")
            return
        }
        XCTAssertEqual(msg.role, .system, "unknown category must still render as system pill, not retired plain text")
        if case .systemEvent(.providerError(let data)) = msg.content {
            XCTAssertEqual(data.category, "unknown")
            // Regression guard: the generic icon lookup must return the
            // default triangle, proving the render path handles unknown.
            XCTAssertEqual(ErrorCategoryDisplay.icon(for: data.category), "exclamationmark.triangle.fill")
        } else {
            XCTFail("expected .systemEvent(.providerError) content for unknown category, got \(msg.content)")
        }
    }

    func test_provider_error_missing_provider_drops_event() {
        // Sanity: other required fields still enforced.
        let payload: [String: AnyCodable] = [
            "error": AnyCodable("rate limited"),
            "category": AnyCodable("rate_limit"),
            "retryable": AnyCodable(true),
        ]
        let msg = ErrorEventProjection.transformProviderError(payload, timestamp: timestamp())
        XCTAssertNil(msg, "missing provider must drop the event")
    }

    func test_provider_error_missing_error_drops_event() {
        let payload: [String: AnyCodable] = [
            "provider": AnyCodable("anthropic"),
            "category": AnyCodable("rate_limit"),
            "retryable": AnyCodable(true),
        ]
        let msg = ErrorEventProjection.transformProviderError(payload, timestamp: timestamp())
        XCTAssertNil(msg, "missing error must drop the event")
    }

    // MARK: - No Retired Plain-Text Recovery

    /// Regression guard: this projection must never emit assistant-role plain
    /// text for a well-formed payload. The retired plain-text branch is gone
    /// — any category (including "unknown") routes through the pill.
    func test_no_plain_text_path_for_any_valid_category() {
        let categories = ["unknown", "rate_limit", "server", "authentication", "network", "random_new_category"]
        for category in categories {
            let payload: [String: AnyCodable] = [
                "provider": AnyCodable("anthropic"),
                "error": AnyCodable("e"),
                "category": AnyCodable(category),
                "retryable": AnyCodable(false),
            ]
            let msg = ErrorEventProjection.transformProviderError(payload, timestamp: timestamp())
            guard let msg else {
                XCTFail("category \(category): expected pill message, got nil")
                continue
            }
            XCTAssertEqual(msg.role, .system, "category \(category) must render as system pill")
            guard case .systemEvent(.providerError) = msg.content else {
                XCTFail("category \(category) must use .systemEvent(.providerError) content, got \(msg.content)")
                continue
            }
        }
    }

    func test_turn_failed_preserves_canonical_failure() {
        let payload: [String: AnyCodable] = [
            "turn": AnyCodable(4),
            "error": AnyCodable("top-level turn error"),
            "code": AnyCodable("TOP_LEVEL_CODE"),
            "category": AnyCodable("engine"),
            "retryable": AnyCodable(true),
            "recoverable": AnyCodable(true),
            "origin": AnyCodable("agent_runtime"),
            "details": AnyCodable([
                "failure": [
                    "code": "RUNTIME_CANCELLED",
                    "category": "cancelled",
                    "message": "canonical turn failure",
                    "retryable": false,
                    "recoverable": true,
                    "origin": "agent_runtime",
                    "traceId": "trace-1",
                ] as [String: Any],
            ] as [String: Any]),
        ]

        let msg = ErrorEventProjection.transformTurnFailed(payload, timestamp: timestamp())

        guard case .systemEvent(.turnFailed(let error, let code, let recoverable, let failure)) = msg?.content else {
            XCTFail("expected turn failed content")
            return
        }
        XCTAssertEqual(error, "canonical turn failure")
        XCTAssertEqual(code, "RUNTIME_CANCELLED")
        XCTAssertTrue(recoverable)
        XCTAssertEqual(failure?.category, "cancelled")
        XCTAssertEqual(failure?.traceId, "trace-1")
    }
}
