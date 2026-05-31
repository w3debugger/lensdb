import Foundation

/// A minimal JSON value that preserves object key order (so column order from
/// `row_to_json` is faithful) and keeps numbers as raw text (so big integers
/// and exact decimals aren't lossily coerced to Double — important for a DB
/// browser where IDs and money values must render exactly).
enum JSONValue {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([JSONValue])
    case object([(String, JSONValue)])

    /// Value to show in a cell. `nil` represents a SQL NULL.
    var displayString: String? {
        switch self {
        case .null: return nil
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n
        case .string(let s): return s
        case .array, .object: return compactJSON
        }
    }

    var objectPairs: [(String, JSONValue)]? {
        if case .object(let pairs) = self { return pairs }
        return nil
    }

    var compactJSON: String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n
        case .string(let s): return JSONValue.encode(string: s)
        case .array(let items):
            return "[" + items.map(\.compactJSON).joined(separator: ",") + "]"
        case .object(let pairs):
            return "{" + pairs.map { JSONValue.encode(string: $0.0) + ":" + $0.1.compactJSON }.joined(separator: ",") + "}"
        }
    }

    static func encode(string: String) -> String {
        var out = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}

/// A small recursive-descent JSON parser. We use it instead of
/// `JSONSerialization` because we need ordered object keys and lossless numbers.
struct JSONParser {
    private let chars: [Character]
    private var pos = 0

    private init(_ text: String) { chars = Array(text) }

    enum ParseError: Error { case unexpected }

    /// Parse a single JSON value from one line of psql output. Returns nil on failure.
    static func parseLine(_ line: String) -> JSONValue? {
        var parser = JSONParser(line)
        parser.skipWhitespace()
        guard let value = try? parser.parseValue() else { return nil }
        return value
    }

    private mutating func skipWhitespace() {
        while pos < chars.count {
            switch chars[pos] {
            case " ", "\n", "\t", "\r": pos += 1
            default: return
            }
        }
    }

    private func peek() -> Character? { pos < chars.count ? chars[pos] : nil }

    private mutating func expect(_ ch: Character) throws {
        guard pos < chars.count, chars[pos] == ch else { throw ParseError.unexpected }
        pos += 1
    }

    private mutating func parseValue() throws -> JSONValue {
        skipWhitespace()
        guard let c = peek() else { throw ParseError.unexpected }
        switch c {
        case "{": return try parseObject()
        case "[": return try parseArray()
        case "\"": return .string(try parseString())
        case "t", "f": return try parseBool()
        case "n": return try parseNull()
        default: return try parseNumber()
        }
    }

    private mutating func parseObject() throws -> JSONValue {
        try expect("{")
        var pairs: [(String, JSONValue)] = []
        skipWhitespace()
        if peek() == "}" { pos += 1; return .object(pairs) }
        while true {
            skipWhitespace()
            let key = try parseString()
            skipWhitespace()
            try expect(":")
            let value = try parseValue()
            pairs.append((key, value))
            skipWhitespace()
            guard let c = peek() else { throw ParseError.unexpected }
            if c == "," { pos += 1; continue }
            if c == "}" { pos += 1; break }
            throw ParseError.unexpected
        }
        return .object(pairs)
    }

    private mutating func parseArray() throws -> JSONValue {
        try expect("[")
        var items: [JSONValue] = []
        skipWhitespace()
        if peek() == "]" { pos += 1; return .array(items) }
        while true {
            items.append(try parseValue())
            skipWhitespace()
            guard let c = peek() else { throw ParseError.unexpected }
            if c == "," { pos += 1; continue }
            if c == "]" { pos += 1; break }
            throw ParseError.unexpected
        }
        return .array(items)
    }

    private mutating func parseString() throws -> String {
        try expect("\"")
        var out = ""
        while pos < chars.count {
            let c = chars[pos]; pos += 1
            if c == "\"" { return out }
            if c == "\\" {
                guard pos < chars.count else { throw ParseError.unexpected }
                let esc = chars[pos]; pos += 1
                switch esc {
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "/": out.append("/")
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "b": out.append("\u{08}")
                case "f": out.append("\u{0C}")
                case "u": out.unicodeScalars.append(contentsOf: try parseUnicodeEscape())
                default: throw ParseError.unexpected
                }
            } else {
                out.append(c)
            }
        }
        throw ParseError.unexpected
    }

    private mutating func parseUnicodeEscape() throws -> [Unicode.Scalar] {
        guard pos + 4 <= chars.count, let code = UInt32(String(chars[pos..<pos+4]), radix: 16) else {
            throw ParseError.unexpected
        }
        pos += 4
        // Combine a UTF-16 surrogate pair if present.
        if code >= 0xD800 && code <= 0xDBFF,
           pos + 6 <= chars.count, chars[pos] == "\\", chars[pos + 1] == "u",
           let low = UInt32(String(chars[pos + 2..<pos + 6]), radix: 16),
           low >= 0xDC00 && low <= 0xDFFF {
            pos += 6
            let combined = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
            if let scalar = Unicode.Scalar(combined) { return [scalar] }
            return []
        }
        if let scalar = Unicode.Scalar(code) { return [scalar] }
        return []
    }

    private mutating func parseNumber() throws -> JSONValue {
        let start = pos
        while pos < chars.count {
            switch chars[pos] {
            case "0"..."9", "-", "+", ".", "e", "E": pos += 1
            default:
                guard pos > start else { throw ParseError.unexpected }
                return .number(String(chars[start..<pos]))
            }
        }
        guard pos > start else { throw ParseError.unexpected }
        return .number(String(chars[start..<pos]))
    }

    private mutating func parseBool() throws -> JSONValue {
        if consume("true") { return .bool(true) }
        if consume("false") { return .bool(false) }
        throw ParseError.unexpected
    }

    private mutating func parseNull() throws -> JSONValue {
        if consume("null") { return .null }
        throw ParseError.unexpected
    }

    private mutating func consume(_ literal: String) -> Bool {
        let arr = Array(literal)
        guard pos + arr.count <= chars.count else { return false }
        for k in 0..<arr.count where chars[pos + k] != arr[k] { return false }
        pos += arr.count
        return true
    }
}
