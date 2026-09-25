import Foundation

/// Loose helpers for poking at JSON whose schema we don't control (Cursor's internal state).
enum J {
    static func obj(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func obj(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8) else { return nil }
        return obj(data)
    }

    /// Finite numbers only: "nan"/"inf" would trap in Int() or throw in JSONSerialization.
    static func number(_ v: Any?) -> Double? {
        var parsed: Double?
        if let n = v as? NSNumber { parsed = n.doubleValue } else if let s = v as? String { parsed = Double(s) }
        guard let value = parsed, value.isFinite else { return nil }
        return value
    }

    static func int(_ v: Any?) -> Int? { number(v).map { Int($0) } }

    static func string(_ data: Data?) -> String? {
        guard let data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Accepts epoch seconds, epoch milliseconds, or ISO-8601 strings.
    static func date(_ v: Any?) -> Date? {
        if let n = number(v), n > 0 {
            return Date(timeIntervalSince1970: n > 100_000_000_000 ? n / 1000 : n)
        }
        if let s = v as? String {
            return isoFractional.date(from: s) ?? iso.date(from: s)
        }
        return nil
    }

    static func firstNumber(_ d: [String: Any], _ keys: [String]) -> Double? {
        for k in keys { if let n = number(d[k]) { return n } }
        return nil
    }

    /// Total UTF-8 length of all string values, skipping ids and duplicated rich-text trees.
    /// Used as a schema-agnostic proxy for "how much text does this thread re-send every turn".
    static func textLength(_ v: Any, depth: Int = 0) -> Int {
        if depth > 10 { return 0 }
        if let s = v as? String { return s.utf8.count }
        if let d = v as? [String: Any] {
            var total = 0
            for (k, value) in d where !skipForLength(k) { total += textLength(value, depth: depth + 1) }
            return total
        }
        if let a = v as? [Any] {
            return a.reduce(0) { $0 + textLength($1, depth: depth + 1) }
        }
        return 0
    }

    private static func skipForLength(_ key: String) -> Bool {
        let k = key.lowercased()
        return k == "richtext" || k == "codeblocks" || k.hasSuffix("id") || k.hasSuffix("ids") || k.hasSuffix("uuid")
    }

    /// First `{ ... }` object inside free text (LLM replies sometimes wrap JSON in prose or fences).
    static func extractObject(_ text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return obj(String(text[start...end]))
    }

    private static let iso: ISO8601DateFormatter = ISO8601DateFormatter()
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

public struct GoldieError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

extension String {
    func clipped(_ max: Int) -> String {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count <= max ? t : String(t.prefix(max)) + "…"
    }
}
