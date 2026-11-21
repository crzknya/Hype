import Foundation
import P256K

public struct HLSignature: Equatable {
    public let r: [UInt8]
    public let s: [UInt8]
    public let v: Int

    public init(r: [UInt8], s: [UInt8], v: Int) {
        self.r = r; self.s = s; self.v = v
    }

    /// Parses a 65-byte r||s||v hex signature as returned by wallets (v may be 0/1 or 27/28).
    public init?(hex: String) {
        guard let b = Hex.decode(hex), b.count == 65 else { return nil }
        var v = Int(b[64])
        if v < 27 { v += 27 }
        self.init(r: Array(b[0..<32]), s: Array(b[32..<64]), v: v)
    }

    public var mp: MP {
        .map([("r", .str(Hex.encode(r))), ("s", .str(Hex.encode(s))), ("v", .int(Int64(v)))])
    }
}

public enum WalletError: Error, LocalizedError {
    case invalidPrivateKey
    public var errorDescription: String? { "Invalid private key (expected 64 hex characters)" }
}

/// An Ethereum-style secp256k1 key (signing is done by libsecp256k1).
public struct HLWallet {
    private let key: P256K.Recovery.PrivateKey
    /// Lowercase 0x-prefixed address.
    public let address: String

    public init(privateKeyHex: String) throws {
        guard let bytes = Hex.decode(privateKeyHex), bytes.count == 32 else { throw WalletError.invalidPrivateKey }
        do {
            key = try P256K.Recovery.PrivateKey(dataRepresentation: bytes, format: .uncompressed)
        } catch {
            throw WalletError.invalidPrivateKey
        }
        let pub = [UInt8](key.publicKey.dataRepresentation)
        address = HLWallet.address(fromUncompressedPublicKey: pub)
    }

    /// Generates a fresh random key (used for creating API/agent wallets).
    public static func generate() throws -> (wallet: HLWallet, privateKeyHex: String) {
        let k = try P256K.Recovery.PrivateKey(format: .uncompressed)
        let hex = Hex.encode([UInt8](k.dataRepresentation))
        return (try HLWallet(privateKeyHex: hex), hex)
    }

    public static func address(fromUncompressedPublicKey pub: [UInt8]) -> String {
        let body = pub.count == 65 ? Array(pub.dropFirst()) : pub
        return Hex.encode(Array(Keccak.hash256(body).suffix(20)))
    }

    /// Signs a 32-byte digest, returning a low-S Ethereum signature with v in {27, 28}.
    public func sign(digest: [UInt8]) -> HLSignature {
        precondition(digest.count == 32)
        let sig = key.signature(for: HashDigest(digest))
        let compact = sig.compactRepresentation
        let raw = [UInt8](compact.signature)
        return HLSignature(r: Array(raw[0..<32]), s: Array(raw[32..<64]), v: 27 + Int(compact.recoveryId))
    }
}

public extension HLSignature {
    /// Address that produced this signature over `digest`, or nil if the signature is malformed.
    func recoverAddress(digest: [UInt8]) -> String? {
        guard digest.count == 32, r.count == 32, s.count == 32, v == 27 || v == 28,
              r.contains(where: { $0 != 0 }), s.contains(where: { $0 != 0 }),
              let sig = try? P256K.Recovery.ECDSASignature(compactRepresentation: Data(r + s), recoveryId: Int32(v - 27))
        else { return nil }
        let pub = P256K.Recovery.PublicKey(HashDigest(digest), signature: sig, format: .uncompressed)
        return HLWallet.address(fromUncompressedPublicKey: [UInt8](pub.dataRepresentation))
    }
}

public enum Address {
    public static func isValid(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("0x"), t.count == 42, let b = Hex.decode(t) else { return false }
        return b.count == 20
    }

    /// EIP-55 mixed-case checksum representation.
    public static func checksum(_ address: String) -> String {
        let lower = address.lowercased().replacingOccurrences(of: "0x", with: "")
        let hash = Hex.encode(Keccak.hash256(lower), prefix: false)
        var out = "0x"
        for (c, h) in zip(lower, hash) {
            if c.isLetter, let n = Int(String(h), radix: 16), n >= 8 { out += c.uppercased() } else { out.append(c) }
        }
        return out
    }

    public static func short(_ address: String) -> String {
        guard address.count > 12 else { return address }
        return String(address.prefix(6)) + "…" + String(address.suffix(4))
    }
}
