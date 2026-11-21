import Foundation

public enum TIF: String, CaseIterable, Identifiable {
    case gtc = "Gtc", ioc = "Ioc", alo = "Alo"
    public var id: String { rawValue }
}

public enum OrderKind {
    case limit(tif: TIF)
    case trigger(triggerPx: String, isMarket: Bool, tpsl: TPSL)
}

public enum TPSL: String { case tp, sl }

public enum Grouping: String { case na, normalTpsl, positionTpsl }

public struct OrderWire {
    public var asset: Int
    public var isBuy: Bool
    public var limitPx: String
    public var sz: String
    public var reduceOnly: Bool
    public var kind: OrderKind
    public var cloid: String?

    public init(asset: Int, isBuy: Bool, limitPx: String, sz: String, reduceOnly: Bool, kind: OrderKind, cloid: String? = nil) {
        self.asset = asset; self.isBuy = isBuy; self.limitPx = limitPx; self.sz = sz
        self.reduceOnly = reduceOnly; self.kind = kind; self.cloid = cloid
    }

    public var mp: MP {
        let t: MP
        switch kind {
        case .limit(let tif):
            t = .map([("limit", .map([("tif", .str(tif.rawValue))]))])
        case .trigger(let px, let isMarket, let tpsl):
            t = .map([("trigger", .map([("isMarket", .bool(isMarket)), ("triggerPx", .str(px)), ("tpsl", .str(tpsl.rawValue))]))])
        }
        var kv: [(String, MP)] = [
            ("a", .int(Int64(asset))), ("b", .bool(isBuy)), ("p", .str(limitPx)),
            ("s", .str(sz)), ("r", .bool(reduceOnly)), ("t", t),
        ]
        if let cloid { kv.append(("c", .str(cloid))) }
        return .map(kv)
    }
}

/// Builders for exchange actions. Key order matters: it must match the canonical
/// Hyperliquid serialization because the action is msgpack-hashed.
public enum HLAction {
    // MARK: L1 actions (signed via phantom agent; can be signed by an API wallet)

    public static func order(_ orders: [OrderWire], grouping: Grouping = .na, builder: (address: String, fee: Int)? = nil) -> MP {
        var kv: [(String, MP)] = [("type", .str("order")), ("orders", .arr(orders.map(\.mp))), ("grouping", .str(grouping.rawValue))]
        if let builder { kv.append(("builder", .map([("b", .str(builder.address.lowercased())), ("f", .int(Int64(builder.fee)))]))) }
        return .map(kv)
    }

    public static func cancel(_ items: [(asset: Int, oid: Int64)]) -> MP {
        .map([("type", .str("cancel")),
              ("cancels", .arr(items.map { .map([("a", .int(Int64($0.asset))), ("o", .int($0.oid))]) }))])
    }

    public static func cancelByCloid(_ items: [(asset: Int, cloid: String)]) -> MP {
        .map([("type", .str("cancelByCloid")),
              ("cancels", .arr(items.map { .map([("asset", .int(Int64($0.asset))), ("cloid", .str($0.cloid))]) }))])
    }

    public static func modify(oid: Int64, order: OrderWire) -> MP {
        .map([("type", .str("modify")), ("oid", .int(oid)), ("order", order.mp)])
    }

    public static func batchModify(_ items: [(oid: Int64, order: OrderWire)]) -> MP {
        .map([("type", .str("batchModify")),
              ("modifies", .arr(items.map { .map([("oid", .int($0.oid)), ("order", $0.order.mp)]) }))])
    }

    public static func updateLeverage(asset: Int, isCross: Bool, leverage: Int) -> MP {
        .map([("type", .str("updateLeverage")), ("asset", .int(Int64(asset))), ("isCross", .bool(isCross)), ("leverage", .int(Int64(leverage)))])
    }

    /// ntli: USD amount * 1e6, positive to add margin, negative to remove.
    public static func updateIsolatedMargin(asset: Int, ntli: Int64) -> MP {
        .map([("type", .str("updateIsolatedMargin")), ("asset", .int(Int64(asset))), ("isBuy", .bool(true)), ("ntli", .int(ntli))])
    }

    public static func twapOrder(asset: Int, isBuy: Bool, sz: String, reduceOnly: Bool, minutes: Int, randomize: Bool) -> MP {
        .map([("type", .str("twapOrder")),
              ("twap", .map([("a", .int(Int64(asset))), ("b", .bool(isBuy)), ("s", .str(sz)), ("r", .bool(reduceOnly)),
                             ("m", .int(Int64(minutes))), ("t", .bool(randomize))]))])
    }

    public static func twapCancel(asset: Int, twapId: Int64) -> MP {
        .map([("type", .str("twapCancel")), ("a", .int(Int64(asset))), ("t", .int(twapId))])
    }

    /// Dead man's switch: cancels all orders at `time` (ms). nil clears the schedule.
    public static func scheduleCancel(time: UInt64?) -> MP {
        var kv: [(String, MP)] = [("type", .str("scheduleCancel"))]
        if let time { kv.append(("time", .int(Int64(time)))) }
        return .map(kv)
    }

    /// Sets a referral code for the account (the exchange may reject it, e.g. after the volume threshold).
    public static func setReferrer(code: String) -> MP {
        .map([("type", .str("setReferrer")), ("code", .str(code))])
    }

    public static func vaultTransfer(vault: String, isDeposit: Bool, usdMicros: Int64) -> MP {
        .map([("type", .str("vaultTransfer")), ("vaultAddress", .str(vault.lowercased())), ("isDeposit", .bool(isDeposit)), ("usd", .int(usdMicros))])
    }

    // MARK: User-signed actions (require the main wallet key)

    private static func chain(_ mainnet: Bool) -> String { mainnet ? "Mainnet" : "Testnet" }

    public static func usdSend(destination: String, amount: String, time: UInt64, mainnet: Bool,
                                 chainId: UInt64 = HLSigning.userSignChainId) -> UserSignedAction {
        let dest = destination.lowercased()
        return UserSignedAction(
            action: .map([("type", .str("usdSend")), ("signatureChainId", .str(HLSigning.hex(chainId))),
                          ("hyperliquidChain", .str(chain(mainnet))), ("destination", .str(dest)),
                          ("amount", .str(amount)), ("time", .int(Int64(time)))]),
            primaryType: "HyperliquidTransaction:UsdSend",
            fields: [.init("hyperliquidChain", "string"), .init("destination", "string"), .init("amount", "string"), .init("time", "uint64")],
            values: ["hyperliquidChain": .string(chain(mainnet)), "destination": .string(dest), "amount": .string(amount), "time": .uint(time)],
            nonce: time, chainId: chainId)
    }

    public static func withdraw(destination: String, amount: String, time: UInt64, mainnet: Bool,
                                 chainId: UInt64 = HLSigning.userSignChainId) -> UserSignedAction {
        let dest = destination.lowercased()
        return UserSignedAction(
            action: .map([("type", .str("withdraw3")), ("signatureChainId", .str(HLSigning.hex(chainId))),
                          ("hyperliquidChain", .str(chain(mainnet))), ("destination", .str(dest)),
                          ("amount", .str(amount)), ("time", .int(Int64(time)))]),
            primaryType: "HyperliquidTransaction:Withdraw",
            fields: [.init("hyperliquidChain", "string"), .init("destination", "string"), .init("amount", "string"), .init("time", "uint64")],
            values: ["hyperliquidChain": .string(chain(mainnet)), "destination": .string(dest), "amount": .string(amount), "time": .uint(time)],
            nonce: time, chainId: chainId)
    }

    /// token: "NAME:0xTOKENID"
    public static func spotSend(destination: String, token: String, amount: String, time: UInt64, mainnet: Bool,
                                 chainId: UInt64 = HLSigning.userSignChainId) -> UserSignedAction {
        let dest = destination.lowercased()
        return UserSignedAction(
            action: .map([("type", .str("spotSend")), ("signatureChainId", .str(HLSigning.hex(chainId))),
                          ("hyperliquidChain", .str(chain(mainnet))), ("destination", .str(dest)), ("token", .str(token)),
                          ("amount", .str(amount)), ("time", .int(Int64(time)))]),
            primaryType: "HyperliquidTransaction:SpotSend",
            fields: [.init("hyperliquidChain", "string"), .init("destination", "string"), .init("token", "string"), .init("amount", "string"), .init("time", "uint64")],
            values: ["hyperliquidChain": .string(chain(mainnet)), "destination": .string(dest), "token": .string(token),
                     "amount": .string(amount), "time": .uint(time)],
            nonce: time, chainId: chainId)
    }

    public static func usdClassTransfer(amount: String, toPerp: Bool, nonce: UInt64, mainnet: Bool,
                                 chainId: UInt64 = HLSigning.userSignChainId) -> UserSignedAction {
        UserSignedAction(
            action: .map([("type", .str("usdClassTransfer")), ("signatureChainId", .str(HLSigning.hex(chainId))),
                          ("hyperliquidChain", .str(chain(mainnet))), ("amount", .str(amount)), ("toPerp", .bool(toPerp)),
                          ("nonce", .int(Int64(nonce)))]),
            primaryType: "HyperliquidTransaction:UsdClassTransfer",
            fields: [.init("hyperliquidChain", "string"), .init("amount", "string"), .init("toPerp", "bool"), .init("nonce", "uint64")],
            values: ["hyperliquidChain": .string(chain(mainnet)), "amount": .string(amount), "toPerp": .bool(toPerp), "nonce": .uint(nonce)],
            nonce: nonce, chainId: chainId)
    }

    /// Moves collateral between perp dexes ("" = main perp dex, "spot" = spot, otherwise a HIP-3 dex name).
    /// token: "NAME:0xTOKENID" of the dex collateral token.
    public static func sendAsset(destination: String, sourceDex: String, destinationDex: String, token: String,
                                 amount: String, fromSubAccount: String, nonce: UInt64, mainnet: Bool,
                                 chainId: UInt64 = HLSigning.userSignChainId) -> UserSignedAction {
        let dest = destination.lowercased()
        let sub = fromSubAccount.lowercased()
        return UserSignedAction(
            action: .map([("type", .str("sendAsset")), ("signatureChainId", .str(HLSigning.hex(chainId))),
                          ("hyperliquidChain", .str(chain(mainnet))), ("destination", .str(dest)),
                          ("sourceDex", .str(sourceDex)), ("destinationDex", .str(destinationDex)), ("token", .str(token)),
                          ("amount", .str(amount)), ("fromSubAccount", .str(sub)), ("nonce", .int(Int64(nonce)))]),
            primaryType: "HyperliquidTransaction:SendAsset",
            fields: [.init("hyperliquidChain", "string"), .init("destination", "string"), .init("sourceDex", "string"),
                     .init("destinationDex", "string"), .init("token", "string"), .init("amount", "string"),
                     .init("fromSubAccount", "string"), .init("nonce", "uint64")],
            values: ["hyperliquidChain": .string(chain(mainnet)), "destination": .string(dest), "sourceDex": .string(sourceDex),
                     "destinationDex": .string(destinationDex), "token": .string(token), "amount": .string(amount),
                     "fromSubAccount": .string(sub), "nonce": .uint(nonce)],
            nonce: nonce, chainId: chainId)
    }

    public static func approveAgent(agentAddress: String, agentName: String, nonce: UInt64, mainnet: Bool,
                                 chainId: UInt64 = HLSigning.userSignChainId) -> UserSignedAction {
        let agent = agentAddress.lowercased()
        return UserSignedAction(
            action: .map([("type", .str("approveAgent")), ("signatureChainId", .str(HLSigning.hex(chainId))),
                          ("hyperliquidChain", .str(chain(mainnet))), ("agentAddress", .str(agent)),
                          ("agentName", .str(agentName)), ("nonce", .int(Int64(nonce)))]),
            primaryType: "HyperliquidTransaction:ApproveAgent",
            fields: [.init("hyperliquidChain", "string"), .init("agentAddress", "address"), .init("agentName", "string"), .init("nonce", "uint64")],
            values: ["hyperliquidChain": .string(chain(mainnet)), "agentAddress": .address(agent), "agentName": .string(agentName), "nonce": .uint(nonce)],
            nonce: nonce, chainId: chainId)
    }
    /// Account type: "unifiedAccount", "portfolioMargin" or "disabled" (manual perps/spot balances).
    public static func userSetAbstraction(user: String, abstraction: String, nonce: UInt64, mainnet: Bool,
                                 chainId: UInt64 = HLSigning.userSignChainId) -> UserSignedAction {
        let u = user.lowercased()
        return UserSignedAction(
            action: .map([("type", .str("userSetAbstraction")), ("signatureChainId", .str(HLSigning.hex(chainId))),
                          ("hyperliquidChain", .str(chain(mainnet))), ("user", .str(u)),
                          ("abstraction", .str(abstraction)), ("nonce", .int(Int64(nonce)))]),
            primaryType: "HyperliquidTransaction:UserSetAbstraction",
            fields: [.init("hyperliquidChain", "string"), .init("user", "address"), .init("abstraction", "string"), .init("nonce", "uint64")],
            values: ["hyperliquidChain": .string(chain(mainnet)), "user": .address(u), "abstraction": .string(abstraction), "nonce": .uint(nonce)],
            nonce: nonce, chainId: chainId)
    }
    /// Sends a token from HyperCore through the HyperEVM to another chain (CCTP withdrawal of USDC to
    /// Arbitrum = destinationChainId 3). sourceDex "spot" for unified accounts, "" for perps.
    public static func sendToEvmWithData(token: String, amount: String, sourceDex: String, destinationRecipient: String,
                                         destinationChainId: UInt64, gasLimit: UInt64, data: [UInt8] = [], nonce: UInt64,
                                         mainnet: Bool, chainId: UInt64 = HLSigning.userSignChainId) -> UserSignedAction {
        let dest = destinationRecipient.lowercased()
        let dataHex = Hex.encode(data)
        return UserSignedAction(
            action: .map([("type", .str("sendToEvmWithData")), ("signatureChainId", .str(HLSigning.hex(chainId))),
                          ("hyperliquidChain", .str(chain(mainnet))), ("token", .str(token)), ("amount", .str(amount)),
                          ("sourceDex", .str(sourceDex)), ("destinationRecipient", .str(dest)), ("addressEncoding", .str("hex")),
                          ("destinationChainId", .int(Int64(destinationChainId))), ("gasLimit", .int(Int64(gasLimit))),
                          ("data", .str(dataHex)), ("nonce", .int(Int64(nonce)))]),
            primaryType: "HyperliquidTransaction:SendToEvmWithData",
            fields: [.init("hyperliquidChain", "string"), .init("token", "string"), .init("amount", "string"),
                     .init("sourceDex", "string"), .init("destinationRecipient", "string"), .init("addressEncoding", "string"),
                     .init("destinationChainId", "uint32"), .init("gasLimit", "uint64"), .init("data", "bytes"), .init("nonce", "uint64")],
            values: ["hyperliquidChain": .string(chain(mainnet)), "token": .string(token), "amount": .string(amount),
                     "sourceDex": .string(sourceDex), "destinationRecipient": .string(dest), "addressEncoding": .string("hex"),
                     "destinationChainId": .uint(destinationChainId), "gasLimit": .uint(gasLimit), "data": .bytes(data), "nonce": .uint(nonce)],
            nonce: nonce, chainId: chainId)
    }
}
