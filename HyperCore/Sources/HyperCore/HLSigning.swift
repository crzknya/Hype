import Foundation

public enum HLSigning {
    public static let userSignChainId: UInt64 = 0x66eee
    public static let userSignChainIdHex = "0x66eee"

    public static func hex(_ chainId: UInt64) -> String { "0x" + String(chainId, radix: 16) }

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

    /// Phantom-agent digest for an arbitrary connection id (signed info requests such as userPoints).
    public static func agentDigest(connectionId: [UInt8], isMainnet: Bool) -> [UInt8] {
        let domain = EIP712.domainSeparator(name: "Exchange", version: "1", chainId: 1337)
        let s = EIP712.structHash("Agent",
                                  [EIP712.Field("source", "string"), EIP712.Field("connectionId", "bytes32")],
                                  ["source": .string(isMainnet ? "a" : "b"), "connectionId": .bytes32(connectionId)])
        return EIP712.digest(domainSeparator: domain, structHash: s)
    }

    /// keccak256(abi.encode(string "userPoints", uint64 timestamp)) — the web app's userPoints auth.
    public static func userPointsConnectionId(timestamp: UInt64) -> [UInt8] {
        func word(_ v: UInt64) -> [UInt8] {
            [UInt8](repeating: 0, count: 24) + (0..<8).reversed().map { UInt8(truncatingIfNeeded: v >> UInt64($0 * 8)) }
        }
        let text = Array("userPoints".utf8)
        var padded = text
        padded += [UInt8](repeating: 0, count: (32 - text.count % 32) % 32)
        let data = word(0x40) + word(timestamp) + word(UInt64(text.count)) + padded
        return Keccak.hash256(data)
    }

    public static func userSignedDigest(_ a: UserSignedAction) -> [UInt8] {
        let domain = EIP712.domainSeparator(name: "HyperliquidSignTransaction", version: "1", chainId: a.chainId)
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
    /// EIP-712 domain chain id (the chain the signing wallet is on; Hyperliquid accepts any).
    public var chainId: UInt64 = HLSigning.userSignChainId

    public init(action: MP, primaryType: String, fields: [EIP712.Field], values: [String: EIP712.Value],
                nonce: UInt64, chainId: UInt64 = HLSigning.userSignChainId) {
        self.action = action; self.primaryType = primaryType; self.fields = fields
        self.values = values; self.nonce = nonce; self.chainId = chainId
    }

    /// EIP-712 typed data JSON for `eth_signTypedData_v4` in an external wallet.
    public func typedDataJSON() -> String {
        func typeList(_ fs: [EIP712.Field]) -> MP {
            .arr(fs.map { .map([("name", .str($0.name)), ("type", .str($0.type))]) })
        }
        let domainFields = [EIP712.Field("name", "string"), EIP712.Field("version", "string"),
                            EIP712.Field("chainId", "uint256"), EIP712.Field("verifyingContract", "address")]
        var message: [(String, MP)] = []
        for f in fields {
            switch values[f.name] {
            case .string(let s)?: message.append((f.name, .str(s)))
            case .address(let a)?: message.append((f.name, .str(a)))
            case .uint(let u)?: message.append((f.name, .int(Int64(u))))
            case .bool(let b)?: message.append((f.name, .bool(b)))
            case .bytes32(let b)?: message.append((f.name, .str(Hex.encode(b))))
            case .bytes(let b)?: message.append((f.name, .str(Hex.encode(b))))
            case nil: break
            }
        }
        let root = MP.map([
            ("types", .map([("EIP712Domain", typeList(domainFields)), (primaryType, typeList(fields))])),
            ("primaryType", .str(primaryType)),
            ("domain", .map([("name", .str("HyperliquidSignTransaction")), ("version", .str("1")),
                             ("chainId", .int(Int64(chainId))),
                             ("verifyingContract", .str("0x0000000000000000000000000000000000000000"))])),
            ("message", .map(message)),
        ])
        return root.json()
    }
}
