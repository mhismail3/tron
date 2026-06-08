import Testing
import Foundation
@testable import TronMobile

// MARK: - AnyCodable Dictionary Extension Tests
//
// Covers the `Dictionary where Key == String, Value == AnyCodable` accessors
// in AnyCodable.swift. The original implementation returned nil for numbers
// that decoded as Double when Int was requested (and vice-versa), which
// caused ~16 call sites across the capability-view layer to write out an explicit
// `as? Int / as? Double` ladder. These tests lock the widened numeric
// behavior and the NaN/Inf/overflow guards that make widening safe.

@Suite("AnyCodable Dictionary Extensions")
struct AnyCodableExtensionsTests {

    // MARK: - Helpers

    private func make(_ pairs: (String, Any)...) -> [String: AnyCodable] {
        var out: [String: AnyCodable] = [:]
        for (k, v) in pairs { out[k] = AnyCodable(v) }
        return out
    }

    // MARK: - string()

    @Test("string returns value when present and String-typed")
    func stringPresent() {
        let d = make(("k", "hello"))
        #expect(d.string("k") == "hello")
    }

    @Test("string returns nil for missing key")
    func stringMissing() {
        let d = make(("k", "hello"))
        #expect(d.string("other") == nil)
    }

    @Test("string returns nil for wrong type")
    func stringWrongType() {
        let d = make(("k", 7))
        #expect(d.string("k") == nil)
    }

    @Test("string returns nil for NSNull")
    func stringNull() {
        let d = make(("k", NSNull()))
        #expect(d.string("k") == nil)
    }

    @Test("string returns empty string when value is empty")
    func stringEmpty() {
        let d = make(("k", ""))
        #expect(d.string("k") == "")
    }

    @Test("string handles unicode")
    func stringUnicode() {
        let d = make(("k", "日本語🚀"))
        #expect(d.string("k") == "日本語🚀")
    }

    // MARK: - bool()

    @Test("bool returns value when present and Bool-typed")
    func boolPresent() {
        let d = make(("t", true), ("f", false))
        #expect(d.bool("t") == true)
        #expect(d.bool("f") == false)
    }

    @Test("bool returns nil for missing key")
    func boolMissing() {
        let d = make(("t", true))
        #expect(d.bool("other") == nil)
    }

    @Test("bool returns nil for string 'true'")
    func boolNotCoercedFromString() {
        let d = make(("k", "true"))
        #expect(d.bool("k") == nil)
    }

    // MARK: - int() — widened

    @Test("int returns value when present and Int-typed")
    func intFromInt() {
        let d = make(("k", 42))
        #expect(d.int("k") == 42)
    }

    @Test("int widens from Double whole value")
    func intFromDoubleWhole() {
        let d = make(("k", 42.0))
        #expect(d.int("k") == 42)
    }

    @Test("int truncates Double toward zero for positive")
    func intFromDoubleTruncatePositive() {
        let d = make(("k", 1.9))
        #expect(d.int("k") == 1)
    }

    @Test("int truncates Double toward zero for negative")
    func intFromDoubleTruncateNegative() {
        let d = make(("k", -1.9))
        #expect(d.int("k") == -1)
    }

    @Test("int handles Int.max")
    func intMax() {
        let d = make(("k", Int.max))
        #expect(d.int("k") == Int.max)
    }

    @Test("int handles Int.min")
    func intMin() {
        let d = make(("k", Int.min))
        #expect(d.int("k") == Int.min)
    }

    @Test("int handles zero and negative zero identically")
    func intZero() {
        let d = make(("a", 0), ("b", -0.0))
        #expect(d.int("a") == 0)
        #expect(d.int("b") == 0)
    }

    @Test("int returns nil for NaN")
    func intNaN() {
        let d = make(("k", Double.nan))
        #expect(d.int("k") == nil)
    }

    @Test("int returns nil for +Infinity")
    func intPositiveInfinity() {
        let d = make(("k", Double.infinity))
        #expect(d.int("k") == nil)
    }

    @Test("int returns nil for -Infinity")
    func intNegativeInfinity() {
        let d = make(("k", -Double.infinity))
        #expect(d.int("k") == nil)
    }

    @Test("int returns nil for Double that overflows Int")
    func intOverflowPositive() {
        let d = make(("k", 1e30))
        #expect(d.int("k") == nil)
    }

    @Test("int returns nil for Double that underflows Int")
    func intOverflowNegative() {
        let d = make(("k", -1e30))
        #expect(d.int("k") == nil)
    }

    @Test("int returns nil for missing key")
    func intMissing() {
        let d = make(("k", 7))
        #expect(d.int("other") == nil)
    }

    @Test("int returns nil for String value (no parsing)")
    func intNotCoercedFromString() {
        let d = make(("k", "7"))
        #expect(d.int("k") == nil)
    }

    @Test("int returns nil for NSNull")
    func intNull() {
        let d = make(("k", NSNull()))
        #expect(d.int("k") == nil)
    }

    // MARK: - double() — widened

    @Test("double returns value when present and Double-typed")
    func doubleFromDouble() {
        let d = make(("k", 3.14))
        #expect(d.double("k") == 3.14)
    }

    @Test("double widens from Int")
    func doubleFromInt() {
        let d = make(("k", 42))
        #expect(d.double("k") == 42.0)
    }

    @Test("double handles zero")
    func doubleZero() {
        let d = make(("a", 0.0), ("b", 0))
        #expect(d.double("a") == 0.0)
        #expect(d.double("b") == 0.0)
    }

    @Test("double returns nil for String value")
    func doubleNotCoercedFromString() {
        let d = make(("k", "3.14"))
        #expect(d.double("k") == nil)
    }

    @Test("double returns nil for missing key")
    func doubleMissing() {
        let d = make(("k", 1.0))
        #expect(d.double("other") == nil)
    }

    @Test("double preserves NaN when requested as Double")
    func doubleNaN() {
        // NaN is a valid Double; `double()` should return it. Callers that
        // care can check `.isNaN`. Only the widened `int()` rejects it.
        let d = make(("k", Double.nan))
        #expect(d.double("k")?.isNaN == true)
    }

    @Test("double preserves Infinity when requested as Double")
    func doubleInfinity() {
        let d = make(("k", Double.infinity))
        #expect(d.double("k")?.isInfinite == true)
    }

    // MARK: - array() / stringArray()

    @Test("array returns contents when present")
    func arrayPresent() {
        let d = make(("k", ["a", "b"]))
        #expect(d.array("k")?.count == 2)
    }

    @Test("array returns empty array for empty input")
    func arrayEmpty() {
        let d = make(("k", [] as [Any]))
        #expect(d.array("k")?.isEmpty == true)
    }

    @Test("array returns nil for missing key")
    func arrayMissing() {
        #expect(make().array("other") == nil)
    }

    @Test("stringArray filters non-strings via compactMap")
    func stringArrayFiltersMixed() {
        let d = make(("k", ["a", 1, "b", NSNull(), "c"]))
        #expect(d.stringArray("k") == ["a", "b", "c"])
    }

    @Test("stringArray returns empty for all non-strings")
    func stringArrayAllFiltered() {
        let d = make(("k", [1, 2, 3]))
        #expect(d.stringArray("k") == [])
    }

    @Test("stringArray returns nil for missing key")
    func stringArrayMissing() {
        #expect(make().stringArray("other") == nil)
    }

    // MARK: - dict()

    @Test("dict returns nested dictionary")
    func dictPresent() {
        let d = make(("k", ["a": 1]))
        #expect(d.dict("k")?["a"] as? Int == 1)
    }

    @Test("dict returns nil for missing key")
    func dictMissing() {
        #expect(make().dict("other") == nil)
    }

    @Test("dict returns nil when value is not a dictionary")
    func dictWrongType() {
        let d = make(("k", "not a dict"))
        #expect(d.dict("k") == nil)
    }

    // MARK: - dictArray() (new accessor for structured jobs/matches)

    @Test("dictArray returns array of dictionaries")
    func dictArrayPresent() {
        let d = make(("k", [["id": "a"], ["id": "b"]]))
        let result = d.dictArray("k")
        #expect(result?.count == 2)
        #expect(result?[0]["id"] as? String == "a")
        #expect(result?[1]["id"] as? String == "b")
    }

    @Test("dictArray returns empty array for empty input")
    func dictArrayEmpty() {
        let d = make(("k", [] as [[String: Any]]))
        #expect(d.dictArray("k") != nil)
        #expect(d.dictArray("k")?.isEmpty == true)
    }

    @Test("dictArray returns nil for missing key")
    func dictArrayMissing() {
        #expect(make().dictArray("other") == nil)
    }

    @Test("dictArray returns nil for non-array value")
    func dictArrayWrongType() {
        let d = make(("k", "string"))
        #expect(d.dictArray("k") == nil)
    }

    // MARK: - JSON round-trip (real-world shape)

    @Test("accessors work after JSON round-trip with Double-encoded integers")
    func roundTripDoubleAsInt() throws {
        // Server may emit integer values through a serde path that decodes
        // as Double. AnyCodable's decoder prefers Int when possible, but
        // a JSON number like "5.0" will decode as Double. Lock that the
        // widened int() accessor still returns 5.
        let jsonString = #"{"replacements": 5.0, "matchCount": 12, "httpStatus": 404.0}"#
        let data = try #require(jsonString.data(using: .utf8))
        let decoded = try JSONDecoder().decode([String: AnyCodable].self, from: data)
        #expect(decoded.int("replacements") == 5)
        #expect(decoded.int("matchCount") == 12)
        #expect(decoded.int("httpStatus") == 404)
    }

    @Test("accessors work on NaN-bearing round trip")
    func roundTripNaNSafe() {
        // JSON doesn't carry NaN, but an in-memory details map constructed
        // server-side (e.g., a metric divide-by-zero) can. Lock that int()
        // does not trap.
        let d = make(("bad", Double.nan), ("good", 1.0))
        #expect(d.int("bad") == nil)
        #expect(d.int("good") == 1)
    }
}
