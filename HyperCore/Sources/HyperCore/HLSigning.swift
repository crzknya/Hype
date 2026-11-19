import Foundation

public enum HLSigning {
    public static let userSignChainId: UInt64 = 0x66eee
    public static let userSignChainIdHex = "0x66eee"

    /// keccak(msgpack(action) || nonce_be64 || vault flag/addr || [0x00 || expiresAfter_be64])
    public static func actionHash(_ action: MP, vault: String?, nonce: UInt64, expiresAfter: UInt64?) -> [UInt8] {
        var data = action.pack()
        data += be64(nonce)
        if let vault, let bytes = Hex.decode(vault) {
            data.append(0x01)
            data += bytes
        } else {
            data.append(0x00)
        }
        if let expiresAfter {
            data.append(0x00)
            data += be64(expiresAfter)
        }
        return Keccak.hash256(data)
    }

    public static func l1Digest(_ action: MP, vault: String?, nonce: UInt64, expiresAfter: UInt64?, isMainnet: Bool) -> [UInt8] {
        let hash = actionHash(action, vault: vault, nonce: nonce, expiresAfter: expiresAfter)
        let domain = EIP712.domainSeparator(name: "Exchange", version: "1", chainId: 1337)
        let s = EIP712.structHash("Agent",
                                  [EIP712.Field("source", "string"), EIP712.Field("connectionId", "bytes32")],
                                  ["source": .string(isMainnet ? "a" : "b"), "connectionId": .bytes32(hash)])
        return EIP712.digest(domainSeparator: domain, structHash: s)
    }

    public static func userSignedDigest(_ a: UserSignedAction) -> [UInt8] {
        let domain = EIP712.domainSeparator(name: "HyperliquidSignTransaction", version: "1", chainId: userSignChainId)
        return EIP712.digest(domainSeparator: domain, structHash: EIP712.structHash(a.primaryType, a.fields, a.values))
    }

    static func be64(_ v: UInt64) -> [UInt8] {
        (0..<8).reversed().map { UInt8(truncatingIfNeeded: v >> UInt64($0 * 8)) }
    }
}

/// A user-signed action (transfers, withdrawals, agent approval): signed with EIP-712 directly.
public struct UserSignedAction {
    public let action: MP
    public let primaryType: String
    public let fields: [EIP712.Field]
    public let values: [String: EIP712.Value]
    public let nonce: UInt64
}
