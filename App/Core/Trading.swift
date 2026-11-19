import Foundation
import HyperCore

enum OrderTypeUI: String, CaseIterable, Identifiable {
    case market, limit, stopMarket, stopLimit, takeMarket, takeLimit, scale, twap
    var id: String { rawValue }
    var title: String {
        switch self {
        case .market: return L("Market order")
        case .limit: return L("Limit order")
        case .stopMarket: return L("Stop Market")
        case .stopLimit: return L("Stop Limit")
        case .takeMarket: return L("Take Market")
        case .takeLimit: return L("Take Limit")
        case .scale: return L("Scale (grid)")
        case .twap: return "TWAP"
        }
    }
    var needsPrice: Bool { [.limit, .stopLimit, .takeLimit].contains(self) }
    var needsTrigger: Bool { [.stopMarket, .stopLimit, .takeMarket, .takeLimit].contains(self) }
    var isTrigger: Bool { needsTrigger }
    var tpsl: TPSL { (self == .takeMarket || self == .takeLimit) ? .tp : .sl }
    var triggerIsMarket: Bool { self == .stopMarket || self == .takeMarket }
}

struct OrderDraft {
    var market: Market
    var isBuy: Bool
    var type: OrderTypeUI
    var size: Double
    var price: Double?          // limit price
    var triggerPx: Double?
    var tif: TIF = .gtc
    var reduceOnly = false
    var tp: Double?
    var sl: Double?
    // scale
    var scaleStart: Double?
    var scaleEnd: Double?
    var scaleCount = 5
    var scaleSkew = 1.0
    // twap
    var twapMinutes = 30
    var twapRandomize = true
}

extension AppModel {
    /// Aggressive IOC price for "market" execution.
    func marketPx(_ m: Market, isBuy: Bool, slippage s: Double? = nil) -> Decimal {
        var ref = mid(m.id)
        if let b = book.bestBid, let a = book.bestAsk, m.id == selectedCoin { ref = isBuy ? a : b }
        return HLNum.marketPrice(mid: ref, isBuy: isBuy, slippage: s ?? slippage, szDecimals: m.szDecimals, isSpot: m.isSpot)
    }

    func wire(_ m: Market, isBuy: Bool, px: Decimal, sz: Decimal, reduceOnly: Bool, kind: OrderKind) -> OrderWire {
        OrderWire(asset: m.asset, isBuy: isBuy, limitPx: HLNum.wire(px), sz: HLNum.wire(sz), reduceOnly: reduceOnly, kind: kind)
    }

    func triggerWire(_ m: Market, isBuy: Bool, trigger: Double, limit: Double?, sz: Decimal, tpsl: TPSL, reduceOnly: Bool = true) -> OrderWire {
        let trig = m.roundPrice(trigger)
        let isMarket = limit == nil
        // For market triggers the limit acts as max slippage once triggered.
        let lim = limit.map { m.roundPrice($0) }
            ?? m.roundPrice(trigger * (isBuy ? 1 + max(slippage, 0.1) : 1 - max(slippage, 0.1)))
        return wire(m, isBuy: isBuy, px: lim, sz: sz, reduceOnly: reduceOnly,
                    kind: .trigger(triggerPx: HLNum.wire(trig), isMarket: isMarket, tpsl: tpsl))
    }

    func validate(_ d: OrderDraft) throws {
        let m = d.market
        guard d.size > 0 else { throw HLError(L("Enter a size")) }
        let sz = NSDecimalNumber(decimal: m.roundSize(d.size, mode: .plain)).doubleValue
        guard sz > 0 else { throw HLError(L("Size is below the minimum step {0}", Fmt.num(m.minSizeStep, m.szDecimals))) }
        let px = d.price ?? d.triggerPx ?? mid(m.id)
        if d.type != .scale && d.type != .twap && !d.reduceOnly && sz * px < 10 {
            throw HLError(L("Minimum order value is $10 (now {0})", Fmt.usd(sz * px)))
        }
        if d.type.needsPrice && (d.price ?? 0) <= 0 { throw HLError(L("Enter a price")) }
        if d.type.needsTrigger && (d.triggerPx ?? 0) <= 0 { throw HLError(L("Enter a trigger price")) }
        if d.type == .scale {
            guard let a = d.scaleStart, let b = d.scaleEnd, a > 0, b > 0 else { throw HLError(L("Enter the grid price range")) }
            guard d.scaleCount >= 2 && d.scaleCount <= 50 else { throw HLError(L("Number of orders: 2 to 50")) }
            if sz * min(a, b) / Double(d.scaleCount) < 10 { throw HLError(L("Each grid order must be at least $10")) }
        }
        if d.type == .twap {
            guard d.twapMinutes >= 5 && d.twapMinutes <= 1440 else { throw HLError(L("TWAP duration: 5–1440 minutes")) }
        }
        if let tp = d.tp, tp > 0 {
            let ref = d.price ?? mid(m.id)
            if d.isBuy ? tp <= ref : tp >= ref { throw HLError(L("Take profit must be {0} the entry price", d.isBuy ? L("above") : L("below"))) }
        }
        if let sl = d.sl, sl > 0 {
            let ref = d.price ?? mid(m.id)
            if d.isBuy ? sl >= ref : sl <= ref { throw HLError(L("Stop loss must be {0} the entry price", d.isBuy ? L("below") : L("above"))) }
        }
    }

    /// Places an order from the order form; returns a human readable result.
    func place(_ d: OrderDraft) async throws -> String {
        try validate(d)
        let m = d.market
        let sz = m.roundSize(d.size, mode: .plain)

        switch d.type {
        case .twap:
            let action = HLAction.twapOrder(asset: m.asset, isBuy: d.isBuy, sz: HLNum.wire(sz), reduceOnly: d.reduceOnly,
                                            minutes: d.twapMinutes, randomize: d.twapRandomize)
            let data = try await submit(action)
            Task { await refreshHistory() }
            if let id = data["status"]["running"]["twapId"].int64 { return L("TWAP started (#{0})", id) }
            return L("TWAP started")

        case .scale:
            let orders = scaleWires(d)
            let data = try await submit(HLAction.order(orders))
            return summarize(data, count: orders.count)

        default:
            let main: OrderWire
            switch d.type {
            case .market:
                main = wire(m, isBuy: d.isBuy, px: marketPx(m, isBuy: d.isBuy), sz: sz, reduceOnly: d.reduceOnly, kind: .limit(tif: .ioc))
            case .limit:
                main = wire(m, isBuy: d.isBuy, px: m.roundPrice(d.price ?? 0), sz: sz, reduceOnly: d.reduceOnly, kind: .limit(tif: d.tif))
            default:
                main = triggerWire(m, isBuy: d.isBuy, trigger: d.triggerPx ?? 0, limit: d.type.triggerIsMarket ? nil : d.price,
                                   sz: sz, tpsl: d.type.tpsl, reduceOnly: d.reduceOnly)
            }
            var orders = [main]
            if !d.type.isTrigger && !m.isSpot {
                if let tp = d.tp, tp > 0 { orders.append(triggerWire(m, isBuy: !d.isBuy, trigger: tp, limit: nil, sz: sz, tpsl: .tp)) }
                if let sl = d.sl, sl > 0 { orders.append(triggerWire(m, isBuy: !d.isBuy, trigger: sl, limit: nil, sz: sz, tpsl: .sl)) }
            }
            let data = try await submit(HLAction.order(orders, grouping: orders.count > 1 ? .normalTpsl : .na))
            Task { await refreshAccount(); await refreshOrders() }
            return summarize(data, count: orders.count)
        }
    }

    func scaleWires(_ d: OrderDraft) -> [OrderWire] {
        let m = d.market
        let n = d.scaleCount
        let a = d.scaleStart ?? 0, b = d.scaleEnd ?? 0
        // Weights grow linearly from 1 to `skew` across the ladder.
        let weights = (0..<n).map { i in 1 + (d.scaleSkew - 1) * Double(i) / Double(max(1, n - 1)) }
        let wsum = weights.reduce(0, +)
        return (0..<n).map { i in
            let px = a + (b - a) * Double(i) / Double(n - 1)
            let s = d.size * weights[i] / wsum
            return wire(m, isBuy: d.isBuy, px: m.roundPrice(px), sz: m.roundSize(s, mode: .plain), reduceOnly: d.reduceOnly, kind: .limit(tif: .gtc))
        }
    }

    func summarize(_ data: JSON, count: Int) -> String {
        var parts: [String] = []
        for s in data["statuses"].array {
            if s["filled"]["totalSz"].double != nil {
                parts.append(L("filled {0} at {1}", s["filled"]["totalSz"].str, s["filled"]["avgPx"].str))
            } else if let oid = s["resting"]["oid"].int64 {
                parts.append(L("resting #{0}", oid))
            } else if s.string == "waitingForFill" || s.string == "waitingForTrigger" {
                parts.append(L("waiting for trigger"))
            }
        }
        if parts.isEmpty { return L("Order sent") }
        if parts.count > 3 { return L("Orders placed: {0}", parts.count) }
        return L("Order ") + parts.joined(separator: "; ")
    }

    // MARK: Position actions

    func closePosition(_ p: Position, fraction: Double = 1, limitPx: Double? = nil) async throws -> String {
        guard let m = market(p.coin) else { throw HLError(L("Market {0} not found", p.coin)) }
        let isBuy = !p.isLong
        let sz = fraction >= 1 ? Decimal(string: HLNum.wire(p.size)) ?? m.roundSize(p.size, mode: .plain)
                               : m.roundSize(p.size * fraction, mode: .plain)
        let o: OrderWire
        if let limitPx {
            o = wire(m, isBuy: isBuy, px: m.roundPrice(limitPx), sz: sz, reduceOnly: true, kind: .limit(tif: .gtc))
        } else {
            o = wire(m, isBuy: isBuy, px: marketPx(m, isBuy: isBuy), sz: sz, reduceOnly: true, kind: .limit(tif: .ioc))
        }
        let data = try await submit(HLAction.order([o]))
        Task { await refreshAccount(); await refreshOrders() }
        return summarize(data, count: 1)
    }

    func closeAll() async throws -> String {
        let wires: [OrderWire] = positions.compactMap { p in
            guard let m = market(p.coin) else { return nil }
            let isBuy = !p.isLong
            return wire(m, isBuy: isBuy, px: marketPx(m, isBuy: isBuy), sz: Decimal(string: HLNum.wire(p.size)) ?? 0,
                        reduceOnly: true, kind: .limit(tif: .ioc))
        }
        guard !wires.isEmpty else { throw HLError(L("No open positions")) }
        let data = try await submit(HLAction.order(wires))
        Task { await refreshAccount(); await refreshOrders() }
        return summarize(data, count: wires.count)
    }

    func reverse(_ p: Position) async throws -> String {
        guard let m = market(p.coin) else { throw HLError(L("Market not found")) }
        let isBuy = !p.isLong
        let sz = m.roundSize(p.size * 2, mode: .plain)
        let data = try await submit(HLAction.order([wire(m, isBuy: isBuy, px: marketPx(m, isBuy: isBuy), sz: sz, reduceOnly: false, kind: .limit(tif: .ioc))]))
        Task { await refreshAccount() }
        return summarize(data, count: 1)
    }

    /// Sets position TP/SL (replaces existing position TP/SL orders of the same kind).
    func setPositionTpsl(_ p: Position, tp: Double?, sl: Double?) async throws -> String {
        guard let m = market(p.coin) else { throw HLError(L("Market not found")) }
        let existing = openOrders.filter { $0.coin == p.coin && $0.isPositionTpsl }
        var toCancel: [(asset: Int, oid: Int64)] = []
        for o in existing {
            let isTp = o.orderType.hasPrefix("Take")
            if (isTp && tp != nil) || (!isTp && sl != nil) { toCancel.append((m.asset, o.oid)) }
        }
        if !toCancel.isEmpty { try await submit(HLAction.cancel(toCancel)) }
        let isBuy = !p.isLong
        let sz = Decimal(string: HLNum.wire(p.size)) ?? 0
        var orders: [OrderWire] = []
        if let tp, tp > 0 { orders.append(triggerWire(m, isBuy: isBuy, trigger: tp, limit: nil, sz: sz, tpsl: .tp)) }
        if let sl, sl > 0 { orders.append(triggerWire(m, isBuy: isBuy, trigger: sl, limit: nil, sz: sz, tpsl: .sl)) }
        guard !orders.isEmpty else {
            Task { await refreshOrders() }
            return L("TP/SL removed")
        }
        let data = try await submit(HLAction.order(orders, grouping: .positionTpsl))
        Task { await refreshOrders() }
        return summarize(data, count: orders.count)
    }

    func updateLeverage(_ m: Market, leverage: Int, isCross: Bool) async throws {
        try await submit(HLAction.updateLeverage(asset: m.asset, isCross: isCross, leverage: leverage))
        activeAsset.leverage = leverage
        activeAsset.isCross = isCross
        Task { await refreshAccount() }
    }

    func updateIsolatedMargin(_ p: Position, deltaUsd: Double) async throws {
        guard let m = market(p.coin) else { throw HLError(L("Market not found")) }
        try await submit(HLAction.updateIsolatedMargin(asset: m.asset, ntli: Int64((deltaUsd * 1_000_000).rounded())))
        Task { await refreshAccount() }
    }

    // MARK: Orders

    func cancel(_ o: OpenOrder) async throws {
        guard let m = market(o.coin) else { throw HLError(L("Market not found")) }
        try await submit(HLAction.cancel([(m.asset, o.oid)]))
        openOrders.removeAll { $0.oid == o.oid }
        Task { await refreshOrders() }
    }

    func cancelAll(coin: String? = nil) async throws -> String {
        let list = openOrders.filter { coin == nil || $0.coin == coin }
        let items: [(asset: Int, oid: Int64)] = list.compactMap { o in market(o.coin).map { ($0.asset, o.oid) } }
        guard !items.isEmpty else { throw HLError(L("No open orders")) }
        try await submit(HLAction.cancel(items))
        Task { await refreshOrders() }
        return L("Orders cancelled: {0}", items.count)
    }

    func modify(_ o: OpenOrder, price: Double, size: Double, trigger: Double?) async throws {
        guard let m = market(o.coin) else { throw HLError(L("Market not found")) }
        let sz = m.roundSize(size, mode: .plain)
        let kind: OrderKind
        if o.isTrigger {
            let trig = m.roundPrice(trigger ?? o.triggerPx)
            let isMarket = o.orderType.contains("Market")
            kind = .trigger(triggerPx: HLNum.wire(trig), isMarket: isMarket, tpsl: o.orderType.hasPrefix("Take") ? .tp : .sl)
        } else {
            kind = .limit(tif: TIF(rawValue: o.tif ?? "Gtc") ?? .gtc)
        }
        let w = wire(m, isBuy: o.isBuy, px: m.roundPrice(price), sz: sz, reduceOnly: o.reduceOnly, kind: kind)
        try await submit(HLAction.modify(oid: o.oid, order: w))
        Task { await refreshOrders() }
    }

    func cancelTwap(_ t: TwapState) async throws {
        guard let m = market(t.coin) else { throw HLError(L("Market not found")) }
        try await submit(HLAction.twapCancel(asset: m.asset, twapId: t.id))
        twaps.removeAll { $0.id == t.id }
        Task { await refreshHistory() }
    }

    /// Dead man's switch. minutes == nil clears it. Minimum is 5 seconds in the future per HL docs.
    func scheduleCancel(minutes: Int?) async throws {
        let time = minutes.map { UInt64(Date().addingTimeInterval(Double($0) * 60).timeIntervalSince1970 * 1000) }
        try await submit(HLAction.scheduleCancel(time: time))
    }

    // MARK: Transfers (main key only)

    func usdClassTransfer(amount: Double, toPerp: Bool) async throws {
        var amt = HLNum.wire(amount, maxDecimals: 6)
        if let v = vaultForActions { amt += " subaccount:\(v)" }
        try await submitUser(HLAction.usdClassTransfer(amount: amt, toPerp: toPerp, nonce: nextNonce(), mainnet: network.isMainnet))
        Task { await refreshAccount() }
    }

    func withdraw(amount: Double, destination: String) async throws {
        try await submitUser(HLAction.withdraw(destination: destination, amount: HLNum.wire(amount, maxDecimals: 6), time: nextNonce(), mainnet: network.isMainnet))
        Task { await refreshAccount(); await refreshHistory() }
    }

    func sendUsd(amount: Double, destination: String) async throws {
        try await submitUser(HLAction.usdSend(destination: destination, amount: HLNum.wire(amount, maxDecimals: 6), time: nextNonce(), mainnet: network.isMainnet))
        Task { await refreshAccount(); await refreshHistory() }
    }

    func sendSpot(token: SpotToken, amount: Double, destination: String) async throws {
        try await submitUser(HLAction.spotSend(destination: destination, token: token.wire,
                                               amount: HLNum.wire(amount, maxDecimals: token.weiDecimals),
                                               time: nextNonce(), mainnet: network.isMainnet))
        Task { await refreshAccount(); await refreshHistory() }
    }

    /// Moves collateral between the main perp dex (""), spot ("spot") and HIP-3 dexes.
    func sendAsset(from: String, to: String, token: SpotToken, amount: Double) async throws {
        guard let me = account?.address else { throw HLError(L("Add an account in Settings")) }
        let dest = vaultForActions ?? me
        try await submitUser(HLAction.sendAsset(destination: dest, sourceDex: from, destinationDex: to, token: token.wire,
                                                amount: HLNum.wire(amount, maxDecimals: min(token.weiDecimals, 8)),
                                                fromSubAccount: vaultForActions ?? "", nonce: nextNonce(), mainnet: network.isMainnet))
        Task { await refreshAllAccounts() }
    }

    /// Collateral token of a dex ("" main → USDC).
    func collateral(of dex: String) -> SpotToken? {
        if let idx = perpDexs.first(where: { $0.name == dex })?.collateralToken { return spotTokens[idx] }
        return spotTokens.values.first { $0.name == "USDC" }
    }

    /// Creates and approves a new API wallet using the main key; returns the agent private key.
    func createAgent(name: String) async throws -> (address: String, key: String) {
        let (agent, key) = try HLWallet.generate()
        try await submitUser(HLAction.approveAgent(agentAddress: agent.address, agentName: name, nonce: nextNonce(), mainnet: network.isMainnet))
        return (agent.address, key)
    }

    /// Checks whether `agent` is an approved API wallet of `user`.
    func isAgentApproved(user: String, agent: String) async -> Bool? {
        guard let j = try? await api.info(type: "extraAgents", [("user", .str(user.lowercased()))]) else { return nil }
        return j.array.contains { $0["address"].str.lowercased() == agent.lowercased() }
    }

    // MARK: Estimates

    /// Rough liquidation price estimate for a new position (isolated-style using max-leverage MMR).
    func estimateLiq(m: Market, isBuy: Bool, entry: Double, size: Double, leverage: Int, isCross: Bool) -> Double? {
        guard entry > 0, size > 0, !m.isSpot else { return nil }
        let mmr = 1 / (2 * Double(max(m.maxLeverage, 1)))
        let side: Double = isBuy ? 1 : -1
        let margin: Double
        if isCross {
            let free = max(0, summary.accountValue - summary.maintenanceMargin)
            margin = free + (position(m.id).map { $0.marginUsed } ?? 0)
        } else {
            margin = entry * size / Double(max(leverage, 1))
        }
        let totalSize = size + (position(m.id).map { ($0.isLong == isBuy) ? $0.size : -$0.size } ?? 0)
        guard totalSize > 0 else { return nil }
        let liq = (entry - side * margin / size) / (1 - side * mmr)
        return liq > 0 ? liq : nil
    }
}
