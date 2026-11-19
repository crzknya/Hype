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

    public static func vaultTransfer(vault: String, isDeposit: Bool, usdMicros: Int64) -> MP {
        .map([("type", .str("vaultTransfer")), ("vaultAddress", .str(vault.lowercased())), ("isDeposit", .bool(isDeposit)), ("usd", .int(usdMicros))])
    }

    // MARK: User-signed actions (require the main wallet key)

    private static func chain(_ mainnet: Bool) -> String { mainnet ? "Mainnet" : "Testnet" }

    public static func usdSend(destination: String, amount: String, time: UInt64, mainnet: Bool) -> UserSignedAction {
        let dest = destination.lowercased()
        return UserSignedAction(
            action: .map([("type", .str("usdSend")), ("signatureChainId", .str(HLSigning.userSignChainIdHex)),
                          ("hyperliquidChain", .str(chain(mainnet))), ("destination", .str(dest)),
                          ("amount", .str(amount)), ("time", .int(Int64(time)))]),
            primaryType: "HyperliquidTransaction:UsdSend",
            fields: [.init("hyperliquidChain", "string"), .init("destination", "string"), .init("amount", "string"), .init("time", "uint64")],
            values: ["hyperliquidChain": .string(chain(mainnet)), "destination": .string(dest), "amount": .string(amount), "time": .uint(time)],
            nonce: time)
    }

    public static func withdraw(destination: String, amount: String, time: UInt64, mainnet: Bool) -> UserSignedAction {
        let dest = destination.lowercased()
        return UserSignedAction(
            action: .map([("type", .str("withdraw3")), ("signatureChainId", .str(HLSigning.userSignChainIdHex)),
                          ("hyperliquidChain", .str(chain(mainnet))), ("destination", .str(dest)),
                          ("amount", .str(amount)), ("time", .int(Int64(time)))]),
            primaryType: "HyperliquidTransaction:Withdraw",
            fields: [.init("hyperliquidChain", "string"), .init("destination", "string"), .init("amount", "string"), .init("time", "uint64")],
            values: ["hyperliquidChain": .string(chain(mainnet)), "destination": .string(dest), "amount": .string(amount), "time": .uint(time)],
            nonce: time)
    }

    /// token: "NAME:0xTOKENID"
    public static func spotSend(destination: String, token: String, amount: String, time: UInt64, mainnet: Bool) -> UserSignedAction {
        let dest = destination.lowercased()
        return UserSignedAction(
            action: .map([("type", .str("spotSend")), ("signatureChainId", .str(HLSigning.userSignChainIdHex)),
                          ("hyperliquidChain", .str(chain(mainnet))), ("destination", .str(dest)), ("token", .str(token)),
                          ("amount", .str(amount)), ("time", .int(Int64(time)))]),
            primaryType: "HyperliquidTransaction:SpotSend",
            fields: [.init("hyperliquidChain", "string"), .init("destination", "string"), .init("token", "string"), .init("amount", "string"), .init("time", "uint64")],
            values: ["hyperliquidChain": .string(chain(mainnet)), "destination": .string(dest), "token": .string(token),
                     "amount": .string(amount), "time": .uint(time)],
            nonce: time)
    }

    public static func usdClassTransfer(amount: String, toPerp: Bool, nonce: UInt64, mainnet: Bool) -> UserSignedAction {
        UserSignedAction(
            action: .map([("type", .str("usdClassTransfer")), ("signatureChainId", .str(HLSigning.userSignChainIdHex)),
                          ("hyperliquidChain", .str(chain(mainnet))), ("amount", .str(amount)), ("toPerp", .bool(toPerp)),
                          ("nonce", .int(Int64(nonce)))]),
            primaryType: "HyperliquidTransaction:UsdClassTransfer",
            fields: [.init("hyperliquidChain", "string"), .init("amount", "string"), .init("toPerp", "bool"), .init("nonce", "uint64")],
            values: ["hyperliquidChain": .string(chain(mainnet)), "amount": .string(amount), "toPerp": .bool(toPerp), "nonce": .uint(nonce)],
            nonce: nonce)
    }

    public static func approveAgent(agentAddress: String, agentName: String, nonce: UInt64, mainnet: Bool) -> UserSignedAction {
        let agent = agentAddress.lowercased()
        return UserSignedAction(
            action: .map([("type", .str("approveAgent")), ("signatureChainId", .str(HLSigning.userSignChainIdHex)),
                          ("hyperliquidChain", .str(chain(mainnet))), ("agentAddress", .str(agent)),
                          ("agentName", .str(agentName)), ("nonce", .int(Int64(nonce)))]),
            primaryType: "HyperliquidTransaction:ApproveAgent",
            fields: [.init("hyperliquidChain", "string"), .init("agentAddress", "address"), .init("agentName", "string"), .init("nonce", "uint64")],
            values: ["hyperliquidChain": .string(chain(mainnet)), "agentAddress": .address(agent), "agentName": .string(agentName), "nonce": .uint(nonce)],
            nonce: nonce)
    }
}
