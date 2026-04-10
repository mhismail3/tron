import Testing
import Foundation
@testable import TronMobile

@Suite("CronScheduleDTO Tests")
struct CronScheduleDTOTests {

    // MARK: - Decode/Encode Round Trips

    @Test("cron schedule round trip")
    func cronRoundTrip() throws {
        let json = #"{"type":"cron","expression":"0 9 * * *","timezone":"America/Los_Angeles"}"#
        let schedule = try JSONDecoder().decode(CronScheduleDTO.self, from: json.data(using: .utf8)!)
        if case .cron(let expr, let tz) = schedule {
            #expect(expr == "0 9 * * *")
            #expect(tz == "America/Los_Angeles")
        } else {
            Issue.record("Expected .cron case")
        }

        let encoded = try JSONEncoder().encode(schedule)
        let reDecoded = try JSONDecoder().decode(CronScheduleDTO.self, from: encoded)
        #expect(schedule == reDecoded)
    }

    @Test("every schedule round trip")
    func everyRoundTrip() throws {
        let json = #"{"type":"every","intervalSecs":3600,"anchor":"2026-04-01T00:00:00Z"}"#
        let schedule = try JSONDecoder().decode(CronScheduleDTO.self, from: json.data(using: .utf8)!)
        if case .every(let secs, let anchor) = schedule {
            #expect(secs == 3600)
            #expect(anchor == "2026-04-01T00:00:00Z")
        } else {
            Issue.record("Expected .every case")
        }

        let encoded = try JSONEncoder().encode(schedule)
        let reDecoded = try JSONDecoder().decode(CronScheduleDTO.self, from: encoded)
        #expect(schedule == reDecoded)
    }

    @Test("every schedule without anchor")
    func everyWithoutAnchor() throws {
        let json = #"{"type":"every","intervalSecs":60}"#
        let schedule = try JSONDecoder().decode(CronScheduleDTO.self, from: json.data(using: .utf8)!)
        if case .every(let secs, let anchor) = schedule {
            #expect(secs == 60)
            #expect(anchor == nil)
        } else {
            Issue.record("Expected .every case")
        }
    }

    @Test("oneShot schedule round trip")
    func oneShotRoundTrip() throws {
        let json = #"{"type":"at","at":"2026-04-10T09:00:00Z"}"#
        let schedule = try JSONDecoder().decode(CronScheduleDTO.self, from: json.data(using: .utf8)!)
        if case .oneShot(let at) = schedule {
            #expect(at == "2026-04-10T09:00:00Z")
        } else {
            Issue.record("Expected .oneShot case")
        }
    }

    @Test("unknown type throws DecodingError")
    func unknownTypeThrows() throws {
        let json = #"{"type":"unknown","foo":"bar"}"#
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(CronScheduleDTO.self, from: json.data(using: .utf8)!)
        }
    }

    @Test("cron schedule missing timezone defaults to UTC")
    func cronDefaultTimezone() throws {
        let json = #"{"type":"cron","expression":"0 9 * * *"}"#
        let schedule = try JSONDecoder().decode(CronScheduleDTO.self, from: json.data(using: .utf8)!)
        if case .cron(_, let tz) = schedule {
            #expect(tz == "UTC")
        } else {
            Issue.record("Expected .cron case")
        }
    }

    // MARK: - Summary: Every Intervals

    @Test("every 1 day summary")
    func everyDay() { #expect(CronScheduleDTO.every(intervalSecs: 86400, anchor: nil).summary == "Every 1d") }

    @Test("every 2 days summary")
    func every2Days() { #expect(CronScheduleDTO.every(intervalSecs: 172800, anchor: nil).summary == "Every 2d") }

    @Test("every 1 hour summary")
    func everyHour() { #expect(CronScheduleDTO.every(intervalSecs: 3600, anchor: nil).summary == "Every 1h") }

    @Test("every 1 minute summary")
    func everyMinute() { #expect(CronScheduleDTO.every(intervalSecs: 60, anchor: nil).summary == "Every 1m") }

    @Test("every 30 seconds summary")
    func every30Secs() { #expect(CronScheduleDTO.every(intervalSecs: 30, anchor: nil).summary == "Every 30s") }

    @Test("every 0 seconds summary — documents edge case")
    func everyZero() { #expect(CronScheduleDTO.every(intervalSecs: 0, anchor: nil).summary == "Every 0s") }

    @Test("every negative seconds summary — documents edge case")
    func everyNegative() { #expect(CronScheduleDTO.every(intervalSecs: -1, anchor: nil).summary == "Every -1s") }

    // MARK: - Summary: Cron Expressions

    @Test("daily at 9 AM")
    func dailyAt9() {
        let s = CronScheduleDTO.cron(expression: "0 9 * * *", timezone: "America/Los_Angeles").summary
        #expect(s.contains("Daily"))
        #expect(s.contains("9"))
        #expect(s.contains("AM"))
        #expect(s.contains("PT"))
    }

    @Test("weekdays pattern")
    func weekdays() {
        let s = CronScheduleDTO.cron(expression: "0 9 * * 1-5", timezone: "America/New_York").summary
        #expect(s.contains("Weekdays"))
        #expect(s.contains("ET"))
    }

    @Test("weekdays MON-FRI pattern")
    func weekdaysNamed() {
        let s = CronScheduleDTO.cron(expression: "0 9 * * MON-FRI", timezone: "UTC").summary
        #expect(s.contains("Weekdays"))
    }

    @Test("weekends pattern")
    func weekends() {
        let s = CronScheduleDTO.cron(expression: "0 9 * * 0,6", timezone: "UTC").summary
        #expect(s.contains("Weekends"))
    }

    @Test("single day — Monday")
    func singleDayMonday() {
        let s = CronScheduleDTO.cron(expression: "0 9 * * 1", timezone: "UTC").summary
        #expect(s.contains("Mon"))
    }

    @Test("monthly on 1st")
    func monthlyFirst() {
        let s = CronScheduleDTO.cron(expression: "0 9 1 * *", timezone: "UTC").summary
        #expect(s.contains("1st"))
        #expect(s.contains("month"))
    }

    @Test("monthly on 15th")
    func monthly15th() {
        let s = CronScheduleDTO.cron(expression: "0 9 15 * *", timezone: "UTC").summary
        #expect(s.contains("15th"))
    }

    @Test("oneShot summary includes timestamp")
    func oneShotSummary() {
        let s = CronScheduleDTO.oneShot(at: "2026-04-10T09:00:00Z").summary
        #expect(s.contains("2026-04-10"))
    }

    @Test("6-field cron expression falls through to raw display")
    func sixFieldCron() {
        let s = CronScheduleDTO.cron(expression: "0 0 9 * * *", timezone: "UTC").summary
        // 6 fields doesn't match 5-field guard, falls through to raw expression
        #expect(s.contains("0 0 9 * * *"))
    }

    @Test("noon formats as 12 PM")
    func noonFormat() {
        let s = CronScheduleDTO.cron(expression: "0 12 * * *", timezone: "UTC").summary
        #expect(s.contains("12 PM"))
    }

    @Test("midnight formats as 12 AM")
    func midnightFormat() {
        let s = CronScheduleDTO.cron(expression: "0 0 * * *", timezone: "UTC").summary
        #expect(s.contains("12 AM"))
    }

    @Test("timezone abbreviation mapping")
    func timezoneAbbreviation() {
        let s = CronScheduleDTO.cron(expression: "0 9 * * *", timezone: "Asia/Tokyo").summary
        #expect(s.contains("JST"))
    }

    @Test("unknown timezone uses last path component")
    func unknownTimezone() {
        let s = CronScheduleDTO.cron(expression: "0 9 * * *", timezone: "Custom/MyCity").summary
        #expect(s.contains("MyCity"))
    }

    // MARK: - Ordinal formatting

    @Test("ordinal numbers")
    func ordinals() {
        // Tested via monthly cron patterns
        let s1 = CronScheduleDTO.cron(expression: "0 9 1 * *", timezone: "UTC").summary
        #expect(s1.contains("1st"))
        let s2 = CronScheduleDTO.cron(expression: "0 9 2 * *", timezone: "UTC").summary
        #expect(s2.contains("2nd"))
        let s3 = CronScheduleDTO.cron(expression: "0 9 3 * *", timezone: "UTC").summary
        #expect(s3.contains("3rd"))
        let s11 = CronScheduleDTO.cron(expression: "0 9 11 * *", timezone: "UTC").summary
        #expect(s11.contains("11th"))
    }
}

@Suite("CronPayloadDTO Tests")
struct CronPayloadDTOTests {

    @Test("agentTurn round trip")
    func agentTurn() throws {
        let json = #"{"type":"agentTurn","prompt":"Hello","model":"claude-sonnet-4-6","workspaceId":"ws-1","systemPrompt":"Be helpful"}"#
        let payload = try JSONDecoder().decode(CronPayloadDTO.self, from: json.data(using: .utf8)!)
        if case .agentTurn(let prompt, let model, let wsId, let sysPrompt) = payload {
            #expect(prompt == "Hello")
            #expect(model == "claude-sonnet-4-6")
            #expect(wsId == "ws-1")
            #expect(sysPrompt == "Be helpful")
        } else {
            Issue.record("Expected .agentTurn")
        }
        #expect(payload.typeLabel == "Agent Turn")
        #expect(payload.icon == "cpu")
    }

    @Test("shellCommand round trip")
    func shellCommand() throws {
        let json = #"{"type":"shellCommand","command":"echo hello","workingDirectory":"/tmp","timeoutSecs":30}"#
        let payload = try JSONDecoder().decode(CronPayloadDTO.self, from: json.data(using: .utf8)!)
        if case .shellCommand(let cmd, let dir, let timeout) = payload {
            #expect(cmd == "echo hello")
            #expect(dir == "/tmp")
            #expect(timeout == 30)
        } else {
            Issue.record("Expected .shellCommand")
        }
        #expect(payload.typeLabel == "Shell Command")
    }

    @Test("webhook round trip")
    func webhook() throws {
        let json = #"{"type":"webhook","url":"https://example.com","method":"POST","headers":{"X-Key":"val"},"body":"data","timeoutSecs":10}"#
        let payload = try JSONDecoder().decode(CronPayloadDTO.self, from: json.data(using: .utf8)!)
        if case .webhook(let url, let method, let headers, let body, let timeout) = payload {
            #expect(url == "https://example.com")
            #expect(method == "POST")
            #expect(headers == ["X-Key": "val"])
            #expect(body == "data")
            #expect(timeout == 10)
        } else {
            Issue.record("Expected .webhook")
        }
    }

    @Test("systemEvent round trip")
    func systemEvent() throws {
        let json = #"{"type":"systemEvent","sessionId":"sess-1","message":"test"}"#
        let payload = try JSONDecoder().decode(CronPayloadDTO.self, from: json.data(using: .utf8)!)
        if case .systemEvent(let sid, let msg) = payload {
            #expect(sid == "sess-1")
            #expect(msg == "test")
        } else {
            Issue.record("Expected .systemEvent")
        }
    }

    @Test("unknown payload type throws")
    func unknownType() {
        let json = #"{"type":"magic","foo":"bar"}"#
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(CronPayloadDTO.self, from: json.data(using: .utf8)!)
        }
    }
}

@Suite("CronDeliveryDTO Tests")
struct CronDeliveryDTOTests {

    @Test("silent round trip")
    func silent() throws {
        let json = #"{"type":"silent"}"#
        let delivery = try JSONDecoder().decode(CronDeliveryDTO.self, from: json.data(using: .utf8)!)
        if case .silent = delivery {} else { Issue.record("Expected .silent") }
        let reEncoded = try JSONEncoder().encode(delivery)
        let reDecoded = try JSONDecoder().decode(CronDeliveryDTO.self, from: reEncoded)
        #expect(delivery == reDecoded)
    }

    @Test("webSocket round trip")
    func webSocket() throws {
        let json = #"{"type":"websocket"}"#
        let delivery = try JSONDecoder().decode(CronDeliveryDTO.self, from: json.data(using: .utf8)!)
        if case .webSocket = delivery {} else { Issue.record("Expected .webSocket") }
    }

    @Test("apns with title")
    func apns() throws {
        let json = #"{"type":"apns","title":"Job done"}"#
        let delivery = try JSONDecoder().decode(CronDeliveryDTO.self, from: json.data(using: .utf8)!)
        if case .apns(let title) = delivery {
            #expect(title == "Job done")
        } else {
            Issue.record("Expected .apns")
        }
    }

    @Test("apns without title")
    func apnsNoTitle() throws {
        let json = #"{"type":"apns"}"#
        let delivery = try JSONDecoder().decode(CronDeliveryDTO.self, from: json.data(using: .utf8)!)
        if case .apns(let title) = delivery {
            #expect(title == nil)
        } else {
            Issue.record("Expected .apns")
        }
    }

    @Test("webhook delivery")
    func webhook() throws {
        let json = #"{"type":"webhook","url":"https://hooks.example.com","headers":{"Auth":"Bearer tok"}}"#
        let delivery = try JSONDecoder().decode(CronDeliveryDTO.self, from: json.data(using: .utf8)!)
        if case .webhook(let url, let headers) = delivery {
            #expect(url == "https://hooks.example.com")
            #expect(headers == ["Auth": "Bearer tok"])
        } else {
            Issue.record("Expected .webhook")
        }
    }

    @Test("unknown delivery type throws")
    func unknownType() {
        let json = #"{"type":"sms"}"#
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(CronDeliveryDTO.self, from: json.data(using: .utf8)!)
        }
    }
}
