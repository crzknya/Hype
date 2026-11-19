import Foundation

/// An ordered value tree that can be serialized both to MessagePack (byte-exact with the
/// Python `msgpack.packb` used by Hyperliquid for action hashing) and to JSON for posting.
public indirect enum MP {
    case null
    case bool(Bool)
    case int(Int64)
    case str(String)
    case arr([MP])
    case map([(String, MP)])

    public subscript(key: String) -> MP? {
        if case .map(let kv) = self { return kv.first(where: { $0.0 == key })?.1 }
        return nil
    }

    // MARK: MessagePack

    public func pack() -> [UInt8] {
        var out = [UInt8]()
        pack(into: &out)
        return out
    }

    private func pack(into out: inout [UInt8]) {
        switch self {
        case .null:
            out.append(0xc0)
        case .bool(let b):
            out.append(b ? 0xc3 : 0xc2)
        case .int(let v):
            if v >= 0 {
                let u = UInt64(v)
                if u < 0x80 { out.append(UInt8(u)) }
                else if u <= 0xff { out.append(0xcc); out.append(UInt8(u)) }
                else if u <= 0xffff { out.append(0xcd); MP.be(u, 2, &out) }
                else if u <= 0xffff_ffff { out.append(0xce); MP.be(u, 4, &out) }
                else { out.append(0xcf); MP.be(u, 8, &out) }
            } else {
                if v >= -32 { out.append(UInt8(bitPattern: Int8(v))) }
                else if v >= -128 { out.append(0xd0); out.append(UInt8(bitPattern: Int8(v))) }
                else if v >= -32768 { out.append(0xd1); MP.be(UInt64(bitPattern: v), 2, &out) }
                else if v >= -2_147_483_648 { out.append(0xd2); MP.be(UInt64(bitPattern: v), 4, &out) }
                else { out.append(0xd3); MP.be(UInt64(bitPattern: v), 8, &out) }
            }
        case .str(let s):
            let bytes = Array(s.utf8)
            let n = bytes.count
            if n < 32 { out.append(0xa0 | UInt8(n)) }
            else if n <= 0xff { out.append(0xd9); out.append(UInt8(n)) }
            else if n <= 0xffff { out.append(0xda); MP.be(UInt64(n), 2, &out) }
            else { out.append(0xdb); MP.be(UInt64(n), 4, &out) }
            out.append(contentsOf: bytes)
        case .arr(let items):
            let n = items.count
            if n < 16 { out.append(0x90 | UInt8(n)) }
            else if n <= 0xffff { out.append(0xdc); MP.be(UInt64(n), 2, &out) }
            else { out.append(0xdd); MP.be(UInt64(n), 4, &out) }
            for i in items { i.pack(into: &out) }
        case .map(let kv):
            let n = kv.count
            if n < 16 { out.append(0x80 | UInt8(n)) }
            else if n <= 0xffff { out.append(0xde); MP.be(UInt64(n), 2, &out) }
            else { out.append(0xdf); MP.be(UInt64(n), 4, &out) }
            for (k, v) in kv {
                MP.str(k).pack(into: &out)
                v.pack(into: &out)
            }
        }
    }

    private static func be(_ v: UInt64, _ bytes: Int, _ out: inout [UInt8]) {
        for i in stride(from: bytes - 1, through: 0, by: -1) {
            out.append(UInt8(truncatingIfNeeded: v >> UInt64(8 * i)))
        }
    }

    // MARK: JSON

    public func json() -> String {
        var s = ""
        json(into: &s)
        return s
    }

    private func json(into s: inout String) {
        switch self {
        case .null: s += "null"
        case .bool(let b): s += b ? "true" : "false"
        case .int(let v): s += String(v)
        case .str(let str): MP.escape(str, into: &s)
        case .arr(let items):
            s += "["
            for (i, item) in items.enumerated() {
                if i > 0 { s += "," }
                item.json(into: &s)
            }
            s += "]"
        case .map(let kv):
            s += "{"
            for (i, (k, v)) in kv.enumerated() {
                if i > 0 { s += "," }
                MP.escape(k, into: &s)
                s += ":"
                v.json(into: &s)
            }
            s += "}"
        }
    }

    private static func escape(_ str: String, into s: inout String) {
        s += "\""
        for u in str.unicodeScalars {
            switch u {
            case "\"": s += "\\\""
            case "\\": s += "\\\\"
            case "\n": s += "\\n"
            case "\r": s += "\\r"
            case "\t": s += "\\t"
            default:
                if u.value < 0x20 {
                    s += String(format: "\\u%04x", u.value)
                } else {
                    s.unicodeScalars.append(u)
                }
            }
        }
        s += "\""
    }
}
