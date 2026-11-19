import Foundation

/// Keccak-256 (the original Keccak padding used by Ethereum, not NIST SHA3-256).
public enum Keccak {
    private static let rc: [UInt64] = [
        0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
        0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
        0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
        0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
        0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
        0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
    ]
    private static let rotc: [UInt64] = [1, 3, 6, 10, 15, 21, 28, 36, 45, 55, 2, 14, 27, 41, 56, 8, 25, 43, 62, 18, 39, 61, 20, 44]
    private static let piln: [Int] = [10, 7, 11, 17, 18, 3, 5, 16, 8, 21, 24, 4, 15, 23, 19, 13, 12, 2, 20, 14, 22, 9, 6, 1]

    @inline(__always) private static func rotl(_ x: UInt64, _ n: UInt64) -> UInt64 { (x << n) | (x >> (64 - n)) }

    private static func permute(_ st: inout [UInt64]) {
        var bc = [UInt64](repeating: 0, count: 5)
        for round in 0..<24 {
            for i in 0..<5 { bc[i] = st[i] ^ st[i + 5] ^ st[i + 10] ^ st[i + 15] ^ st[i + 20] }
            for i in 0..<5 {
                let t = bc[(i + 4) % 5] ^ rotl(bc[(i + 1) % 5], 1)
                for j in stride(from: 0, to: 25, by: 5) { st[j + i] ^= t }
            }
            var t = st[1]
            for i in 0..<24 {
                let j = piln[i]
                let tmp = st[j]
                st[j] = rotl(t, rotc[i])
                t = tmp
            }
            for j in stride(from: 0, to: 25, by: 5) {
                for i in 0..<5 { bc[i] = st[j + i] }
                for i in 0..<5 { st[j + i] ^= (~bc[(i + 1) % 5]) & bc[(i + 2) % 5] }
            }
            st[0] ^= rc[round]
        }
    }

    public static func hash256(_ data: [UInt8]) -> [UInt8] {
        let rate = 136
        var st = [UInt64](repeating: 0, count: 25)
        var msg = data
        msg.append(0x01)
        while msg.count % rate != 0 { msg.append(0) }
        msg[msg.count - 1] |= 0x80
        var offset = 0
        while offset < msg.count {
            for i in 0..<(rate / 8) {
                var lane: UInt64 = 0
                for k in 0..<8 { lane |= UInt64(msg[offset + i * 8 + k]) << UInt64(8 * k) }
                st[i] ^= lane
            }
            permute(&st)
            offset += rate
        }
        var out = [UInt8]()
        out.reserveCapacity(32)
        for i in 0..<4 {
            for k in 0..<8 { out.append(UInt8(truncatingIfNeeded: st[i] >> UInt64(8 * k))) }
        }
        return out
    }

    public static func hash256(_ string: String) -> [UInt8] { hash256(Array(string.utf8)) }
}
