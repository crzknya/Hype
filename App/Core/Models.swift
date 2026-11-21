import Foundation
import HyperCore

struct Market: Identifiable, Hashable {
    let id: String          // API coin key: "BTC", "PURR/USDC", "@107"
    let name: String        // display name: "BTC", "HYPE/USDC"
    let base: String
    let quote: String
    let asset: Int          // perp index, or 10000 + spot index
    let isSpot: Bool
    let szDecimals: Int
    let maxLeverage: Int
    let onlyIsolated: Bool
    var dex: String = ""     // "" = main perp dex, otherwise HIP-3 builder dex name (e.g. "xyz")
    var marginTiers: [MarginTier] = []   // from the dex meta's marginTables (empty = single tier at maxLeverage)
    var deployerFeeScale: Double = 0     // HIP-3: deployer fee share (fees × (scale + max(1, scale)))
    var growthMode = false               // HIP-3 growth mode: fees × 0.1
    var markPx: Double = 0
    var midPx: Double = 0
    var oraclePx: Double = 0
    var prevDayPx: Double = 0
    var dayNtlVlm: Double = 0
    var funding: Double = 0
    var openInterest: Double = 0
    var premium: Double = 0

    static func == (a: Market, b: Market) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    var isHip3: Bool { !dex.isEmpty }

    var change24h: Double { prevDayPx > 0 && markPx > 0 ? markPx / prevDayPx - 1 : 0 }
    var fundingAnnual: Double { funding * 24 * 365 }
    var openInterestUsd: Double { openInterest * markPx }
    var maxPriceDecimals: Int { HLNum.maxPriceDecimals(szDecimals: szDecimals, isSpot: isSpot) }

    func priceDecimals(_ px: Double) -> Int {
        HLNum.priceDecimals(px, szDecimals: szDecimals, isSpot: isSpot)
    }

    func roundPrice(_ px: Double) -> Decimal { HLNum.roundPrice(px, szDecimals: szDecimals, isSpot: isSpot) }
    func roundSize(_ sz: Double, mode: NSDecimalNumber.RoundingMode = .down) -> Decimal { HLNum.roundSize(sz, szDecimals: szDecimals, mode: mode) }
    var minSizeStep: Double { pow(10, -Double(szDecimals)) }
}

/// A HIP-3 builder-deployed perp dex (stocks, indices, etc).
struct PerpDex: Identifiable, Hashable {
    let name: String
    let fullName: String
    let offset: Int          // asset id offset: 110000 + i * 10000
    var collateralToken: Int?
    var id: String { name }
}

struct SpotToken: Identifiable, Hashable {
    let index: Int
    let name: String
    let szDecimals: Int
    let weiDecimals: Int
    let tokenId: String
    var evmContract: String? = nil      // linked HyperEVM ERC-20 (nil: not linked; HYPE is native)
    var evmExtraDecimals = 0            // EVM decimals = weiDecimals + evmExtraDecimals
    var id: Int { index }
    var evmDecimals: Int { weiDecimals + evmExtraDecimals }
    /// Can move between HyperCore and HyperEVM.
    var isEvmLinked: Bool { evmContract != nil || name == "HYPE" }
    /// Wire form for spotSend: NAME:0xTOKENID
    var wire: String { "\(name):\(tokenId)" }
}

/// One margin tier of a market (notional ≥ lowerBound uses maxLeverage). `deduction` is the
/// maintenance deduction that keeps the maintenance margin continuous across tiers.
struct MarginTier: Hashable {
    let lowerBound: Double
    let upperBound: Double?
    let maxLeverage: Int
    let deduction: Double

    /// Builds tiers the way app.hyperliquid.xyz does: ids ≤ 50 are a single tier at that leverage.
    static func tiers(tableId: Int?, maxLeverage: Int, tables: [Int: [(lowerBound: Double, maxLeverage: Int)]]) -> [MarginTier] {
        var raw: [(lowerBound: Double, maxLeverage: Int)] = [(0, max(maxLeverage, 1))]
        if let id = tableId {
            if id <= 50 { raw = [(0, max(id, 1))] } else if let t = tables[id], !t.isEmpty { raw = t }
        }
        var out: [MarginTier] = []
        var deduction = 0.0
        for (i, t) in raw.enumerated() {
            let next = i + 1 < raw.count ? raw[i + 1] : nil
            out.append(MarginTier(lowerBound: t.lowerBound, upperBound: next?.lowerBound, maxLeverage: max(t.maxLeverage, 1), deduction: deduction))
            if let n = next {
                deduction += n.lowerBound * (1 / Double(2 * max(n.maxLeverage, 1)) - 1 / Double(2 * max(t.maxLeverage, 1)))
            }
        }
        return out
    }

    /// Maintenance margin for a position of `notional` in this tier.
    func maintenance(_ notional: Double) -> Double { notional / Double(2 * maxLeverage) - deduction }
}

extension Array where Element == MarginTier {
    func tier(for notional: Double) -> MarginTier? {
        first { notional >= $0.lowerBound && ($0.upperBound == nil || notional < $0.upperBound!) } ?? last
    }
}

struct Position: Identifiable, Hashable {
    let coin: String
    let szi: Double
    let entryPx: Double
    let positionValue: Double
    let unrealizedPnl: Double
    let returnOnEquity: Double
    let liquidationPx: Double?
    let marginUsed: Double
    let leverageType: String
    let leverage: Int
    let maxLeverage: Int
    let fundingSinceOpen: Double
    let rawUsd: Double      // isolated positions: margin "raw USD" (see clearinghouseState)
    var id: String { coin }
    var isIsolated: Bool { leverageType == "isolated" }
    var isLong: Bool { szi > 0 }
    var size: Double { abs(szi) }

    init(_ j: JSON) {
        let p = j["position"]
        coin = p["coin"].str
        szi = p["szi"].dbl
        entryPx = p["entryPx"].dbl
        positionValue = p["positionValue"].dbl
        unrealizedPnl = p["unrealizedPnl"].dbl
        returnOnEquity = p["returnOnEquity"].dbl
        liquidationPx = p["liquidationPx"].double
        marginUsed = p["marginUsed"].dbl
        leverageType = p["leverage"]["type"].str
        leverage = p["leverage"]["value"].int ?? 1
        maxLeverage = p["maxLeverage"].int ?? 1
        fundingSinceOpen = p["cumFunding"]["sinceOpen"].dbl
        rawUsd = p["leverage"]["rawUsd"].dbl
    }
}

struct AccountSummary: Equatable {
    var accountValue: Double = 0
    var crossNtlPos: Double = 0
    var totalNtlPos: Double = 0
    var totalMarginUsed: Double = 0
    var withdrawable: Double = 0
    var maintenanceMargin: Double = 0
    var crossAccountValue: Double = 0

    init() {}

    init(_ ch: JSON) {
        let ms = ch["marginSummary"], cs = ch["crossMarginSummary"]
        accountValue = ms["accountValue"].dbl
        totalNtlPos = ms["totalNtlPos"].dbl
        totalMarginUsed = ms["totalMarginUsed"].dbl
        withdrawable = ch["withdrawable"].dbl
        maintenanceMargin = ch["crossMaintenanceMarginUsed"].dbl
        crossAccountValue = cs["accountValue"].dbl
        crossNtlPos = cs["totalNtlPos"].dbl
    }

    var leverage: Double { accountValue > 0 ? totalNtlPos / accountValue : 0 }
    var marginRatio: Double { crossAccountValue > 0 ? maintenanceMargin / crossAccountValue : 0 }
}

struct OpenOrder: Identifiable, Hashable {
    let coin: String
    let isBuy: Bool
    let limitPx: Double
    let sz: Double
    let origSz: Double
    let oid: Int64
    let timestamp: Date
    let orderType: String
    let triggerPx: Double
    let isTrigger: Bool
    let triggerCondition: String
    let reduceOnly: Bool
    let isPositionTpsl: Bool
    let tif: String?
    let cloid: String?
    var id: Int64 { oid }

    init(_ j: JSON) {
        coin = j["coin"].str
        isBuy = j["side"].str == "B"
        limitPx = j["limitPx"].dbl
        sz = j["sz"].dbl
        origSz = j["origSz"].double ?? j["sz"].dbl
        oid = j["oid"].int64 ?? 0
        timestamp = Date(timeIntervalSince1970: j["timestamp"].dbl / 1000)
        orderType = j["orderType"].string ?? "Limit"
        triggerPx = j["triggerPx"].dbl
        isTrigger = j["isTrigger"].bool ?? false
        triggerCondition = j["triggerCondition"].str
        reduceOnly = j["reduceOnly"].bool ?? false
        isPositionTpsl = j["isPositionTpsl"].bool ?? false
        tif = j["tif"].string
        cloid = j["cloid"].string
    }

    var typeTitle: String {
        switch orderType {
        case "Limit": return L("Limit")
        case "Market": return L("Market")
        case "Stop Market": return L("Stop Market")
        case "Stop Limit": return L("Stop Limit")
        case "Take Profit Market": return L("Take Market")
        case "Take Profit Limit": return L("Take Limit")
        case "Trailing Stop Market", "Trailing Stop": return L("Trailing Stop")
        default: return orderType
        }
    }
}

struct Fill: Identifiable, Hashable {
    let coin: String
    let px: Double
    let sz: Double
    let isBuy: Bool
    let time: Date
    let dir: String
    let closedPnl: Double
    let fee: Double
    let feeToken: String
    let oid: Int64
    let tid: Int64
    let hash: String
    let crossed: Bool
    var id: String { "\(tid)-\(oid)-\(hash.suffix(8))" }

    init(_ j: JSON) {
        coin = j["coin"].str
        px = j["px"].dbl
        sz = j["sz"].dbl
        isBuy = j["side"].str == "B"
        time = Date(timeIntervalSince1970: j["time"].dbl / 1000)
        dir = j["dir"].str
        closedPnl = j["closedPnl"].dbl
        fee = j["fee"].dbl
        feeToken = j["feeToken"].string ?? "USDC"
        oid = j["oid"].int64 ?? 0
        tid = j["tid"].int64 ?? 0
        hash = j["hash"].str
        crossed = j["crossed"].bool ?? false
    }

    var dirTitle: String {
        switch dir {
        case "Open Long": return L("Open Long")
        case "Open Short": return L("Open Short")
        case "Close Long": return L("Close Long")
        case "Close Short": return L("Close Short")
        case "Buy": return L("Purchase")
        case "Sell": return L("Sale")
        case "Long > Short": return L("Long → Short")
        case "Short > Long": return L("Short → Long")
        case "Liquidated Isolated Long", "Liquidated Cross Long": return L("Long liquidated")
        case "Liquidated Isolated Short", "Liquidated Cross Short": return L("Short liquidated")
        default: return dir
        }
    }
}

struct FundingEntry: Identifiable, Hashable {
    let time: Date
    let coin: String
    let usdc: Double
    let szi: Double
    let rate: Double
    let hash: String
    var id: String { "\(hash)-\(coin)-\(time.timeIntervalSince1970)" }

    init(_ j: JSON) {
        time = Date(timeIntervalSince1970: j["time"].dbl / 1000)
        let d = j["delta"]
        coin = d["coin"].str
        usdc = d["usdc"].dbl
        szi = d["szi"].dbl
        rate = d["fundingRate"].dbl
        hash = j["hash"].str
    }
}

struct LedgerEntry: Identifiable, Hashable {
    let time: Date
    let type: String
    let usdc: Double
    let hash: String
    let detail: String
    var id: String { "\(hash)-\(type)-\(time.timeIntervalSince1970)" }

    init(_ j: JSON) {
        time = Date(timeIntervalSince1970: j["time"].dbl / 1000)
        let d = j["delta"]
        type = d["type"].str
        hash = j["hash"].str
        var amount = d["usdc"].double ?? d["amount"].double ?? 0
        var det = ""
        switch type {
        case "withdraw": amount = -abs(amount); det = L("Withdrawal")
        case "deposit": det = L("Deposit")
        case "accountClassTransfer": det = (d["toPerp"].bool ?? false) ? L("Spot → Perp") : L("Perp → Spot")
        case "internalTransfer", "send", "spotTransfer":
            det = L("Transfer {0} {1}", d["token"].string ?? "USDC", Address.short(d["destination"].str))
        case "vaultDeposit": det = L("Vault deposit"); amount = -abs(amount)
        case "vaultWithdraw": det = L("Vault withdrawal")
        case "subAccountTransfer": det = L("Sub-account")
        case "liquidation": det = L("Liquidation")
        default: det = type
        }
        usdc = amount
        detail = det
    }
}

struct SpotBalance: Identifiable, Hashable {
    let coin: String
    let token: Int
    let total: Double
    let hold: Double
    let entryNtl: Double
    var id: String { coin }
    var available: Double { total - hold }

    init(_ j: JSON) {
        coin = j["coin"].str
        token = j["token"].int ?? 0
        total = j["total"].dbl
        hold = j["hold"].dbl
        entryNtl = j["entryNtl"].dbl
    }
}

struct TwapState: Identifiable, Hashable {
    let id: Int64
    let coin: String
    let isBuy: Bool
    let sz: Double
    let executedSz: Double
    let executedNtl: Double
    let minutes: Int
    let started: Date
    let reduceOnly: Bool

    var progress: Double { sz > 0 ? executedSz / sz : 0 }
    var avgPx: Double { executedSz > 0 ? executedNtl / executedSz : 0 }
    var endsAt: Date { started.addingTimeInterval(Double(minutes) * 60) }
}

struct Candle: Identifiable, Hashable {
    let t: Double   // open time ms
    var o: Double, h: Double, l: Double, c: Double, v: Double
    var id: Double { t }

    init(t: Double, o: Double, h: Double, l: Double, c: Double, v: Double) {
        self.t = t; self.o = o; self.h = h; self.l = l; self.c = c; self.v = v
    }

    init(_ j: JSON) {
        t = j["t"].dbl
        o = j["o"].dbl; h = j["h"].dbl; l = j["l"].dbl; c = j["c"].dbl; v = j["v"].dbl
    }
}

struct BookLevel: Identifiable, Hashable {
    let px: Double
    let sz: Double
    let n: Int
    var id: Double { px }
}

struct OrderBook: Equatable {
    var bids: [BookLevel] = []
    var asks: [BookLevel] = []
    var time: Date = .distantPast

    var bestBid: Double? { bids.first?.px }
    var bestAsk: Double? { asks.first?.px }
    var mid: Double? {
        guard let b = bestBid, let a = bestAsk else { return nil }
        return (a + b) / 2
    }
    var spread: Double? {
        guard let b = bestBid, let a = bestAsk else { return nil }
        return a - b
    }
}

struct BestBidAsk: Equatable {
    let bid: Double
    let ask: Double
}

struct PublicTrade: Identifiable, Hashable {
    let px: Double
    let sz: Double
    let isBuy: Bool
    let time: Date
    let tid: Int64
    var id: Int64 { tid }
}

enum CandleInterval: String, CaseIterable, Identifiable, Codable {
    case m1 = "1m", m3 = "3m", m5 = "5m", m15 = "15m", m30 = "30m", h1 = "1h", h2 = "2h", h4 = "4h", h8 = "8h", h12 = "12h", d1 = "1d", d3 = "3d", w1 = "1w", M1 = "1M"
    var id: String { rawValue }
    var seconds: Double {
        switch self {
        case .m1: return 60
        case .m3: return 180
        case .m5: return 300
        case .m15: return 900
        case .m30: return 1800
        case .h1: return 3600
        case .h2: return 7200
        case .h4: return 14400
        case .h8: return 28800
        case .h12: return 43200
        case .d1: return 86400
        case .d3: return 259200
        case .w1: return 604800
        case .M1: return 2_592_000
        }
    }
    static let quick: [CandleInterval] = [.m1, .m5, .m15, .h1, .h4, .d1]
}

struct PriceAlert: Identifiable, Codable, Hashable {
    var id = UUID()
    var coin: String
    var name: String
    var price: Double
    var above: Bool
    var repeating: Bool = false
    var created = Date()
}

/// One time range of the `portfolio` info request.
struct PortfolioRange {
    var accountValue: [(Date, Double)]
    var pnl: [(Date, Double)]
    var volume: Double
    /// PnL over the range (last − first point of the cumulative PnL history).
    var pnlChange: Double { (pnl.last?.1 ?? 0) - (pnl.first?.1 ?? 0) }
}

/// An entry of `historicalOrders`: the order as it was and its final (or current) status.
struct HistoricalOrder: Identifiable, Hashable {
    let order: OpenOrder
    let status: String
    let time: Date
    var id: String { "\(order.oid)-\(status)" }

    init(_ j: JSON) {
        order = OpenOrder(j["order"])
        status = j["status"].str
        time = Date(timeIntervalSince1970: j["statusTimestamp"].dbl / 1000)
    }

    var statusTitle: String {
        switch status {
        case "open": return L("Open")
        case "filled": return L("Filled")
        case "canceled": return L("Canceled")
        case "triggered": return L("Triggered")
        case "rejected": return L("Rejected")
        case "marginCanceled": return L("Canceled: margin")
        case "reduceOnlyCanceled": return L("Canceled: reduce only")
        case "badAloPxRejected": return L("Rejected: post-only would cross")
        case "iocCancelRejected": return L("Rejected: IOC not filled")
        case "scheduledCancel": return L("Canceled: schedule")
        case "selfTradeCanceled": return L("Canceled: self trade")
        case "siblingFilledCanceled": return L("Canceled: TP/SL sibling filled")
        default: return status
        }
    }
}

/// A sub-account of the master (`subAccounts` info).
struct SubAccount: Identifiable, Hashable {
    let address: String
    let name: String
    let perpsValue: Double
    let withdrawable: Double
    let balances: [SpotBalance]
    var id: String { address }

    init(_ j: JSON) {
        address = j["subAccountUser"].str.lowercased()
        name = j["name"].str
        perpsValue = j["clearinghouseState"]["marginSummary"]["accountValue"].dbl
        withdrawable = j["clearinghouseState"]["withdrawable"].dbl
        balances = j["spotState"]["balances"].array.map(SpotBalance.init).filter { $0.total != 0 }
    }
}
