import Foundation

/// Tolerant dynamic JSON value. Hyperliquid encodes most numbers as strings; `.double`
/// transparently parses both.
public enum JSON: Decodable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let d = try? c.decode(Double.self) { self = .number(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSON].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON") }
    }

    public static func parse(_ data: Data) throws -> JSON { try JSONDecoder().decode(JSON.self, from: data) }

    public subscript(key: String) -> JSON {
        if case .object(let o) = self { return o[key] ?? .null }
        return .null
    }

    public subscript(index: Int) -> JSON {
        if case .array(let a) = self, index >= 0, index < a.count { return a[index] }
        return .null
    }

    public var isNull: Bool { if case .null = self { return true }; return false }

    public var double: Double? {
        switch self {
        case .number(let d): return d
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    public var dbl: Double { double ?? 0 }

    public var int: Int? {
        switch self {
        case .number(let d): return Int(exactly: d.rounded()) ?? Int(d)
        case .string(let s): return Int(s) ?? Double(s).map { Int($0) }
        default: return nil
        }
    }

    public var int64: Int64? {
        switch self {
        case .number(let d): return Int64(d)
        case .string(let s): return Int64(s)
        default: return nil
        }
    }

    public var string: String? {
        switch self {
        case .string(let s): return s
        case .number(let d): return d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    public var str: String { string ?? "" }

    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }

    public var array: [JSON] { if case .array(let a) = self { return a }; return [] }

    public var object: [String: JSON] { if case .object(let o) = self { return o }; return [:] }
}
