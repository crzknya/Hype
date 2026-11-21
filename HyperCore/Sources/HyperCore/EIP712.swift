import Foundation

/// Just enough EIP-712 for Hyperliquid's flat (non-nested) typed messages.
public enum EIP712 {
    public enum Value {
        case string(String)
        case bytes32([UInt8])
        case bytes([UInt8])          // dynamic `bytes`: encoded as keccak256(bytes)
        case uint(UInt64)
        case bool(Bool)
        case address(String)
    }

    public struct Field {
        public let name: String
        public let type: String
        public init(_ name: String, _ type: String) { self.name = name; self.type = type }
    }

    public static func typeHash(_ primaryType: String, _ fields: [Field]) -> [UInt8] {
        let sig = primaryType + "(" + fields.map { "\($0.type) \($0.name)" }.joined(separator: ",") + ")"
        return Keccak.hash256(sig)
    }

    static func word(_ v: UInt64) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 24)
        for i in stride(from: 56, through: 0, by: -8) { out.append(UInt8(truncatingIfNeeded: v >> UInt64(i))) }
        return out
    }

    public static func encode(_ value: Value) -> [UInt8] {
        switch value {
        case .string(let s): return Keccak.hash256(s)
        case .bytes32(let b):
            precondition(b.count == 32)
            return b
        case .bytes(let b): return Keccak.hash256(b)
        case .uint(let v): return word(v)
        case .bool(let b): return word(b ? 1 : 0)
        case .address(let a):
            let bytes = Hex.decode(a) ?? []
            return [UInt8](repeating: 0, count: 32 - min(32, bytes.count)) + bytes.suffix(32)
        }
    }

    public static func structHash(_ primaryType: String, _ fields: [Field], _ values: [String: Value]) -> [UInt8] {
        var data = typeHash(primaryType, fields)
        for f in fields {
            guard let v = values[f.name] else { preconditionFailure("missing EIP-712 field \(f.name)") }
            data += encode(v)
        }
        return Keccak.hash256(data)
    }

    public static func domainSeparator(name: String, version: String, chainId: UInt64,
                                       verifyingContract: String = "0x0000000000000000000000000000000000000000") -> [UInt8] {
        structHash("EIP712Domain",
                   [Field("name", "string"), Field("version", "string"), Field("chainId", "uint256"), Field("verifyingContract", "address")],
                   ["name": .string(name), "version": .string(version), "chainId": .uint(chainId), "verifyingContract": .address(verifyingContract)])
    }

    public static func digest(domainSeparator: [UInt8], structHash: [UInt8]) -> [UInt8] {
        Keccak.hash256([0x19, 0x01] + domainSeparator + structHash)
    }
}
