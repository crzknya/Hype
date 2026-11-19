import Foundation

/// Minimal unsigned 256-bit integer (4 little-endian 64-bit limbs) for secp256k1 math.
public struct U256: Equatable, Comparable, CustomStringConvertible {
    public var l0: UInt64, l1: UInt64, l2: UInt64, l3: UInt64

    public init(_ l0: UInt64, _ l1: UInt64, _ l2: UInt64, _ l3: UInt64) {
        self.l0 = l0; self.l1 = l1; self.l2 = l2; self.l3 = l3
    }

    public init(_ v: UInt64) { self.init(v, 0, 0, 0) }

    public static let zero = U256(0)
    public static let one = U256(1)

    /// Big-endian bytes (up to 32; shorter input is left-padded).
    public init(bytes: [UInt8]) {
        precondition(bytes.count <= 32)
        var padded = [UInt8](repeating: 0, count: 32 - bytes.count) + bytes
        func limb(_ i: Int) -> UInt64 {
            var v: UInt64 = 0
            for k in 0..<8 { v = v << 8 | UInt64(padded[i * 8 + k]) }
            return v
        }
        self.init(limb(3), limb(2), limb(1), limb(0))
        padded.removeAll()
    }

    public init?(hex: String) {
        guard let b = Hex.decode(hex), b.count <= 32 else { return nil }
        self.init(bytes: b)
    }

    public var bytes: [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(32)
        for limb in [l3, l2, l1, l0] {
            for k in stride(from: 56, through: 0, by: -8) { out.append(UInt8(truncatingIfNeeded: limb >> UInt64(k))) }
        }
        return out
    }

    public var description: String { Hex.encode(bytes) }

    public var isZero: Bool { (l0 | l1 | l2 | l3) == 0 }
    public var isOdd: Bool { l0 & 1 == 1 }

    @inline(__always) func limb(_ i: Int) -> UInt64 {
        switch i { case 0: return l0; case 1: return l1; case 2: return l2; default: return l3 }
    }

    public func bit(_ i: Int) -> Bool { (limb(i / 64) >> UInt64(i % 64)) & 1 == 1 }

    public static func < (a: U256, b: U256) -> Bool {
        if a.l3 != b.l3 { return a.l3 < b.l3 }
        if a.l2 != b.l2 { return a.l2 < b.l2 }
        if a.l1 != b.l1 { return a.l1 < b.l1 }
        return a.l0 < b.l0
    }

    /// Returns (a + b mod 2^256, carry).
    public static func add(_ a: U256, _ b: U256) -> (U256, Bool) {
        var c: UInt64 = 0
        func step(_ x: UInt64, _ y: UInt64) -> UInt64 {
            let (s1, o1) = x.addingReportingOverflow(y)
            let (s2, o2) = s1.addingReportingOverflow(c)
            c = (o1 ? 1 : 0) + (o2 ? 1 : 0)
            return s2
        }
        let r0 = step(a.l0, b.l0), r1 = step(a.l1, b.l1), r2 = step(a.l2, b.l2), r3 = step(a.l3, b.l3)
        return (U256(r0, r1, r2, r3), c != 0)
    }

    /// Returns (a - b mod 2^256, borrow).
    public static func sub(_ a: U256, _ b: U256) -> (U256, Bool) {
        var br: UInt64 = 0
        func step(_ x: UInt64, _ y: UInt64) -> UInt64 {
            let (d1, o1) = x.subtractingReportingOverflow(y)
            let (d2, o2) = d1.subtractingReportingOverflow(br)
            br = (o1 ? 1 : 0) + (o2 ? 1 : 0)
            return d2
        }
        let r0 = step(a.l0, b.l0), r1 = step(a.l1, b.l1), r2 = step(a.l2, b.l2), r3 = step(a.l3, b.l3)
        return (U256(r0, r1, r2, r3), br != 0)
    }

    /// Full 512-bit product, 8 little-endian limbs.
    public static func mulFull(_ a: U256, _ b: U256) -> [UInt64] {
        var r = [UInt64](repeating: 0, count: 8)
        let al = [a.l0, a.l1, a.l2, a.l3], bl = [b.l0, b.l1, b.l2, b.l3]
        for i in 0..<4 {
            var carry: UInt64 = 0
            for j in 0..<4 {
                let (hi, lo) = al[i].multipliedFullWidth(by: bl[j])
                let (s1, o1) = r[i + j].addingReportingOverflow(lo)
                let (s2, o2) = s1.addingReportingOverflow(carry)
                r[i + j] = s2
                carry = hi &+ (o1 ? 1 : 0) &+ (o2 ? 1 : 0)
            }
            r[i + 4] = carry
        }
        return r
    }
}

/// Arithmetic modulo m where m = 2^256 - c (true for both the secp256k1 field prime and group order).
public struct Modulus {
    public let m: U256
    public let c: U256

    public init(_ m: U256) {
        self.m = m
        self.c = U256.sub(.zero, m).0
    }

    public func reduce(_ a: U256) -> U256 {
        var x = a
        while x >= m { x = U256.sub(x, m).0 }
        return x
    }

    public func reduceWide(_ w: [UInt64]) -> U256 {
        var lo = U256(w[0], w[1], w[2], w[3])
        var hi = U256(w[4], w[5], w[6], w[7])
        while !hi.isZero {
            let p = U256.mulFull(hi, c)
            let plo = U256(p[0], p[1], p[2], p[3])
            let (sum, carry) = U256.add(plo, lo)
            lo = sum
            hi = U256(p[4], p[5], p[6], p[7])
            if carry { hi = U256.add(hi, .one).0 }
        }
        return reduce(lo)
    }

    public func add(_ a: U256, _ b: U256) -> U256 {
        let (s, carry) = U256.add(a, b)
        if carry || s >= m { return U256.sub(s, m).0 }
        return s
    }

    public func sub(_ a: U256, _ b: U256) -> U256 {
        let (d, borrow) = U256.sub(a, b)
        if borrow { return U256.add(d, m).0 }
        return d
    }

    public func neg(_ a: U256) -> U256 { a.isZero ? a : U256.sub(m, a).0 }

    public func mul(_ a: U256, _ b: U256) -> U256 { reduceWide(U256.mulFull(a, b)) }

    public func sqr(_ a: U256) -> U256 { mul(a, a) }

    public func pow(_ a: U256, _ e: U256) -> U256 {
        var result = U256.one
        var started = false
        for i in stride(from: 255, through: 0, by: -1) {
            if started { result = sqr(result) }
            if e.bit(i) {
                result = started ? mul(result, a) : a
                started = true
            }
        }
        return started ? result : .one
    }

    /// Modular inverse via Fermat's little theorem (m is prime).
    public func inv(_ a: U256) -> U256 { pow(a, U256.sub(m, U256(2)).0) }
}
