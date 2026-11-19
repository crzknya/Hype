import Foundation

public enum Hex {
    /// Decodes a hex string (with or without 0x prefix). Returns nil on invalid input.
    public static func decode(_ string: String) -> [UInt8]? {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("0x") || s.hasPrefix("0X") { s.removeFirst(2) }
        if s.count % 2 == 1 { s = "0" + s }
        var out = [UInt8]()
        out.reserveCapacity(s.count / 2)
        var it = s.unicodeScalars.makeIterator()
        while let a = it.next(), let b = it.next() {
            guard let hi = nibble(a), let lo = nibble(b) else { return nil }
            out.append(hi << 4 | lo)
        }
        return out
    }

    public static func encode(_ bytes: [UInt8], prefix: Bool = true) -> String {
        let table: [Character] = Array("0123456789abcdef")
        var s = prefix ? "0x" : ""
        s.reserveCapacity(s.count + bytes.count * 2)
        for b in bytes {
            s.append(table[Int(b >> 4)])
            s.append(table[Int(b & 0x0f)])
        }
        return s
    }

    private static func nibble(_ c: Unicode.Scalar) -> UInt8? {
        switch c.value {
        case 48...57: return UInt8(c.value - 48)
        case 65...70: return UInt8(c.value - 55)
        case 97...102: return UInt8(c.value - 87)
        default: return nil
        }
    }
}
