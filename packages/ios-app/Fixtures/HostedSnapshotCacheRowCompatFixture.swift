#if HOSTED_TEST
import CryptoKit
import Foundation
import TronMobileCore

enum RawJSON {
    static func members(_ text: Substring) -> [(key: String, value: Substring)]? {
        var index = text.startIndex
        skip(text, &index)
        guard index < text.endIndex, text[index] == "{" else { return nil }
        index = text.index(after: index)
        var result: [(String, Substring)] = []
        while true {
            skip(text, &index)
            if index < text.endIndex, text[index] == "}" { return result }
            let keyStart = index
            guard value(text, &index) else { return nil }
            let key = String(text[keyStart..<index])
            skip(text, &index)
            guard index < text.endIndex, text[index] == ":" else { return nil }
            index = text.index(after: index)
            skip(text, &index)
            let valueStart = index
            guard value(text, &index) else { return nil }
            result.append((key, text[valueStart..<index]))
            skip(text, &index)
            guard index < text.endIndex else { return nil }
            if text[index] == "," { index = text.index(after: index); continue }
            if text[index] == "}" { return result }
            return nil
        }
    }

    static func elements(_ text: Substring) -> [Substring]? {
        var index = text.startIndex
        guard index < text.endIndex, text[index] == "[" else { return nil }
        index = text.index(after: index)
        var result: [Substring] = []
        while true {
            skip(text, &index)
            if index < text.endIndex, text[index] == "]" { return result }
            let start = index
            guard value(text, &index) else { return nil }
            result.append(text[start..<index])
            skip(text, &index)
            guard index < text.endIndex else { return nil }
            if text[index] == "," { index = text.index(after: index); continue }
            if text[index] == "]" { return result }
            return nil
        }
    }

    static func normalized(_ text: Substring) -> String {
        if let members = members(text) {
            return "{" + members.map { "\($0.key):\(normalized($0.value))" }.sorted().joined(separator: ",") + "}"
        }
        return String(text)
    }

    static func shuffled(_ text: Substring, seed: inout UInt64) -> String {
        guard var members = members(text) else { return String(text) }
        for index in stride(from: members.count - 1, to: 0, by: -1) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            members.swapAt(index, Int(seed >> 33) % (index + 1))
        }
        return "{" + members.map { "\($0.key):\(shuffled($0.value, seed: &seed))" }.joined(separator: ",") + "}"
    }

    private static func skip(_ text: Substring, _ index: inout Substring.Index) {
        while index < text.endIndex, text[index] == " " || text[index] == "\n" || text[index] == "\t" || text[index] == "\r" {
            index = text.index(after: index)
        }
    }

    private static func value(_ text: Substring, _ index: inout Substring.Index) -> Bool {
        guard index < text.endIndex else { return false }
        let first = text[index]
        if first == "\"" {
            index = text.index(after: index)
            while index < text.endIndex {
                let character = text[index]
                index = text.index(after: index)
                if character == "\\" { guard index < text.endIndex else { return false }; index = text.index(after: index) }
                else if character == "\"" { return true }
            }
            return false
        }
        if first == "{" || first == "[" {
            var depth = 0
            while index < text.endIndex {
                let character = text[index]
                if character == "\"" { guard value(text, &index) else { return false }; continue }
                if character == "{" || character == "[" { depth += 1 }
                if character == "}" || character == "]" { depth -= 1 }
                index = text.index(after: index)
                if depth == 0 { return true }
            }
            return false
        }
        while index < text.endIndex, !",}] \n\t\r".contains(text[index]) { index = text.index(after: index) }
        return true
    }
}

enum SnapshotCacheRowCompat {
    static let capturedRows: [String] = [
        "eyJraW5kIjoidXNlciIsImZpcnN0TWVzc2FnZSI6IkZpcnN0IG1lc3NhZ2UiLCJjcmVhdGVkQXQiOiIyMDI2LTAxLTAxVDAwOjAwOjAwWiIsImlkIjoiYmFzZSIsInN1bW1hcnlSZXZpc2lvbiI6MSwiY3dkIjoiL2ZpeHR1cmUvY2FjaGUiLCJhdHRlbnRpb25SZXZpc2lvbiI6MCwiaXNVbnJlYWQiOmZhbHNlLCJ3YWl0aW5nRm9yVXNlciI6ZmFsc2UsIm5hbWUiOiJSb3ciLCJjb21wbGV0aW9uUmV2aXNpb24iOjAsIm1lc3NhZ2VDb3VudCI6MywicGhhc2UiOiJpZGxlIiwidXBkYXRlZEF0IjoiMjAyNi0wMS0wMVQwMDowMDowMS4yNTBaIiwiaGFzQWN0aXZlU3ViYWdlbnRzIjpmYWxzZX0=",
        "eyJraW5kIjoidXNlciIsImZpcnN0TWVzc2FnZSI6IkZpcnN0IG1lc3NhZ2UiLCJjcmVhdGVkQXQiOiIyMDI2LTAxLTAxVDAwOjAwOjAwWiIsImlkIjoibmFtZS0wIiwic3VtbWFyeVJldmlzaW9uIjoxLCJjd2QiOiIvZml4dHVyZS9jYWNoZSIsImF0dGVudGlvblJldmlzaW9uIjowLCJpc1VucmVhZCI6ZmFsc2UsIndhaXRpbmdGb3JVc2VyIjpmYWxzZSwibmFtZSI6Ilx1MDAwMFx1MDAwMVx1MDAwMlx1MDAwM1x1MDAwNFx1MDAwNVx1MDAwNlx1MDAwN1xiXHRcblx1MDAwYlxmXHJcdTAwMGVcdTAwMGZcdTAwMTBcdTAwMTFcdTAwMTJcdTAwMTNcdTAwMTRcdTAwMTVcdTAwMTZcdTAwMTdcdTAwMThcdTAwMTlcdTAwMWFcdTAwMWJcdTAwMWNcdTAwMWRcdTAwMWVcdTAwMWYgIVwiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj9AQUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVpbXFxdXl9gYWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXp7fH1+fyIsImNvbXBsZXRpb25SZXZpc2lvbiI6MCwibWVzc2FnZUNvdW50IjozLCJwaGFzZSI6ImlkbGUiLCJ1cGRhdGVkQXQiOiIyMDI2LTAxLTAxVDAwOjAwOjAxLjI1MFoiLCJoYXNBY3RpdmVTdWJhZ2VudHMiOmZhbHNlfQ==",
        "eyJraW5kIjoidXNlciIsImZpcnN0TWVzc2FnZSI6IkZpcnN0IG1lc3NhZ2UiLCJjcmVhdGVkQXQiOiIyMDI2LTAxLTAxVDAwOjAwOjAwWiIsImlkIjoibmFtZS0xIiwic3VtbWFyeVJldmlzaW9uIjoxLCJjd2QiOiIvZml4dHVyZS9jYWNoZSIsImF0dGVudGlvblJldmlzaW9uIjowLCJpc1VucmVhZCI6ZmFsc2UsIndhaXRpbmdGb3JVc2VyIjpmYWxzZSwibmFtZSI6IuKAqOKAqe+/vu6AgPSPv7/wn5iAIMOpzIMg5LitIiwiY29tcGxldGlvblJldmlzaW9uIjowLCJtZXNzYWdlQ291bnQiOjMsInBoYXNlIjoiaWRsZSIsInVwZGF0ZWRBdCI6IjIwMjYtMDEtMDFUMDA6MDA6MDEuMjUwWiIsImhhc0FjdGl2ZVN1YmFnZW50cyI6ZmFsc2V9",
        "eyJraW5kIjoidXNlciIsImZpcnN0TWVzc2FnZSI6IkZpcnN0IG1lc3NhZ2UiLCJjcmVhdGVkQXQiOiIyMDI2LTAxLTAxVDAwOjAwOjAwWiIsImlkIjoibmFtZS0yIiwic3VtbWFyeVJldmlzaW9uIjoxLCJjd2QiOiIvZml4dHVyZS9jYWNoZSIsImF0dGVudGlvblJldmlzaW9uIjowLCJpc1VucmVhZCI6ZmFsc2UsIndhaXRpbmdGb3JVc2VyIjpmYWxzZSwibmFtZSI6IlwiXFwvIiwiY29tcGxldGlvblJldmlzaW9uIjowLCJtZXNzYWdlQ291bnQiOjMsInBoYXNlIjoiaWRsZSIsInVwZGF0ZWRBdCI6IjIwMjYtMDEtMDFUMDA6MDA6MDEuMjUwWiIsImhhc0FjdGl2ZVN1YmFnZW50cyI6ZmFsc2V9",
        "eyJraW5kIjoidXNlciIsImZpcnN0TWVzc2FnZSI6IkZpcnN0IG1lc3NhZ2UiLCJjcmVhdGVkQXQiOiIyMDI2LTAxLTAxVDAwOjAwOjAwWiIsImlkIjoibmFtZS0zIiwic3VtbWFyeVJldmlzaW9uIjoxLCJjd2QiOiIvZml4dHVyZS9jYWNoZSIsImF0dGVudGlvblJldmlzaW9uIjowLCJpc1VucmVhZCI6ZmFsc2UsIndhaXRpbmdGb3JVc2VyIjpmYWxzZSwibmFtZSI6IiIsImNvbXBsZXRpb25SZXZpc2lvbiI6MCwibWVzc2FnZUNvdW50IjozLCJwaGFzZSI6ImlkbGUiLCJ1cGRhdGVkQXQiOiIyMDI2LTAxLTAxVDAwOjAwOjAxLjI1MFoiLCJoYXNBY3RpdmVTdWJhZ2VudHMiOmZhbHNlfQ==",
        "eyJraW5kIjoidXNlciIsImZpcnN0TWVzc2FnZSI6IkZpcnN0IG1lc3NhZ2UiLCJjcmVhdGVkQXQiOiIyMDI2LTAxLTAxVDAwOjAwOjAwWiIsImlkIjoibmFtZS00Iiwic3VtbWFyeVJldmlzaW9uIjoxLCJjd2QiOiIvZml4dHVyZS9jYWNoZSIsImF0dGVudGlvblJldmlzaW9uIjowLCJpc1VucmVhZCI6ZmFsc2UsIndhaXRpbmdGb3JVc2VyIjpmYWxzZSwibmFtZSI6ImxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgIiwiY29tcGxldGlvblJldmlzaW9uIjowLCJtZXNzYWdlQ291bnQiOjMsInBoYXNlIjoiaWRsZSIsInVwZGF0ZWRBdCI6IjIwMjYtMDEtMDFUMDA6MDA6MDEuMjUwWiIsImhhc0FjdGl2ZVN1YmFnZW50cyI6ZmFsc2V9",
        "eyJraW5kIjoidXNlciIsImZpcnN0TWVzc2FnZSI6Ilx1MDAwMFx1MDAwMVx1MDAwMlx1MDAwM1x1MDAwNFx1MDAwNVx1MDAwNlx1MDAwN1xiXHRcblx1MDAwYlxmXHJcdTAwMGVcdTAwMGZcdTAwMTBcdTAwMTFcdTAwMTJcdTAwMTNcdTAwMTRcdTAwMTVcdTAwMTZcdTAwMTdcdTAwMThcdTAwMTlcdTAwMWFcdTAwMWJcdTAwMWNcdTAwMWRcdTAwMWVcdTAwMWYgIVwiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj9AQUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVpbXFxdXl9gYWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXp7fH1+fyIsImNyZWF0ZWRBdCI6IjIwMjYtMDEtMDFUMDA6MDA6MDBaIiwiaWQiOiJmaXJzdC0wIiwic3VtbWFyeVJldmlzaW9uIjoxLCJjd2QiOiIvZml4dHVyZS9jYWNoZSIsImF0dGVudGlvblJldmlzaW9uIjowLCJpc1VucmVhZCI6ZmFsc2UsIndhaXRpbmdGb3JVc2VyIjpmYWxzZSwibmFtZSI6IlJvdyIsImNvbXBsZXRpb25SZXZpc2lvbiI6MCwibWVzc2FnZUNvdW50IjozLCJwaGFzZSI6ImlkbGUiLCJ1cGRhdGVkQXQiOiIyMDI2LTAxLTAxVDAwOjAwOjAxLjI1MFoiLCJoYXNBY3RpdmVTdWJhZ2VudHMiOmZhbHNlfQ==",
        "eyJraW5kIjoidXNlciIsImZpcnN0TWVzc2FnZSI6IuKAqOKAqe+/vu6AgPSPv7/wn5iAIMOpzIMg5LitIiwiY3JlYXRlZEF0IjoiMjAyNi0wMS0wMVQwMDowMDowMFoiLCJpZCI6ImZpcnN0LTEiLCJzdW1tYXJ5UmV2aXNpb24iOjEsImN3ZCI6Ii9maXh0dXJlL2NhY2hlIiwiYXR0ZW50aW9uUmV2aXNpb24iOjAsImlzVW5yZWFkIjpmYWxzZSwid2FpdGluZ0ZvclVzZXIiOmZhbHNlLCJuYW1lIjoiUm93IiwiY29tcGxldGlvblJldmlzaW9uIjowLCJtZXNzYWdlQ291bnQiOjMsInBoYXNlIjoiaWRsZSIsInVwZGF0ZWRBdCI6IjIwMjYtMDEtMDFUMDA6MDA6MDEuMjUwWiIsImhhc0FjdGl2ZVN1YmFnZW50cyI6ZmFsc2V9",
        "eyJraW5kIjoidXNlciIsImZpcnN0TWVzc2FnZSI6IlwiXFwvIiwiY3JlYXRlZEF0IjoiMjAyNi0wMS0wMVQwMDowMDowMFoiLCJpZCI6ImZpcnN0LTIiLCJzdW1tYXJ5UmV2aXNpb24iOjEsImN3ZCI6Ii9maXh0dXJlL2NhY2hlIiwiYXR0ZW50aW9uUmV2aXNpb24iOjAsImlzVW5yZWFkIjpmYWxzZSwid2FpdGluZ0ZvclVzZXIiOmZhbHNlLCJuYW1lIjoiUm93IiwiY29tcGxldGlvblJldmlzaW9uIjowLCJtZXNzYWdlQ291bnQiOjMsInBoYXNlIjoiaWRsZSIsInVwZGF0ZWRBdCI6IjIwMjYtMDEtMDFUMDA6MDA6MDEuMjUwWiIsImhhc0FjdGl2ZVN1YmFnZW50cyI6ZmFsc2V9",
        "eyJraW5kIjoidXNlciIsImZpcnN0TWVzc2FnZSI6IiIsImNyZWF0ZWRBdCI6IjIwMjYtMDEtMDFUMDA6MDA6MDBaIiwiaWQiOiJmaXJzdC0zIiwic3VtbWFyeVJldmlzaW9uIjoxLCJjd2QiOiIvZml4dHVyZS9jYWNoZSIsImF0dGVudGlvblJldmlzaW9uIjowLCJpc1VucmVhZCI6ZmFsc2UsIndhaXRpbmdGb3JVc2VyIjpmYWxzZSwibmFtZSI6IlJvdyIsImNvbXBsZXRpb25SZXZpc2lvbiI6MCwibWVzc2FnZUNvdW50IjozLCJwaGFzZSI6ImlkbGUiLCJ1cGRhdGVkQXQiOiIyMDI2LTAxLTAxVDAwOjAwOjAxLjI1MFoiLCJoYXNBY3RpdmVTdWJhZ2VudHMiOmZhbHNlfQ==",
        "eyJraW5kIjoidXNlciIsImZpcnN0TWVzc2FnZSI6ImxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgIiwiY3JlYXRlZEF0IjoiMjAyNi0wMS0wMVQwMDowMDowMFoiLCJpZCI6ImZpcnN0LTQiLCJzdW1tYXJ5UmV2aXNpb24iOjEsImN3ZCI6Ii9maXh0dXJlL2NhY2hlIiwiYXR0ZW50aW9uUmV2aXNpb24iOjAsImlzVW5yZWFkIjpmYWxzZSwid2FpdGluZ0ZvclVzZXIiOmZhbHNlLCJuYW1lIjoiUm93IiwiY29tcGxldGlvblJldmlzaW9uIjowLCJtZXNzYWdlQ291bnQiOjMsInBoYXNlIjoiaWRsZSIsImhhc0FjdGl2ZVN1YmFnZW50cyI6ZmFsc2UsInVwZGF0ZWRBdCI6IjIwMjYtMDEtMDFUMDA6MDA6MDEuMjUwWiJ9",
        "eyJraW5kIjoidXNlciIsImZpcnN0TWVzc2FnZSI6IkZpcnN0IG1lc3NhZ2UiLCJjcmVhdGVkQXQiOiIyMDI2LTAxLTAxVDAwOjAwOjAwWiIsImlkIjoiY3dkLTAiLCJzdW1tYXJ5UmV2aXNpb24iOjEsImN3ZCI6Ilx1MDAwMFx1MDAwMVx1MDAwMlx1MDAwM1x1MDAwNFx1MDAwNVx1MDAwNlx1MDAwN1xiXHRcblx1MDAwYlxmXHJcdTAwMGVcdTAwMGZcdTAwMTBcdTAwMTFcdTAwMTJcdTAwMTNcdTAwMTRcdTAwMTVcdTAwMTZcdTAwMTdcdTAwMThcdTAwMTlcdTAwMWFcdTAwMWJcdTAwMWNcdTAwMWRcdTAwMWVcdTAwMWYgIVwiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj9AQUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVpbXFxdXl9gYWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXp7fH1+fyIsImF0dGVudGlvblJldmlzaW9uIjowLCJpc1VucmVhZCI6ZmFsc2UsIndhaXRpbmdGb3JVc2VyIjpmYWxzZSwibmFtZSI6IlJvdyIsImNvbXBsZXRpb25SZXZpc2lvbiI6MCwibWVzc2FnZUNvdW50IjozLCJwaGFzZSI6ImlkbGUiLCJoYXNBY3RpdmVTdWJhZ2VudHMiOmZhbHNlLCJ1cGRhdGVkQXQiOiIyMDI2LTAxLTAxVDAwOjAwOjAxLjI1MFoifQ==",
        "eyJraW5kIjoidXNlciIsImZpcnN0TWVzc2FnZSI6IkZpcnN0IG1lc3NhZ2UiLCJjcmVhdGVkQXQiOiIyMDI2LTAxLTAxVDAwOjAwOjAwWiIsImlkIjoiY3dkLTEiLCJzdW1tYXJ5UmV2aXNpb24iOjEsImN3ZCI6IuKAqOKAqe+/vu6AgPSPv7/wn5iAIMOpzIMg5LitIiwiYXR0ZW50aW9uUmV2aXNpb24iOjAsImlzVW5yZWFkIjpmYWxzZSwid2FpdGluZ0ZvclVzZXIiOmZhbHNlLCJuYW1lIjoiUm93IiwiY29tcGxldGlvblJldmlzaW9uIjowLCJtZXNzYWdlQ291bnQiOjMsInBoYXNlIjoiaWRsZSIsImhhc0FjdGl2ZVN1YmFnZW50cyI6ZmFsc2UsInVwZGF0ZWRBdCI6IjIwMjYtMDEtMDFUMDA6MDA6MDEuMjUwWiJ9",
        "eyJraW5kIjoidXNlciIsImZpcnN0TWVzc2FnZSI6IkZpcnN0IG1lc3NhZ2UiLCJjcmVhdGVkQXQiOiIyMDI2LTAxLTAxVDAwOjAwOjAwWiIsImlkIjoiY3dkLTIiLCJzdW1tYXJ5UmV2aXNpb24iOjEsImN3ZCI6IlwiXFwvIiwiYXR0ZW50aW9uUmV2aXNpb24iOjAsImlzVW5yZWFkIjpmYWxzZSwid2FpdGluZ0ZvclVzZXIiOmZhbHNlLCJuYW1lIjoiUm93IiwiY29tcGxldGlvblJldmlzaW9uIjowLCJtZXNzYWdlQ291bnQiOjMsInBoYXNlIjoiaWRsZSIsImhhc0FjdGl2ZVN1YmFnZW50cyI6ZmFsc2UsInVwZGF0ZWRBdCI6IjIwMjYtMDEtMDFUMDA6MDA6MDEuMjUwWiJ9",
        "eyJraW5kIjoidXNlciIsImZpcnN0TWVzc2FnZSI6IkZpcnN0IG1lc3NhZ2UiLCJjcmVhdGVkQXQiOiIyMDI2LTAxLTAxVDAwOjAwOjAwWiIsImlkIjoiY3dkLTMiLCJzdW1tYXJ5UmV2aXNpb24iOjEsImN3ZCI6IiIsImF0dGVudGlvblJldmlzaW9uIjowLCJpc1VucmVhZCI6ZmFsc2UsIndhaXRpbmdGb3JVc2VyIjpmYWxzZSwibmFtZSI6IlJvdyIsImNvbXBsZXRpb25SZXZpc2lvbiI6MCwibWVzc2FnZUNvdW50IjozLCJwaGFzZSI6ImlkbGUiLCJoYXNBY3RpdmVTdWJhZ2VudHMiOmZhbHNlLCJ1cGRhdGVkQXQiOiIyMDI2LTAxLTAxVDAwOjAwOjAxLjI1MFoifQ==",
        "eyJraW5kIjoidXNlciIsImZpcnN0TWVzc2FnZSI6IkZpcnN0IG1lc3NhZ2UiLCJjcmVhdGVkQXQiOiIyMDI2LTAxLTAxVDAwOjAwOjAwWiIsImlkIjoiY3dkLTQiLCJzdW1tYXJ5UmV2aXNpb24iOjEsImN3ZCI6ImxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgbG9uZyBsb25nIGxvbmcgIiwiYXR0ZW50aW9uUmV2aXNpb24iOjAsImlzVW5yZWFkIjpmYWxzZSwid2FpdGluZ0ZvclVzZXIiOmZhbHNlLCJuYW1lIjoiUm93IiwiY29tcGxldGlvblJldmlzaW9uIjowLCJtZXNzYWdlQ291bnQiOjMsInBoYXNlIjoiaWRsZSIsImhhc0FjdGl2ZVN1YmFnZW50cyI6ZmFsc2UsInVwZGF0ZWRBdCI6IjIwMjYtMDEtMDFUMDA6MDA6MDEuMjUwWiJ9",
        "eyJraW5kIjoidXNlciIsImZpcnN0TWVzc2FnZSI6IkZpcnN0IG1lc3NhZ2UiLCJjcmVhdGVkQXQiOiIyMDI2LTAxLTAxVDAwOjAwOjAwWiIsImlkIjoiXHUwMDAwXHUwMDAxXHUwMDAyXHUwMDAzXHUwMDA0XHUwMDA1XHUwMDA2XHUwMDA3XGJcdFxuXHUwMDBiXGZcclx1MDAwZVx1MDAwZlx1MDAxMFx1MDAxMVx1MDAxMlx1MDAxM1x1MDAxNFx1MDAxNVx1MDAxNlx1MDAxN1x1MDAxOFx1MDAxOVx1MDAxYVx1MDAxYlx1MDAxY1x1MDAxZFx1MDAxZVx1MDAxZiAhXCIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+P0BBQkNERUZHSElKS0xNTk9QUVJTVFVWV1hZWltcXF1eX2BhYmNkZWZnaGlqa2xtbm9wcXJzdHV2d3h5ent8fX5/4oCo4oCp77++7oCA9I+/v/CfmIAgw6nMgyDkuK0iLCJzdW1tYXJ5UmV2aXNpb24iOjEsImN3ZCI6Ii9maXh0dXJlL2NhY2hlIiwiYXR0ZW50aW9uUmV2aXNpb24iOjAsImlzVW5yZWFkIjpmYWxzZSwid2FpdGluZ0ZvclVzZXIiOmZhbHNlLCJuYW1lIjoiUm93IiwiY29tcGxldGlvblJldmlzaW9uIjowLCJtZXNzYWdlQ291bnQiOjMsInBoYXNlIjoiaWRsZSIsImhhc0FjdGl2ZVN1YmFnZW50cyI6ZmFsc2UsInVwZGF0ZWRBdCI6IjIwMjYtMDEtMDFUMDA6MDA6MDEuMjUwWiJ9",
        "eyJraW5kIjoidXNlciIsImZpcnN0TWVzc2FnZSI6IkZpcnN0IG1lc3NhZ2UiLCJjcmVhdGVkQXQiOiIyMDI2LTAxLTAxVDAwOjAwOjAwWiIsImlkIjoidW5uYW1lZCIsInN1bW1hcnlSZXZpc2lvbiI6MSwiY3dkIjoiL2ZpeHR1cmUvY2FjaGUiLCJhdHRlbnRpb25SZXZpc2lvbiI6MCwiaXNVbnJlYWQiOmZhbHNlLCJ3YWl0aW5nRm9yVXNlciI6ZmFsc2UsImNvbXBsZXRpb25SZXZpc2lvbiI6MCwibWVzc2FnZUNvdW50IjozLCJwaGFzZSI6ImlkbGUiLCJoYXNBY3RpdmVTdWJhZ2VudHMiOmZhbHNlLCJ1cGRhdGVkQXQiOiIyMDI2LTAxLTAxVDAwOjAwOjAxLjI1MFoifQ==",
        "eyJraW5kIjoic3ViYWdlbnQiLCJmaXJzdE1lc3NhZ2UiOiJGaXJzdCBtZXNzYWdlIiwiY3JlYXRlZEF0IjoiMjAyNi0wMS0wMVQwMDowMDowMFoiLCJwYXJlbnRTZXNzaW9uSWQiOiJwYXJlbnQtc2Vzc2lvbiIsImlkIjoic3ViYWdlbnQiLCJzdW1tYXJ5UmV2aXNpb24iOjEsImN3ZCI6Ii9maXh0dXJlL2NhY2hlIiwiYXR0ZW50aW9uUmV2aXNpb24iOjAsImlzVW5yZWFkIjpmYWxzZSwid2FpdGluZ0ZvclVzZXIiOmZhbHNlLCJuYW1lIjoiUm93IiwiY29tcGxldGlvblJldmlzaW9uIjowLCJtZXNzYWdlQ291bnQiOjMsInBoYXNlIjoiaWRsZSIsInVwZGF0ZWRBdCI6IjIwMjYtMDEtMDFUMDA6MDA6MDEuMjUwWiIsImhhc0FjdGl2ZVN1YmFnZW50cyI6ZmFsc2V9",
        "eyJraW5kIjoidXNlciIsInVwZGF0ZWRBdCI6IjIwMjYtMDEtMDFUMDA6MDA6MDEuMjUwWiIsImZpcnN0TWVzc2FnZSI6IkZpcnN0IG1lc3NhZ2UiLCJjcmVhdGVkQXQiOiIyMDI2LTAxLTAxVDAwOjAwOjAwWiIsImlkIjoiYXV0b21hdGlvbiIsInN1bW1hcnlSZXZpc2lvbiI6MSwiY3dkIjoiL2ZpeHR1cmUvY2FjaGUiLCJhdHRlbnRpb25SZXZpc2lvbiI6MCwiaXNVbnJlYWQiOmZhbHNlLCJ3YWl0aW5nRm9yVXNlciI6ZmFsc2UsIm5hbWUiOiJSb3ciLCJjb21wbGV0aW9uUmV2aXNpb24iOjAsIm1lc3NhZ2VDb3VudCI6MywicGhhc2UiOiJpZGxlIiwiaGFzQWN0aXZlU3ViYWdlbnRzIjpmYWxzZSwiY3JlYXRpb25PcmlnaW4iOnsia2luZCI6ImF1dG9tYXRpb24iLCJhdXRvbWF0aW9uSWQiOiIwZjhlNGE2Yy0zYjJkLTRlMWYtOWE3Yi0yYzVkOGUxZjRhNmIifX0=",
        "eyJraW5kIjoidXNlciIsInVwZGF0ZWRBdCI6IjIwMjYtMDEtMDFUMDA6MDA6MDEuMjUwWiIsImZpcnN0TWVzc2FnZSI6IkZpcnN0IG1lc3NhZ2UiLCJjcmVhdGVkQXQiOiIyMDI2LTAxLTAxVDAwOjAwOjAwWiIsImlkIjoiYXV0b21hdGlvbi11cHBlciIsInN1bW1hcnlSZXZpc2lvbiI6MSwiY3dkIjoiL2ZpeHR1cmUvY2FjaGUiLCJhdHRlbnRpb25SZXZpc2lvbiI6MCwiaXNVbnJlYWQiOmZhbHNlLCJ3YWl0aW5nRm9yVXNlciI6ZmFsc2UsIm5hbWUiOiJSb3ciLCJjb21wbGV0aW9uUmV2aXNpb24iOjAsIm1lc3NhZ2VDb3VudCI6MywicGhhc2UiOiJpZGxlIiwiaGFzQWN0aXZlU3ViYWdlbnRzIjpmYWxzZSwiY3JlYXRpb25PcmlnaW4iOnsia2luZCI6ImF1dG9tYXRpb24iLCJhdXRvbWF0aW9uSWQiOiIwRjhFNEE2Qy0zQjJELTRFMUYtOUE3Qi0yQzVEOEUxRjRBNkIifX0=",
        "eyJraW5kIjoidXNlciIsImZpcnN0TWVzc2FnZSI6IkZpcnN0IG1lc3NhZ2UiLCJjcmVhdGVkQXQiOiIyMDI2LTAxLTAxVDAwOjAwOjAwWiIsImlkIjoid29ya2VyIiwic3VtbWFyeVJldmlzaW9uIjoxLCJjd2QiOiIvZml4dHVyZS9jYWNoZSIsImF0dGVudGlvblJldmlzaW9uIjowLCJpc1VucmVhZCI6ZmFsc2UsIndhaXRpbmdGb3JVc2VyIjpmYWxzZSwibmFtZSI6IlJvdyIsImNvbXBsZXRpb25SZXZpc2lvbiI6MCwiaG9tZVRhc2tJZCI6InRhc2stMSIsIm1lc3NhZ2VDb3VudCI6MywicGhhc2UiOiJpZGxlIiwiaGFzQWN0aXZlU3ViYWdlbnRzIjpmYWxzZSwidXBkYXRlZEF0IjoiMjAyNi0wMS0wMVQwMDowMDowMS4yNTBaIn0=",
        "eyJraW5kIjoidXNlciIsImFjdGl2ZVNpbmNlIjoiMjAyNi0wMS0wMVQwMDowMDowMFoiLCJmaXJzdE1lc3NhZ2UiOiJGaXJzdCBtZXNzYWdlIiwiY3JlYXRlZEF0IjoiMjAyNi0wMS0wMVQwMDowMDowMFoiLCJpZCI6ImFjdGl2ZSIsInN1bW1hcnlSZXZpc2lvbiI6MSwiY3dkIjoiL2ZpeHR1cmUvY2FjaGUiLCJhdHRlbnRpb25SZXZpc2lvbiI6MCwiaXNVbnJlYWQiOmZhbHNlLCJ3YWl0aW5nRm9yVXNlciI6ZmFsc2UsIm5hbWUiOiJSb3ciLCJjb21wbGV0aW9uUmV2aXNpb24iOjAsIm1lc3NhZ2VDb3VudCI6MywicGhhc2UiOiJydW5uaW5nIiwiaGFzQWN0aXZlU3ViYWdlbnRzIjpmYWxzZSwidXBkYXRlZEF0IjoiMjAyNi0wMS0wMVQwMDowMDowMS4yNTBaIn0=",
        "eyJraW5kIjoidXNlciIsImZpcnN0TWVzc2FnZSI6IkZpcnN0IG1lc3NhZ2UiLCJjcmVhdGVkQXQiOiIyMDI2LTAxLTAxVDAwOjAwOjAwWiIsImlkIjoicGhhc2UtaWRsZSIsInN1bW1hcnlSZXZpc2lvbiI6MSwiY3dkIjoiL2ZpeHR1cmUvY2FjaGUiLCJhdHRlbnRpb25SZXZpc2lvbiI6MCwiaXNVbnJlYWQiOmZhbHNlLCJ3YWl0aW5nRm9yVXNlciI6ZmFsc2UsIm5hbWUiOiJSb3ciLCJjb21wbGV0aW9uUmV2aXNpb24iOjAsIm1lc3NhZ2VDb3VudCI6MywicGhhc2UiOiJpZGxlIiwiaGFzQWN0aXZlU3ViYWdlbnRzIjpmYWxzZSwidXBkYXRlZEF0IjoiMjAyNi0wMS0wMVQwMDowMDowMS4yNTBaIn0=",
        "eyJraW5kIjoidXNlciIsImZpcnN0TWVzc2FnZSI6IkZpcnN0IG1lc3NhZ2UiLCJjcmVhdGVkQXQiOiIyMDI2LTAxLTAxVDAwOjAwOjAwWiIsImlkIjoicGhhc2UtcnVubmluZyIsInN1bW1hcnlSZXZpc2lvbiI6MSwiY3dkIjoiL2ZpeHR1cmUvY2FjaGUiLCJhdHRlbnRpb25SZXZpc2lvbiI6MCwiaXNVbnJlYWQiOmZhbHNlLCJ3YWl0aW5nRm9yVXNlciI6ZmFsc2UsIm5hbWUiOiJSb3ciLCJjb21wbGV0aW9uUmV2aXNpb24iOjAsIm1lc3NhZ2VDb3VudCI6MywicGhhc2UiOiJydW5uaW5nIiwiaGFzQWN0aXZlU3ViYWdlbnRzIjpmYWxzZSwidXBkYXRlZEF0IjoiMjAyNi0wMS0wMVQwMDowMDowMS4yNTBaIn0=",
        "eyJraW5kIjoidXNlciIsImZpcnN0TWVzc2FnZSI6IkZpcnN0IG1lc3NhZ2UiLCJjcmVhdGVkQXQiOiIyMDI2LTAxLTAxVDAwOjAwOjAwWiIsImlkIjoicGhhc2UtY29tcGFjdGluZyIsInN1bW1hcnlSZXZpc2lvbiI6MSwiY3dkIjoiL2ZpeHR1cmUvY2FjaGUiLCJhdHRlbnRpb25SZXZpc2lvbiI6MCwiaXNVbnJlYWQiOmZhbHNlLCJ3YWl0aW5nRm9yVXNlciI6ZmFsc2UsIm5hbWUiOiJSb3ciLCJjb21wbGV0aW9uUmV2aXNpb24iOjAsIm1lc3NhZ2VDb3VudCI6MywicGhhc2UiOiJjb21wYWN0aW5nIiwiaGFzQWN0aXZlU3ViYWdlbnRzIjpmYWxzZSwidXBkYXRlZEF0IjoiMjAyNi0wMS0wMVQwMDowMDowMS4yNTBaIn0=",
        "eyJraW5kIjoidXNlciIsImZpcnN0TWVzc2FnZSI6IkZpcnN0IG1lc3NhZ2UiLCJjcmVhdGVkQXQiOiIyMDI2LTAxLTAxVDAwOjAwOjAwWiIsImlkIjoicGhhc2UtcmV0cnlpbmciLCJzdW1tYXJ5UmV2aXNpb24iOjEsImN3ZCI6Ii9maXh0dXJlL2NhY2hlIiwiYXR0ZW50aW9uUmV2aXNpb24iOjAsImlzVW5yZWFkIjpmYWxzZSwid2FpdGluZ0ZvclVzZXIiOmZhbHNlLCJuYW1lIjoiUm93IiwiY29tcGxldGlvblJldmlzaW9uIjowLCJtZXNzYWdlQ291bnQiOjMsInBoYXNlIjoicmV0cnlpbmciLCJoYXNBY3RpdmVTdWJhZ2VudHMiOmZhbHNlLCJ1cGRhdGVkQXQiOiIyMDI2LTAxLTAxVDAwOjAwOjAxLjI1MFoifQ==",
        "eyJraW5kIjoidXNlciIsImZpcnN0TWVzc2FnZSI6IkZpcnN0IG1lc3NhZ2UiLCJjcmVhdGVkQXQiOiIyMDI2LTAxLTAxVDAwOjAwOjAwWiIsImlkIjoicGhhc2UtaW50ZXJydXB0ZWQiLCJzdW1tYXJ5UmV2aXNpb24iOjEsImN3ZCI6Ii9maXh0dXJlL2NhY2hlIiwiYXR0ZW50aW9uUmV2aXNpb24iOjAsImlzVW5yZWFkIjpmYWxzZSwid2FpdGluZ0ZvclVzZXIiOmZhbHNlLCJuYW1lIjoiUm93IiwiY29tcGxldGlvblJldmlzaW9uIjowLCJtZXNzYWdlQ291bnQiOjMsInBoYXNlIjoiaW50ZXJydXB0ZWQiLCJoYXNBY3RpdmVTdWJhZ2VudHMiOmZhbHNlLCJ1cGRhdGVkQXQiOiIyMDI2LTAxLTAxVDAwOjAwOjAxLjI1MFoifQ==",
        "eyJraW5kIjoidXNlciIsImZvcmVncm91bmRQaGFzZSI6ImlkbGUiLCJmaXJzdE1lc3NhZ2UiOiJGaXJzdCBtZXNzYWdlIiwiY3JlYXRlZEF0IjoiMjAyNi0wMS0wMVQwMDowMDowMFoiLCJpZCI6ImZvcmVncm91bmQtaWRsZSIsInN1bW1hcnlSZXZpc2lvbiI6MSwiY3dkIjoiL2ZpeHR1cmUvY2FjaGUiLCJhdHRlbnRpb25SZXZpc2lvbiI6MCwiaXNVbnJlYWQiOmZhbHNlLCJ3YWl0aW5nRm9yVXNlciI6ZmFsc2UsIm5hbWUiOiJSb3ciLCJjb21wbGV0aW9uUmV2aXNpb24iOjAsIm1lc3NhZ2VDb3VudCI6MywicGhhc2UiOiJydW5uaW5nIiwiaGFzQWN0aXZlU3ViYWdlbnRzIjpmYWxzZSwidXBkYXRlZEF0IjoiMjAyNi0wMS0wMVQwMDowMDowMS4yNTBaIn0=",
        "eyJraW5kIjoidXNlciIsImZvcmVncm91bmRQaGFzZSI6InJ1bm5pbmciLCJmaXJzdE1lc3NhZ2UiOiJGaXJzdCBtZXNzYWdlIiwiY3JlYXRlZEF0IjoiMjAyNi0wMS0wMVQwMDowMDowMFoiLCJpZCI6ImZvcmVncm91bmQtcnVubmluZyIsInN1bW1hcnlSZXZpc2lvbiI6MSwiY3dkIjoiL2ZpeHR1cmUvY2FjaGUiLCJhdHRlbnRpb25SZXZpc2lvbiI6MCwiaXNVbnJlYWQiOmZhbHNlLCJ3YWl0aW5nRm9yVXNlciI6ZmFsc2UsIm5hbWUiOiJSb3ciLCJjb21wbGV0aW9uUmV2aXNpb24iOjAsIm1lc3NhZ2VDb3VudCI6MywicGhhc2UiOiJydW5uaW5nIiwiaGFzQWN0aXZlU3ViYWdlbnRzIjpmYWxzZSwidXBkYXRlZEF0IjoiMjAyNi0wMS0wMVQwMDowMDowMS4yNTBaIn0=",
        "eyJraW5kIjoidXNlciIsImZvcmVncm91bmRQaGFzZSI6ImNvbXBhY3RpbmciLCJmaXJzdE1lc3NhZ2UiOiJGaXJzdCBtZXNzYWdlIiwiY3JlYXRlZEF0IjoiMjAyNi0wMS0wMVQwMDowMDowMFoiLCJpZCI6ImZvcmVncm91bmQtY29tcGFjdGluZyIsInN1bW1hcnlSZXZpc2lvbiI6MSwiY3dkIjoiL2ZpeHR1cmUvY2FjaGUiLCJhdHRlbnRpb25SZXZpc2lvbiI6MCwiaXNVbnJlYWQiOmZhbHNlLCJ3YWl0aW5nRm9yVXNlciI6ZmFsc2UsIm5hbWUiOiJSb3ciLCJjb21wbGV0aW9uUmV2aXNpb24iOjAsIm1lc3NhZ2VDb3VudCI6MywicGhhc2UiOiJydW5uaW5nIiwiaGFzQWN0aXZlU3ViYWdlbnRzIjpmYWxzZSwidXBkYXRlZEF0IjoiMjAyNi0wMS0wMVQwMDowMDowMS4yNTBaIn0=",
        "eyJraW5kIjoidXNlciIsImZvcmVncm91bmRQaGFzZSI6InJldHJ5aW5nIiwiZmlyc3RNZXNzYWdlIjoiRmlyc3QgbWVzc2FnZSIsImNyZWF0ZWRBdCI6IjIwMjYtMDEtMDFUMDA6MDA6MDBaIiwiaWQiOiJmb3JlZ3JvdW5kLXJldHJ5aW5nIiwic3VtbWFyeVJldmlzaW9uIjoxLCJjd2QiOiIvZml4dHVyZS9jYWNoZSIsImF0dGVudGlvblJldmlzaW9uIjowLCJpc1VucmVhZCI6ZmFsc2UsIndhaXRpbmdGb3JVc2VyIjpmYWxzZSwibmFtZSI6IlJvdyIsImNvbXBsZXRpb25SZXZpc2lvbiI6MCwibWVzc2FnZUNvdW50IjozLCJwaGFzZSI6InJ1bm5pbmciLCJoYXNBY3RpdmVTdWJhZ2VudHMiOmZhbHNlLCJ1cGRhdGVkQXQiOiIyMDI2LTAxLTAxVDAwOjAwOjAxLjI1MFoifQ==",
        "eyJraW5kIjoidXNlciIsImZvcmVncm91bmRQaGFzZSI6ImludGVycnVwdGVkIiwiZmlyc3RNZXNzYWdlIjoiRmlyc3QgbWVzc2FnZSIsImNyZWF0ZWRBdCI6IjIwMjYtMDEtMDFUMDA6MDA6MDBaIiwiaWQiOiJmb3JlZ3JvdW5kLWludGVycnVwdGVkIiwic3VtbWFyeVJldmlzaW9uIjoxLCJjd2QiOiIvZml4dHVyZS9jYWNoZSIsImF0dGVudGlvblJldmlzaW9uIjowLCJpc1VucmVhZCI6ZmFsc2UsIndhaXRpbmdGb3JVc2VyIjpmYWxzZSwibmFtZSI6IlJvdyIsImNvbXBsZXRpb25SZXZpc2lvbiI6MCwibWVzc2FnZUNvdW50IjozLCJwaGFzZSI6InJ1bm5pbmciLCJoYXNBY3RpdmVTdWJhZ2VudHMiOmZhbHNlLCJ1cGRhdGVkQXQiOiIyMDI2LTAxLTAxVDAwOjAwOjAxLjI1MFoifQ==",
        "eyJraW5kIjoidXNlciIsImZpcnN0TWVzc2FnZSI6IkZpcnN0IG1lc3NhZ2UiLCJjcmVhdGVkQXQiOiIyMDI2LTAxLTAxVDAwOjAwOjAwWiIsImlkIjoiY291bnQtMCIsInN1bW1hcnlSZXZpc2lvbiI6MSwiY3dkIjoiL2ZpeHR1cmUvY2FjaGUiLCJhdHRlbnRpb25SZXZpc2lvbiI6MCwiaXNVbnJlYWQiOmZhbHNlLCJ3YWl0aW5nRm9yVXNlciI6ZmFsc2UsIm5hbWUiOiJSb3ciLCJjb21wbGV0aW9uUmV2aXNpb24iOjAsIm1lc3NhZ2VDb3VudCI6MCwicGhhc2UiOiJpZGxlIiwiaGFzQWN0aXZlU3ViYWdlbnRzIjpmYWxzZSwidXBkYXRlZEF0IjoiMjAyNi0wMS0wMVQwMDowMDowMS4yNTBaIn0=",
        "eyJraW5kIjoidXNlciIsImZpcnN0TWVzc2FnZSI6IkZpcnN0IG1lc3NhZ2UiLCJjcmVhdGVkQXQiOiIyMDI2LTAxLTAxVDAwOjAwOjAwWiIsImlkIjoiY291bnQtMSIsInN1bW1hcnlSZXZpc2lvbiI6MSwiY3dkIjoiL2ZpeHR1cmUvY2FjaGUiLCJhdHRlbnRpb25SZXZpc2lvbiI6MCwiaXNVbnJlYWQiOmZhbHNlLCJ3YWl0aW5nRm9yVXNlciI6ZmFsc2UsIm5hbWUiOiJSb3ciLCJjb21wbGV0aW9uUmV2aXNpb24iOjAsIm1lc3NhZ2VDb3VudCI6MSwicGhhc2UiOiJpZGxlIiwiaGFzQWN0aXZlU3ViYWdlbnRzIjpmYWxzZSwidXBkYXRlZEF0IjoiMjAyNi0wMS0wMVQwMDowMDowMS4yNTBaIn0=",
        "eyJraW5kIjoidXNlciIsImZpcnN0TWVzc2FnZSI6IkZpcnN0IG1lc3NhZ2UiLCJjcmVhdGVkQXQiOiIyMDI2LTAxLTAxVDAwOjAwOjAwWiIsImlkIjoiY291bnQtOTAwNzE5OTI1NDc0MDk5MSIsInN1bW1hcnlSZXZpc2lvbiI6MSwiY3dkIjoiL2ZpeHR1cmUvY2FjaGUiLCJhdHRlbnRpb25SZXZpc2lvbiI6MCwiaXNVbnJlYWQiOmZhbHNlLCJ3YWl0aW5nRm9yVXNlciI6ZmFsc2UsIm5hbWUiOiJSb3ciLCJjb21wbGV0aW9uUmV2aXNpb24iOjAsIm1lc3NhZ2VDb3VudCI6OTAwNzE5OTI1NDc0MDk5MSwicGhhc2UiOiJpZGxlIiwiaGFzQWN0aXZlU3ViYWdlbnRzIjpmYWxzZSwidXBkYXRlZEF0IjoiMjAyNi0wMS0wMVQwMDowMDowMS4yNTBaIn0=",
        "eyJraW5kIjoidXNlciIsImZpcnN0TWVzc2FnZSI6IkZpcnN0IG1lc3NhZ2UiLCJjcmVhdGVkQXQiOiIyMDI2LTAxLTAxVDAwOjAwOjAwWiIsImlkIjoicmV2aXNpb24tYWJzZW50IiwiY3dkIjoiL2ZpeHR1cmUvY2FjaGUiLCJhdHRlbnRpb25SZXZpc2lvbiI6MCwiaXNVbnJlYWQiOmZhbHNlLCJ3YWl0aW5nRm9yVXNlciI6ZmFsc2UsImNvbXBsZXRpb25SZXZpc2lvbiI6MCwibmFtZSI6IlJvdyIsIm1lc3NhZ2VDb3VudCI6MywicGhhc2UiOiJpZGxlIiwiaGFzQWN0aXZlU3ViYWdlbnRzIjpmYWxzZSwidXBkYXRlZEF0IjoiMjAyNi0wMS0wMVQwMDowMDowMS4yNTBaIn0=",
        "eyJraW5kIjoidXNlciIsImZpcnN0TWVzc2FnZSI6IkZpcnN0IG1lc3NhZ2UiLCJjcmVhdGVkQXQiOiIyMDI2LTAxLTAxVDAwOjAwOjAwWiIsImlkIjoicmV2aXNpb24tMCIsInN1bW1hcnlSZXZpc2lvbiI6MCwiY3dkIjoiL2ZpeHR1cmUvY2FjaGUiLCJhdHRlbnRpb25SZXZpc2lvbiI6MCwiaXNVbnJlYWQiOmZhbHNlLCJ3YWl0aW5nRm9yVXNlciI6ZmFsc2UsIm5hbWUiOiJSb3ciLCJjb21wbGV0aW9uUmV2aXNpb24iOjAsIm1lc3NhZ2VDb3VudCI6MywicGhhc2UiOiJpZGxlIiwiaGFzQWN0aXZlU3ViYWdlbnRzIjpmYWxzZSwidXBkYXRlZEF0IjoiMjAyNi0wMS0wMVQwMDowMDowMS4yNTBaIn0=",
        "eyJraW5kIjoidXNlciIsImZpcnN0TWVzc2FnZSI6IkZpcnN0IG1lc3NhZ2UiLCJjcmVhdGVkQXQiOiIyMDI2LTAxLTAxVDAwOjAwOjAwWiIsImlkIjoicmV2aXNpb24tNyIsInN1bW1hcnlSZXZpc2lvbiI6NywiY3dkIjoiL2ZpeHR1cmUvY2FjaGUiLCJhdHRlbnRpb25SZXZpc2lvbiI6MCwiaXNVbnJlYWQiOmZhbHNlLCJ3YWl0aW5nRm9yVXNlciI6ZmFsc2UsIm5hbWUiOiJSb3ciLCJjb21wbGV0aW9uUmV2aXNpb24iOjAsIm1lc3NhZ2VDb3VudCI6MywicGhhc2UiOiJpZGxlIiwiaGFzQWN0aXZlU3ViYWdlbnRzIjpmYWxzZSwidXBkYXRlZEF0IjoiMjAyNi0wMS0wMVQwMDowMDowMS4yNTBaIn0=",
        "eyJraW5kIjoidXNlciIsImZpcnN0TWVzc2FnZSI6IkZpcnN0IG1lc3NhZ2UiLCJjcmVhdGVkQXQiOiIyMDI2LTAxLTAxVDAwOjAwOjAwWiIsImlkIjoicmV2aXNpb24tOTAwNzE5OTI1NDc0MDk5MSIsInN1bW1hcnlSZXZpc2lvbiI6OTAwNzE5OTI1NDc0MDk5MSwiY3dkIjoiL2ZpeHR1cmUvY2FjaGUiLCJhdHRlbnRpb25SZXZpc2lvbiI6MCwiaXNVbnJlYWQiOmZhbHNlLCJ3YWl0aW5nRm9yVXNlciI6ZmFsc2UsIm5hbWUiOiJSb3ciLCJjb21wbGV0aW9uUmV2aXNpb24iOjAsIm1lc3NhZ2VDb3VudCI6MywicGhhc2UiOiJpZGxlIiwiaGFzQWN0aXZlU3ViYWdlbnRzIjpmYWxzZSwidXBkYXRlZEF0IjoiMjAyNi0wMS0wMVQwMDowMDowMS4yNTBaIn0=",
        "eyJraW5kIjoidXNlciIsImZpcnN0TWVzc2FnZSI6IkZpcnN0IG1lc3NhZ2UiLCJjcmVhdGVkQXQiOiIyMDI2LTAxLTAxVDAwOjAwOjAwWiIsImlkIjoiYXR0ZW50aW9uLTAiLCJzdW1tYXJ5UmV2aXNpb24iOjEsImN3ZCI6Ii9maXh0dXJlL2NhY2hlIiwiYXR0ZW50aW9uUmV2aXNpb24iOjAsImlzVW5yZWFkIjpmYWxzZSwid2FpdGluZ0ZvclVzZXIiOmZhbHNlLCJuYW1lIjoiUm93IiwiY29tcGxldGlvblJldmlzaW9uIjowLCJtZXNzYWdlQ291bnQiOjMsInBoYXNlIjoiaWRsZSIsImhhc0FjdGl2ZVN1YmFnZW50cyI6ZmFsc2UsInVwZGF0ZWRBdCI6IjIwMjYtMDEtMDFUMDA6MDA6MDEuMjUwWiJ9",
        "eyJraW5kIjoidXNlciIsImZpcnN0TWVzc2FnZSI6IkZpcnN0IG1lc3NhZ2UiLCJjcmVhdGVkQXQiOiIyMDI2LTAxLTAxVDAwOjAwOjAwWiIsImlkIjoiYXR0ZW50aW9uLTUiLCJzdW1tYXJ5UmV2aXNpb24iOjEsImN3ZCI6Ii9maXh0dXJlL2NhY2hlIiwiYXR0ZW50aW9uUmV2aXNpb24iOjQsImlzVW5yZWFkIjpmYWxzZSwid2FpdGluZ0ZvclVzZXIiOmZhbHNlLCJuYW1lIjoiUm93IiwiY29tcGxldGlvblJldmlzaW9uIjo1LCJtZXNzYWdlQ291bnQiOjMsInBoYXNlIjoiaWRsZSIsImhhc0FjdGl2ZVN1YmFnZW50cyI6ZmFsc2UsInVwZGF0ZWRBdCI6IjIwMjYtMDEtMDFUMDA6MDA6MDEuMjUwWiJ9",
        "eyJraW5kIjoidXNlciIsImZpcnN0TWVzc2FnZSI6IkZpcnN0IG1lc3NhZ2UiLCJjcmVhdGVkQXQiOiIyMDI2LTAxLTAxVDAwOjAwOjAwWiIsImlkIjoiYXR0ZW50aW9uLTkwMDcxOTkyNTQ3NDA5OTEiLCJzdW1tYXJ5UmV2aXNpb24iOjEsImN3ZCI6Ii9maXh0dXJlL2NhY2hlIiwiYXR0ZW50aW9uUmV2aXNpb24iOjkwMDcxOTkyNTQ3NDA5OTEsImlzVW5yZWFkIjpmYWxzZSwid2FpdGluZ0ZvclVzZXIiOmZhbHNlLCJuYW1lIjoiUm93IiwiY29tcGxldGlvblJldmlzaW9uIjo5MDA3MTk5MjU0NzQwOTkxLCJtZXNzYWdlQ291bnQiOjMsInBoYXNlIjoiaWRsZSIsImhhc0FjdGl2ZVN1YmFnZW50cyI6ZmFsc2UsInVwZGF0ZWRBdCI6IjIwMjYtMDEtMDFUMDA6MDA6MDEuMjUwWiJ9",
        "eyJraW5kIjoidXNlciIsImZpcnN0TWVzc2FnZSI6IkZpcnN0IG1lc3NhZ2UiLCJjcmVhdGVkQXQiOiIyMDI2LTAxLTAxVDAwOjAwOjAwWiIsImlkIjoiZmxhZ3MiLCJzdW1tYXJ5UmV2aXNpb24iOjEsImN3ZCI6Ii9maXh0dXJlL2NhY2hlIiwiYXR0ZW50aW9uUmV2aXNpb24iOjAsImlzVW5yZWFkIjp0cnVlLCJ3YWl0aW5nRm9yVXNlciI6dHJ1ZSwibmFtZSI6IlJvdyIsImNvbXBsZXRpb25SZXZpc2lvbiI6MCwibWVzc2FnZUNvdW50IjozLCJwaGFzZSI6ImlkbGUiLCJoYXNBY3RpdmVTdWJhZ2VudHMiOnRydWUsInVwZGF0ZWRBdCI6IjIwMjYtMDEtMDFUMDA6MDA6MDEuMjUwWiJ9",
        "eyJraW5kIjoidXNlciIsImZvcmVncm91bmRQaGFzZSI6ImlkbGUiLCJmaXJzdE1lc3NhZ2UiOiJGaXJzdCBtZXNzYWdlIiwiY3JlYXRlZEF0IjoiMjAyNi0wMS0wMVQwMDowMDowMFoiLCJpZCI6ImZsYWdzLXN1YmFnZW50cyIsInN1bW1hcnlSZXZpc2lvbiI6MSwiY3dkIjoiL2ZpeHR1cmUvY2FjaGUiLCJhdHRlbnRpb25SZXZpc2lvbiI6MCwiaXNVbnJlYWQiOmZhbHNlLCJ3YWl0aW5nRm9yVXNlciI6ZmFsc2UsIm5hbWUiOiJSb3ciLCJjb21wbGV0aW9uUmV2aXNpb24iOjAsIm1lc3NhZ2VDb3VudCI6MywicGhhc2UiOiJydW5uaW5nIiwiaGFzQWN0aXZlU3ViYWdlbnRzIjp0cnVlLCJ1cGRhdGVkQXQiOiIyMDI2LTAxLTAxVDAwOjAwOjAxLjI1MFoifQ==",
    ].map { String(decoding: Data(base64Encoded: $0)!, as: UTF8.self) }

    static let nearLimitCapturedRow = #"{"phase":"idle","isUnread":false,"waitingForUser":false,"hasActiveSubagents":false,"messageCount":3,"attentionRevision":0,"completionRevision":0,"updatedAt":"2026-01-01T00:00:01.250Z","createdAt":"2026-01-01T00:00:00Z","cwd":"/fixture/cache","firstMessage":""#
        + String(repeating: "x", count: 130_077) + #"","name":"Row","id":"near-limit","kind":"user"}"#

    static let declarationOrder = ["id", "name", "cwd", "kind", "parentSessionId", "creationOrigin", "homeTaskId", "createdAt",
        "updatedAt", "activeSince", "messageCount", "firstMessage", "phase", "foregroundPhase", "hasActiveSubagents",
        "waitingForUser", "summaryRevision", "completionRevision", "attentionRevision", "isUnread", "archivedAt"]

    static func report(cache: SnapshotCache, root: URL) async -> [String: Any] {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var readRows = 0, readMismatches: [String] = [], shuffledDistinct = 0
        var absentRevisionReads: [Int] = []
        for permutation in 0...3 {
            var seed = UInt64(permutation + 1)
            let rows = capturedRows.map { permutation == 0 ? $0 : RawJSON.shuffled(Substring($0), seed: &seed) }
            shuffledDistinct += permutation == 0 ? 0 : zip(rows, capturedRows).filter { $0 != $1 }.count
            let profileID = "row-compat-read-\(permutation)"
            try? Data((#"{"version":4,"sessions":["# + rows.joined(separator: ",") + #"],"archivedCount":2}"#).utf8)
                .write(to: file(root, profileID))
            let loaded = await cache.load(profileID: profileID)
            if loaded.archivedCount != 2 || loaded.sessions.count != capturedRows.count { readMismatches.append("\(permutation):document") }
            for (index, (captured, session)) in zip(capturedRows, loaded.sessions).enumerated() {
                readRows += 1
                switch compare(written: session.summary.encode(), captured: captured) {
                case .same: break
                case .absentRevisionWrittenAsZero: if permutation == 0 { absentRevisionReads.append(index) }
                case .different: readMismatches.append("\(permutation):\(index)")
                }
            }
        }

        let source = await cache.load(profileID: "row-compat-read-0").sessions
        await cache.save(profileID: "row-compat-write", sessions: source, archivedCount: 2)
        let written = String(decoding: (try? Data(contentsOf: file(root, "row-compat-write"))) ?? Data(), as: UTF8.self)
        let rows = RawJSON.members(Substring(written))?.first { $0.key == #""sessions""# }.flatMap { RawJSON.elements($0.value) } ?? []
        var writeMismatches: [String] = [], orderMismatches: [Int] = [], absentRevisionWrites: [Int] = []
        for (index, (captured, row)) in zip(capturedRows, rows).enumerated() {
            switch compare(written: String(row), captured: captured) {
            case .same: break
            case .absentRevisionWrittenAsZero: absentRevisionWrites.append(index)
            case .different: writeMismatches.append("\(index)")
            }
            let members = RawJSON.members(row) ?? []
            let keys = members.map { String($0.key.dropFirst().dropLast()) }
            let nested = members.first { $0.key == #""creationOrigin""# }.flatMap { RawJSON.members($0.value) }
            if keys != declarationOrder.filter(keys.contains) || nested.map({ $0.map(\.key) != [#""kind""#, #""automationId""#] }) == true {
                orderMismatches.append(index)
            }
        }

        let full = (0..<SnapshotCachePolicy.maximumSessionCount).map { index in
            CatalogSession(SessionSummary(id: "full-\(index)", name: "Full \(index)", cwd: "/fixture/cache", createdAt: "2026-01-01T00:00:00Z",
                updatedAt: "2026-01-01T00:00:00Z", messageCount: index, firstMessage: "Full cache row", phase: .idle, summaryRevision: 1))
        }
        await cache.save(profileID: "row-compat-full", sessions: full)
        let fullRows = await cache.load(profileID: "row-compat-full").sessions.count

        let nearProfile = "row-compat-near-limit"
        try? Data((#"{"version":4,"sessions":["# + nearLimitCapturedRow + "]}").utf8).write(to: file(root, nearProfile))
        let nearLoaded = await cache.load(profileID: nearProfile).sessions
        await cache.save(profileID: nearProfile, sessions: nearLoaded)
        let nearRestored = await cache.load(profileID: nearProfile).sessions
        let nearLimitReadMatches = nearLoaded.first.map { compare(written: $0.summary.encode(), captured: nearLimitCapturedRow) == .absentRevisionWrittenAsZero } ?? false
        let nearLimitWriteMatches = nearRestored.first.map { compare(written: $0.summary.encode(), captured: nearLimitCapturedRow) == .absentRevisionWrittenAsZero } ?? false

        var revisionReaders: [String: [String]] = [:]
        for (name, index) in [("absent", 36), ("zero", 37)] where source.indices.contains(index) {
            let row = source[index]
            revisionReaders[name] = [0, 1].flatMap { revision -> [String] in
                let update = SessionSummaryUpdate(sessionId: row.id, summaryRevision: revision, phase: .idle,
                    updatedAt: row.updatedAt, messageCount: row.messageCount, firstMessage: "Updated \(revision)")
                var applied = SessionCatalogCoordinator()
                applied.installCached([row])
                var published = SessionCatalogCoordinator()
                _ = published.apply(update)
                let admission = published.beginLoad()
                published.publishAuthoritative([row], admission: admission, projectionToken: "row-compat")
                return ["apply \(revision):\(applied.apply(update))",
                        "publish \(revision):\(published.sessions.first?.firstMessage == "Updated \(revision)" ? "updated" : "kept")"]
            }
        }
        return ["capturedRows": capturedRows.count, "readRows": readRows, "readMismatches": readMismatches,
                "shuffledDistinct": shuffledDistinct, "absentRevisionReads": absentRevisionReads, "writtenRows": rows.count,
                "writeMismatches": writeMismatches, "orderMismatches": orderMismatches,
                "absentRevisionWrites": absentRevisionWrites, "revisionReaders": revisionReaders,
                "absentRevisionRowID": source.indices.contains(36) ? source[36].id : "", "fullRows": fullRows,
                "nearLimitReadIDs": nearLoaded.map(\.id), "nearLimitWrittenIDs": nearRestored.map(\.id),
                "nearLimitReadMatches": nearLimitReadMatches, "nearLimitWriteMatches": nearLimitWriteMatches]
    }

    private enum Comparison: Equatable { case same, absentRevisionWrittenAsZero, different }

    private static func compare(written: String, captured: String) -> Comparison {
        if RawJSON.normalized(Substring(written)) == RawJSON.normalized(Substring(captured)) { return .same }
        let members = RawJSON.members(Substring(written)) ?? []
        let capturedKeys = (RawJSON.members(Substring(captured)) ?? []).map(\.key)
        guard !capturedKeys.contains(#""summaryRevision""#),
              members.first(where: { $0.key == #""summaryRevision""# })?.value == "0" else { return .different }
        let without = "{" + members.filter { $0.key != #""summaryRevision""# }.map { "\($0.key):\($0.value)" }.joined(separator: ",") + "}"
        return RawJSON.normalized(Substring(without)) == RawJSON.normalized(Substring(captured)) ? .absentRevisionWrittenAsZero : .different
    }

    private static func file(_ root: URL, _ profileID: String) -> URL {
        let digest = SHA256.hash(data: Data(profileID.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appending(path: "\(digest).json")
    }
}
#endif
