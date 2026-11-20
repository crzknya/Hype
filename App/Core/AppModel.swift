import Foundation
import SwiftUI
import Observation
import HyperCore

enum AppTab: Hashable { case markets, trade, portfolio, tools, settings }

struct Toast: Identifiable, Equatable {
    enum Kind { case success, error, info }
    let id = UUID()
    let kind: Kind
    let text: String
}

struct ActiveAssetData: Equatable {
    var leverage: Int = 1
    var isCross: Bool = true
    var maxBuy: Double = 0
    var maxSell: Double = 0
    var availableBuy: Double = 0
    var availableSell: Double = 0
}

@MainActor
@Observable
final class AppModel {
    // MARK: Settings (persisted)
    var network: HLNetwork { didSet { save(); networkChanged() } }
    var accounts: [Account] = [] { didSet { save() } }
    var activeAccountId: UUID? { didSet { save(); accountChanged() } }
    var favorites: Set<String> = [] { didSet { save() } }
    var alerts: [PriceAlert] = [] { didSet { save() } }
    var slippage: Double = 0.03 { didSet { save() } }
    var confirmOrders = true { didSet { save() } }
    var haptics = true { didSet { save() } }
    var biometricLock = false { didSet { save() } }
    var selectedCoin: String = "BTC" { didSet { save(); if oldValue != selectedCoin { coinChanged(old: oldValue) } } }
    var interval: CandleInterval = .h1 { didSet { save(); if oldValue != interval { intervalChanged(old: oldValue) } } }
    var bookSigFigs: Int? = nil { didSet { if oldValue != bookSigFigs { bookAggChanged(old: oldValue) } } }
    var showChart = true { didSet { save() } }
    var minTradeUsd: Double = 0 { didSet { save() } }
    var indicators: [IndicatorConfig] = IndicatorConfig.defaults { didSet { save() } }
    var showVolume = true { didSet { save() } }
    var chartHeight: Double = 250 { didSet { save() } }
    var logScale = false { didSet { save() } }
    var tradeLayout: TradeLayout = .sheet { didSet { save() } }
    var lastOrderType = "market" { didSet { save() } }
    var visibleIntervals: [CandleInterval] = CandleInterval.quick { didSet { save() } }
    var theme: AppTheme = AppTheme.current {
        didSet { AppTheme.current = theme; save(); ThemeAppearance.apply() }
    }
    var language: AppLanguage = Loc.lang { didSet { Loc.lang = language; save() } }

    // MARK: Market data
    var perps: [Market] = []
    var spots: [Market] = []
    var hip3: [Market] = []
    var perpDexs: [PerpDex] = []
    var marketById: [String: Market] = [:]
    var spotTokens: [Int: SpotToken] = [:]
    var mids: [String: Double] = [:]
    var book = OrderBook()
    /// Live best bid/ask (bbo stream), fresher than the order-book snapshot.
    var bbo: BestBidAsk?
    @ObservationIgnored private var lastSocketBookAt: Date = .distantPast
    @ObservationIgnored private var pendingMids: [String: Double] = [:]
    @ObservationIgnored private var midsFlushScheduled = false
    /// When the shown order-book snapshot arrived (for the staleness indicator).
    var bookReceivedAt: Date = .distantPast
    var trades: [PublicTrade] = []
    var candles: [Candle] = []
    var candlesLoading = false
    var wsConnected = false
    var wsError: String?
    var metaLoaded = false

    // MARK: Account
    var summary = AccountSummary()
    var positions: [Position] = []
    var dexSummaries: [String: AccountSummary] = [:]
    @ObservationIgnored private var mainPositions: [Position] = []
    @ObservationIgnored private var dexPositions: [String: [Position]] = [:]
    @ObservationIgnored private var activeDexes: Set<String> = []
    var openOrders: [OpenOrder] = []
    var fills: [Fill] = []
    var fundingHistory: [FundingEntry] = []
    var ledger: [LedgerEntry] = []
    var spotBalances: [SpotBalance] = []
    var twaps: [TwapState] = []
    var activeAsset = ActiveAssetData()
    var takerFee: Double = 0.00045
    var makerFee: Double = 0.00015
    var portfolioHistory: [(Date, Double)] = []
    var accountError: String?

    // MARK: UI
    var tab: AppTab = .markets
    var toast: Toast?
    var locked = false
    var pendingPrice: Double?      // price tapped in order book -> order form

    let api: HLAPI
    let socket: HLSocket
    @ObservationIgnored private var loops: [Task<Void, Never>] = []
    @ObservationIgnored private var lastNonce: UInt64 = 0
    @ObservationIgnored private var lastAlertCheck = Date.distantPast
    @ObservationIgnored private var tick = 0

    init() {
        let d = UserDefaults.standard
        let net = HLNetwork(rawValue: d.string(forKey: "network") ?? "") ?? .mainnet
        network = net
        api = HLAPI(network: net)
        socket = HLSocket(url: net.ws)
        if let data = d.data(forKey: "accounts"), let a = try? JSONDecoder().decode([Account].self, from: data) { accounts = a }
        if let s = d.string(forKey: "activeAccount") { activeAccountId = UUID(uuidString: s) }
        favorites = Set(d.stringArray(forKey: "favorites") ?? ["BTC", "ETH", "HYPE", "SOL"])
        if let data = d.data(forKey: "alerts"), let a = try? JSONDecoder().decode([PriceAlert].self, from: data) { alerts = a }
        if d.object(forKey: "slippage") != nil { slippage = d.double(forKey: "slippage") }
        if d.object(forKey: "confirmOrders") != nil { confirmOrders = d.bool(forKey: "confirmOrders") }
        if d.object(forKey: "haptics") != nil { haptics = d.bool(forKey: "haptics") }
        biometricLock = d.bool(forKey: "biometricLock")
        if d.object(forKey: "showChart") != nil { showChart = d.bool(forKey: "showChart") }
        minTradeUsd = d.double(forKey: "minTradeUsd")
        if let data = d.data(forKey: "indicators"), let ind = try? JSONDecoder().decode([IndicatorConfig].self, from: data) { indicators = ind }
        if d.object(forKey: "showVolume") != nil { showVolume = d.bool(forKey: "showVolume") }
        logScale = d.bool(forKey: "logScale")
        tradeLayout = TradeLayout(rawValue: d.string(forKey: "tradeLayout") ?? "") ?? .sheet
        lastOrderType = d.string(forKey: "lastOrderType") ?? "market"
        if d.object(forKey: "chartHeight") != nil { chartHeight = min(560, max(140, d.double(forKey: "chartHeight"))) }
        if let iv = d.stringArray(forKey: "visibleIntervals") {
            let parsed = iv.compactMap(CandleInterval.init(rawValue:))
            if !parsed.isEmpty { visibleIntervals = parsed }
        }
        selectedCoin = d.string(forKey: "selectedCoin") ?? "BTC"
        interval = CandleInterval(rawValue: d.string(forKey: "interval") ?? "") ?? .h1
        locked = biometricLock
        if activeAccountId == nil { activeAccountId = accounts.first?.id }

        socket.onMessage = { [weak self] ch, data in self?.handle(channel: ch, data: data) }
        socket.onStatus = { [weak self] c in
            self?.wsConnected = c
            if c { self?.wsError = nil }
        }
        socket.onError = { [weak self] e in self?.wsError = e }
    }

    @ObservationIgnored private var loading = true
    private func save() {
        guard !loading else { return }
        let d = UserDefaults.standard
        d.set(network.rawValue, forKey: "network")
        d.set(try? JSONEncoder().encode(accounts), forKey: "accounts")
        d.set(activeAccountId?.uuidString, forKey: "activeAccount")
        d.set(Array(favorites), forKey: "favorites")
        d.set(try? JSONEncoder().encode(alerts), forKey: "alerts")
        d.set(slippage, forKey: "slippage")
        d.set(confirmOrders, forKey: "confirmOrders")
        d.set(haptics, forKey: "haptics")
        d.set(biometricLock, forKey: "biometricLock")
        d.set(showChart, forKey: "showChart")
        d.set(selectedCoin, forKey: "selectedCoin")
        d.set(interval.rawValue, forKey: "interval")
        d.set(language.rawValue, forKey: "language")
        d.set(theme.rawValue, forKey: "theme")
        d.set(minTradeUsd, forKey: "minTradeUsd")
        d.set(try? JSONEncoder().encode(indicators), forKey: "indicators")
        d.set(showVolume, forKey: "showVolume")
        d.set(chartHeight, forKey: "chartHeight")
        d.set(logScale, forKey: "logScale")
        d.set(tradeLayout.rawValue, forKey: "tradeLayout")
        d.set(lastOrderType, forKey: "lastOrderType")
        d.set(visibleIntervals.map(\.rawValue), forKey: "visibleIntervals")
    }

    // MARK: Derived

    var account: Account? { accounts.first { $0.id == activeAccountId } }
    var userAddress: String? { account.map { ($0.vaultAddress?.isEmpty == false ? $0.vaultAddress! : $0.address).lowercased() } }
    var canTrade: Bool { account?.kind.canTrade ?? false }
    var selectedMarket: Market? { marketById[selectedCoin] }
    var unrealizedPnl: Double { positions.reduce(0) { $0 + $1.unrealizedPnl } }

    func market(_ coin: String) -> Market? { marketById[coin] }
    func displayName(_ coin: String) -> String { marketById[coin]?.name ?? coin }
    func mid(_ coin: String) -> Double {
        if let m = mids[coin], m > 0 { return m }
        return marketById[coin]?.midPx ?? marketById[coin]?.markPx ?? 0
    }
    /// Mid and spread from the live bbo, falling back to the order-book snapshot.
    var topMid: Double? { bbo.map { ($0.bid + $0.ask) / 2 } ?? book.mid }
    var topSpread: Double? { bbo.map { $0.ask - $0.bid } ?? book.spread }

    /// Freshest price for display: last trade (same source as the chart's last candle) for the
    /// selected market, then the order-book mid, then allMids.
    func lastPrice(_ coin: String) -> Double {
        if coin == selectedCoin {
            if let t = trades.first { return t.px }
            if let m = topMid { return m }
        }
        return mid(coin)
    }

    func position(_ coin: String) -> Position? { positions.first { $0.coin == coin } }
    func orders(for coin: String) -> [OpenOrder] { openOrders.filter { $0.coin == coin } }

    /// USD price of a spot token (via its /USDC market).
    func spotPrice(_ coin: String) -> Double {
        if coin == "USDC" { return 1 }
        guard let m = spots.first(where: { $0.base == coin && $0.quote == "USDC" }) else { return 0 }
        return mid(m.id)
    }

    var spotValue: Double {
        var total = 0.0
        for b in spotBalances { total += b.total * spotPrice(b.coin) }
        return total
    }

    var usdcSpot: Double { spotBalances.first { $0.coin == "USDC" }?.available ?? 0 }

    // MARK: Lifecycle

    func start() {
        loading = false
        guard loops.isEmpty else { return }
        socket.connect()
        socket.subscribe(.map([("type", .str("allMids"))]))
        subscribeCoin(selectedCoin)
        subscribeUser()
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollBook()
                try? await Task.sleep(for: .seconds(1))
            }
        })
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshMarkets()
                try? await Task.sleep(for: .seconds(15))
            }
        })
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshAccount()
                try? await Task.sleep(for: .seconds(3))
            }
        })
        Task { await loadCandles() }
        Task { await refreshHistory() }
        Task { await refreshFees() }
    }

    func stop() {
        loops.forEach { $0.cancel() }
        loops.removeAll()
        socket.disconnect()
    }

    private func networkChanged() {
        guard !loading else { return }
        api.network = network
        clearAccountState()
        perps = []; spots = []; hip3 = []; perpDexs = []; marketById = [:]; mids = [:]; metaLoaded = false
        socket.setURL(network.ws)
        Task {
            await refreshMarkets()
            await loadCandles()
            await refreshAccount()
            await refreshHistory()
        }
    }

    private func clearAccountState() {
        summary = AccountSummary(); positions = []; openOrders = []; fills = []; fundingHistory = []
        mainPositions = []; dexPositions = [:]; dexSummaries = [:]; activeDexes = []
        ledger = []; spotBalances = []; twaps = []; portfolioHistory = []; accountError = nil
        activeAsset = ActiveAssetData()
    }

    @ObservationIgnored private var subscribedUser: String?

    private func accountChanged() {
        guard !loading else { return }
        clearAccountState()
        subscribeUser()
        Task {
            await refreshAccount()
            await refreshHistory()
            await refreshFees()
        }
    }

    private func subscribeUser() {
        if let u = subscribedUser {
            for t in ["userFills", "orderUpdates", "notification", "userEvents"] {
                socket.unsubscribe(.map([("type", .str(t)), ("user", .str(u))]))
            }
            socket.unsubscribe(.map([("type", .str("activeAssetData")), ("user", .str(u)), ("coin", .str(selectedCoin))]))
        }
        subscribedUser = userAddress
        guard let u = userAddress else { return }
        for t in ["userFills", "orderUpdates", "notification"] {
            socket.subscribe(.map([("type", .str(t)), ("user", .str(u))]))
        }
        if marketById[selectedCoin]?.isSpot == false {
            socket.subscribe(.map([("type", .str("activeAssetData")), ("user", .str(u)), ("coin", .str(selectedCoin))]))
        }
    }

    private func coinSubs(_ coin: String) -> [MP] {
        var subs: [MP] = [
            l2Sub(coin, bookSigFigs),
            .map([("type", .str("trades")), ("coin", .str(coin))]),
            .map([("type", .str("candle")), ("coin", .str(coin)), ("interval", .str(interval.rawValue))]),
            .map([("type", .str("activeAssetCtx")), ("coin", .str(coin))]),
            .map([("type", .str("bbo")), ("coin", .str(coin))]),
        ]
        if let u = userAddress, marketById[coin]?.isSpot != true {
            subs.append(.map([("type", .str("activeAssetData")), ("user", .str(u)), ("coin", .str(coin))]))
        }
        return subs
    }

    /// Applies an l2Book snapshot. WebSocket snapshots always apply (the stream is ordered); REST
    /// snapshots only fill in when the stream has been quiet (their timestamps use a different clock).
    private func applyBookSnapshot(_ data: JSON, fromSocket: Bool) {
        if fromSocket {
            lastSocketBookAt = Date()
        } else if Date().timeIntervalSince(lastSocketBookAt) < 1.5 {
            return
        }
        let lv = data["levels"]
        func parse(_ a: JSON) -> [BookLevel] { a.array.map { BookLevel(px: $0["px"].dbl, sz: $0["sz"].dbl, n: $0["n"].int ?? 0) } }
        book = OrderBook(bids: parse(lv[0]), asks: parse(lv[1]), time: Date(timeIntervalSince1970: data["time"].dbl / 1000))
        bookReceivedAt = Date()
    }

    private func flushMids() {
        midsFlushScheduled = false
        guard !pendingMids.isEmpty else { return }
        var m = mids
        for (k, v) in pendingMids { m[k] = v }
        pendingMids.removeAll(keepingCapacity: true)
        mids = m        // one observable change per batch
        checkAlerts()
    }

    /// REST fallback: while the trade screen is open, fetch the book every second so the ladder
    /// stays fresh even if WebSocket snapshots arrive late.
    private func pollBook() async {
        guard tab == .trade, Date().timeIntervalSince(lastSocketBookAt) >= 1.5 else { return }
        let coin = selectedCoin, sig = bookSigFigs
        var extra: [(String, MP)] = [("coin", .str(coin))]
        if let sig { extra.append(("nSigFigs", .int(Int64(sig)))) }
        guard let j = try? await api.info(type: "l2Book", extra),
              coin == selectedCoin, sig == bookSigFigs, j["coin"].str == coin else { return }
        applyBookSnapshot(j, fromSocket: false)
    }

    private func l2Sub(_ coin: String, _ sig: Int?) -> MP {
        var kv: [(String, MP)] = [("type", .str("l2Book")), ("coin", .str(coin))]
        if let sig { kv.append(("nSigFigs", .int(Int64(sig)))) }
        return .map(kv)
    }

    private func subscribeCoin(_ coin: String) { coinSubs(coin).forEach { socket.subscribe($0) } }

    private func coinChanged(old: String) {
        guard !loading else { return }
        let oldInterval = interval
        socket.unsubscribe(l2Sub(old, bookSigFigs))
        socket.unsubscribe(.map([("type", .str("trades")), ("coin", .str(old))]))
        socket.unsubscribe(.map([("type", .str("candle")), ("coin", .str(old)), ("interval", .str(oldInterval.rawValue))]))
        socket.unsubscribe(.map([("type", .str("activeAssetCtx")), ("coin", .str(old))]))
        socket.unsubscribe(.map([("type", .str("bbo")), ("coin", .str(old))]))
        if let u = userAddress { socket.unsubscribe(.map([("type", .str("activeAssetData")), ("user", .str(u)), ("coin", .str(old))])) }
        book = OrderBook(); bookReceivedAt = .distantPast; bbo = nil; trades = []; candles = []; activeAsset = ActiveAssetData()
        pendingPrice = nil
        subscribeCoin(selectedCoin)
        Task { await loadCandles() }
    }

    private func intervalChanged(old: CandleInterval) {
        guard !loading else { return }
        socket.unsubscribe(.map([("type", .str("candle")), ("coin", .str(selectedCoin)), ("interval", .str(old.rawValue))]))
        socket.subscribe(.map([("type", .str("candle")), ("coin", .str(selectedCoin)), ("interval", .str(interval.rawValue))]))
        candles = []
        Task { await loadCandles() }
    }

    private func bookAggChanged(old: Int?) {
        socket.unsubscribe(l2Sub(selectedCoin, old))
        book = OrderBook()
        socket.subscribe(l2Sub(selectedCoin, bookSigFigs))
    }

    func toggleIntervalVisibility(_ iv: CandleInterval) {
        if let i = visibleIntervals.firstIndex(of: iv) {
            if visibleIntervals.count > 1 { visibleIntervals.remove(at: i) }
        } else {
            visibleIntervals.append(iv)
            visibleIntervals.sort { $0.seconds < $1.seconds }
        }
    }

    func reconnectSocket() {
        socket.disconnect()
        socket.connect()
    }

    func sceneActive(_ active: Bool) {
        if active {
            if loops.isEmpty { start() }
            else {
                socket.connect()
                Task { await refreshAccount(); await refreshMarkets() }
            }
        } else {
            if biometricLock { locked = true }
        }
    }

    // MARK: REST refresh

    func refreshMarkets() async {
        do {
            async let perpReq = api.info(type: "metaAndAssetCtxs")
            async let spotReq = api.info(type: "spotMetaAndAssetCtxs")
            let (p, s) = try await (perpReq, spotReq)
            parsePerps(p)
            parseSpots(s)
            metaLoaded = true
            let firstHip3 = hip3.isEmpty
            await refreshHip3()
            if firstHip3 && !hip3.isEmpty { await refreshAllAccounts() }
            if marketById[selectedCoin] == nil, let first = perps.first { selectedCoin = first.id }
        } catch {
            if !metaLoaded { show(.error, L("Failed to load markets: {0}", error.localizedDescription)) }
        }
    }

    /// Loads HIP-3 builder dexes (stocks like xyz:NVDA, indices, ...) and their markets.
    func refreshHip3() async {
        if let list = await tryInfo("perpDexs", []) {
            var dexes: [PerpDex] = []
            for (i, d) in list.array.dropFirst().enumerated() {
                let name = d["name"].str
                guard !name.isEmpty else { continue }
                let old = perpDexs.first { $0.name == name }
                dexes.append(PerpDex(name: name, fullName: d["fullName"].string ?? name, offset: 110000 + i * 10000,
                                     collateralToken: old?.collateralToken))
            }
            let newNames = Set(dexes.map(\.name)).subtracting(perpDexs.map(\.name))
            perpDexs = dexes
            for n in newNames { socket.subscribe(.map([("type", .str("allMids")), ("dex", .str(n))])) }
        }
        var out: [Market] = []
        for (k, d) in perpDexs.enumerated() {
            guard let j = await tryInfo("metaAndAssetCtxs", [("dex", .str(d.name))]) else { continue }
            if let c = j[0]["collateralToken"].int { perpDexs[k].collateralToken = c }
            out += parsePerpUniverse(j, offset: d.offset, dex: d.name)
        }
        hip3 = out
        for m in out { marketById[m.id] = m }
    }

    private func parsePerpUniverse(_ j: JSON, offset: Int, dex: String) -> [Market] {
        let universe = j[0]["universe"].array
        let ctxs = j[1].array
        var out: [Market] = []
        for (i, u) in universe.enumerated() {
            if u["isDelisted"].bool == true { continue }
            let coin = u["name"].str
            let short = coin.contains(":") ? String(coin.split(separator: ":", maxSplits: 1)[1]) : coin
            let mode = u["marginMode"].str
            let isolatedOnly = (u["onlyIsolated"].bool ?? false) || mode == "strictIsolated" || mode == "noCross"
            var m = Market(id: coin, name: short, base: short, quote: "USD", asset: offset + i, isSpot: false,
                           szDecimals: u["szDecimals"].int ?? 0, maxLeverage: u["maxLeverage"].int ?? 1,
                           onlyIsolated: isolatedOnly, dex: dex)
            if i < ctxs.count { apply(ctx: ctxs[i], to: &m) }
            out.append(m)
        }
        return out
    }

    private func parsePerps(_ j: JSON) {
        let out = parsePerpUniverse(j, offset: 0, dex: "")
        perps = out
        for m in out { marketById[m.id] = m }
    }

    private func parseSpots(_ j: JSON) {
        var tokens: [Int: SpotToken] = [:]
        for t in j[0]["tokens"].array {
            let idx = t["index"].int ?? 0
            tokens[idx] = SpotToken(index: idx, name: t["name"].str, szDecimals: t["szDecimals"].int ?? 0,
                                    weiDecimals: t["weiDecimals"].int ?? 0, tokenId: t["tokenId"].str)
        }
        spotTokens = tokens
        var ctxByCoin: [String: JSON] = [:]
        for c in j[1].array { ctxByCoin[c["coin"].str] = c }
        var out: [Market] = []
        for u in j[0]["universe"].array {
            let tk = u["tokens"].array.compactMap(\.int)
            guard tk.count == 2, let base = tokens[tk[0]], let quote = tokens[tk[1]] else { continue }
            let coin = u["name"].str
            let idx = u["index"].int ?? 0
            var m = Market(id: coin, name: "\(base.name)/\(quote.name)", base: base.name, quote: quote.name,
                           asset: 10000 + idx, isSpot: true, szDecimals: base.szDecimals, maxLeverage: 1, onlyIsolated: false)
            if let c = ctxByCoin[coin] { apply(ctx: c, to: &m) }
            out.append(m)
        }
        spots = out
        for m in out { marketById[m.id] = m }
    }

    private func apply(ctx c: JSON, to m: inout Market) {
        m.markPx = c["markPx"].dbl
        m.midPx = c["midPx"].double ?? m.markPx
        m.oraclePx = c["oraclePx"].dbl
        m.prevDayPx = c["prevDayPx"].dbl
        m.dayNtlVlm = c["dayNtlVlm"].dbl
        m.funding = c["funding"].dbl
        m.openInterest = c["openInterest"].dbl
        m.premium = c["premium"].dbl
    }

    func refreshAccount() async {
        guard let user = userAddress else { return }
        do {
            async let chReq = api.info(type: "clearinghouseState", [("user", .str(user))])
            async let spReq = api.info(type: "spotClearinghouseState", [("user", .str(user))])
            let (ch, sp) = try await (chReq, spReq)
            guard user == userAddress else { return }
            let ms = ch["marginSummary"], cs = ch["crossMarginSummary"]
            summary = AccountSummary(accountValue: ms["accountValue"].dbl, totalNtlPos: ms["totalNtlPos"].dbl,
                                     totalMarginUsed: ms["totalMarginUsed"].dbl, withdrawable: ch["withdrawable"].dbl,
                                     maintenanceMargin: ch["crossMaintenanceMarginUsed"].dbl,
                                     crossAccountValue: cs["accountValue"].dbl)
            mainPositions = ch["assetPositions"].array.map(Position.init).filter { $0.szi != 0 }
            spotBalances = sp["balances"].array.map(SpotBalance.init).filter { $0.total != 0 }
            accountError = nil
            if tick % 3 == 0 { await refreshDexAccounts(user) }
            positions = mainPositions + perpDexs.flatMap { dexPositions[$0.name] ?? [] }
            if tick % 3 == 0 { await refreshOrders() }
            tick += 1
        } catch {
            accountError = error.localizedDescription
        }
    }

    /// Positions and margin on HIP-3 dexes (each dex has its own clearinghouse).
    private func refreshDexAccounts(_ user: String) async {
        for d in perpDexs {
            guard let ch = await tryInfo("clearinghouseState", [("user", .str(user)), ("dex", .str(d.name))]), user == userAddress else { continue }
            let ms = ch["marginSummary"], cs = ch["crossMarginSummary"]
            let sum = AccountSummary(accountValue: ms["accountValue"].dbl, totalNtlPos: ms["totalNtlPos"].dbl,
                                     totalMarginUsed: ms["totalMarginUsed"].dbl, withdrawable: ch["withdrawable"].dbl,
                                     maintenanceMargin: ch["crossMaintenanceMarginUsed"].dbl,
                                     crossAccountValue: cs["accountValue"].dbl)
            let pos = ch["assetPositions"].array.map(Position.init).filter { $0.szi != 0 }
            dexSummaries[d.name] = sum
            dexPositions[d.name] = pos
            if sum.accountValue > 0 || !pos.isEmpty { activeDexes.insert(d.name) }
        }
    }

    func refreshOrders() async {
        guard let user = userAddress else { return }
        var dexes = activeDexes
        if let m = selectedMarket, m.isHip3 { dexes.insert(m.dex) }
        guard let o = await tryInfo("frontendOpenOrders", [("user", .str(user))]), user == userAddress else { return }
        var all = o.array.map(OpenOrder.init)
        for d in dexes.sorted() {
            if let j = await tryInfo("frontendOpenOrders", [("user", .str(user)), ("dex", .str(d))]) {
                all += j.array.map(OpenOrder.init)
            }
        }
        guard user == userAddress else { return }
        var seen = Set<Int64>()
        openOrders = all.filter { seen.insert($0.oid).inserted }
    }

    /// Full refresh including HIP-3 dex clearinghouses.
    func refreshAllAccounts() async {
        if let u = userAddress { await refreshDexAccounts(u) }
        await refreshAccount()
        await refreshOrders()
    }

    /// Withdrawable margin for the dex a market trades on.
    func withdrawable(for m: Market) -> Double {
        m.isHip3 ? (dexSummaries[m.dex]?.withdrawable ?? 0) : summary.withdrawable
    }

    /// Value of all perp accounts (main + HIP-3 dexes).
    var totalPerpValue: Double {
        summary.accountValue + dexSummaries.values.reduce(0) { $0 + $1.accountValue }
    }

    func refreshHistory() async {
        guard let user = userAddress else { return }
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        let week: UInt64 = 7 * 24 * 3600 * 1000
        async let f = tryInfo("userFills", [("user", .str(user)), ("aggregateByTime", .bool(true))])
        async let fu = tryInfo("userFunding", [("user", .str(user)), ("startTime", .int(Int64(now - 4 * week)))])
        async let l = tryInfo("userNonFundingLedgerUpdates", [("user", .str(user)), ("startTime", .int(Int64(now - 52 * week)))])
        async let t = tryInfo("twapHistory", [("user", .str(user))])
        async let p = tryInfo("portfolio", [("user", .str(user))])
        let (fills, funding, ledger, twap, portfolio) = await (f, fu, l, t, p)
        guard user == userAddress else { return }
        if let fills { self.fills = fills.array.map(Fill.init).sorted { $0.time > $1.time } }
        if let funding { fundingHistory = funding.array.map(FundingEntry.init).sorted { $0.time > $1.time } }
        if let ledger { self.ledger = ledger.array.map(LedgerEntry.init).sorted { $0.time > $1.time } }
        if let twap { parseTwaps(twap) }
        if let portfolio { parsePortfolio(portfolio) }
    }

    private func tryInfo(_ type: String, _ extra: [(String, MP)]) async -> JSON? {
        try? await api.info(type: type, extra)
    }

    private func parseTwaps(_ j: JSON) {
        var out: [TwapState] = []
        for e in j.array {
            let status = e["status"]["status"].string ?? e["status"].str
            guard status == "activated" else { continue }
            let s = e["state"]
            guard let id = e["twapId"].int64 else { continue }
            out.append(TwapState(id: id, coin: s["coin"].str, isBuy: s["side"].str == "B", sz: s["sz"].dbl,
                                 executedSz: s["executedSz"].dbl, executedNtl: s["executedNtl"].dbl,
                                 minutes: s["minutes"].int ?? 0,
                                 started: Date(timeIntervalSince1970: s["timestamp"].dbl / 1000),
                                 reduceOnly: s["reduceOnly"].bool ?? false))
        }
        twaps = out.filter { $0.endsAt > Date() }
    }

    private func parsePortfolio(_ j: JSON) {
        // [["day", {...}], ["week", {...}], ["month", {...}], ["allTime", {...}], ...]
        for entry in j.array where entry[0].str == "month" {
            portfolioHistory = entry[1]["accountValueHistory"].array.map {
                (Date(timeIntervalSince1970: $0[0].dbl / 1000), $0[1].dbl)
            }
        }
    }

    func refreshFees() async {
        guard let user = userAddress else { return }
        if let f = try? await api.info(type: "userFees", [("user", .str(user))]) {
            if let t = f["userCrossRate"].double { takerFee = t }
            if let m = f["userAddRate"].double { makerFee = m }
        }
    }

    func loadCandles() async {
        let coin = selectedCoin, iv = interval
        candlesLoading = true
        defer { candlesLoading = false }
        let end = Date().timeIntervalSince1970 * 1000
        let start = end - iv.seconds * 1000 * 400
        let req = MP.map([("coin", .str(coin)), ("interval", .str(iv.rawValue)),
                          ("startTime", .int(Int64(start))), ("endTime", .int(Int64(end)))])
        guard let j = try? await api.info(type: "candleSnapshot", [("req", req)]), coin == selectedCoin, iv == interval else { return }
        candles = j.array.map(Candle.init).sorted { $0.t < $1.t }
    }

    // MARK: WebSocket

    private func handle(channel: String, data: JSON) {
        switch channel {
        case "allMids":
            // Many allMids streams (main + every HIP-3 dex): buffer and publish at most twice a second
            // so they don't keep the main thread busy ahead of order-book and trade messages.
            for (k, v) in data["mids"].object { if let d = v.double { pendingMids[k] = d } }
            if !midsFlushScheduled {
                midsFlushScheduled = true
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(500))
                    self?.flushMids()
                }
            }
        case "bbo":
            // Best bid/ask arrive on every change; used for the mid/spread line only. The ladder itself
            // always comes from the latest consistent l2Book snapshot (patching it made levels vanish).
            guard data["coin"].str == selectedCoin else { return }
            let pair = data["bbo"]
            if let b = pair[0]["px"].double, let a = pair[1]["px"].double, a >= b { bbo = BestBidAsk(bid: b, ask: a) }
        case "l2Book":
            guard data["coin"].str == selectedCoin else { return }
            applyBookSnapshot(data, fromSocket: true)
        case "trades":
            let new = data.array.filter { $0["coin"].str == selectedCoin }.map {
                PublicTrade(px: $0["px"].dbl, sz: $0["sz"].dbl, isBuy: $0["side"].str == "B",
                            time: Date(timeIntervalSince1970: $0["time"].dbl / 1000), tid: $0["tid"].int64 ?? Int64.random(in: 0...Int64.max))
            }
            guard !new.isEmpty else { return }
            var seen = Set(trades.map(\.tid))
            let fresh = new.reversed().filter { seen.insert($0.tid).inserted }
            trades = Array((fresh + trades).prefix(500))
        case "candle":
            guard data["s"].str == selectedCoin, data["i"].str == interval.rawValue else { return }
            let c = Candle(data)
            if let last = candles.last, last.t == c.t { candles[candles.count - 1] = c }
            else if candles.last.map({ c.t > $0.t }) ?? true { candles.append(c) }
        case "activeAssetCtx", "activeSpotAssetCtx":
            let coin = data["coin"].str
            guard var m = marketById[coin] else { return }
            apply(ctx: data["ctx"], to: &m)
            marketById[coin] = m
        case "activeAssetData":
            guard data["coin"].str == selectedCoin else { return }
            let lev = data["leverage"]
            activeAsset = ActiveAssetData(leverage: lev["value"].int ?? 1, isCross: lev["type"].str != "isolated",
                                          maxBuy: data["maxTradeSzs"][0].dbl, maxSell: data["maxTradeSzs"][1].dbl,
                                          availableBuy: data["availableToTrade"][0].dbl, availableSell: data["availableToTrade"][1].dbl)
        case "userFills":
            guard data["user"].str.lowercased() == userAddress, data["isSnapshot"].bool != true else { return }
            let new = data["fills"].array.map(Fill.init)
            guard !new.isEmpty else { return }
            fills = (new + fills).sorted { $0.time > $1.time }
            let f = new[0]
            let total = new.reduce(0) { $0 + $1.sz }
            show(.success, L("Filled: {0} {1} {2} at {3}", f.isBuy ? L("buy") : L("sell"), Fmt.num(total, market(f.coin)?.szDecimals ?? 4), displayName(f.coin), Fmt.price(f.px)))
            Haptics.success(enabled: haptics)
            Task { await refreshAccount(); await refreshOrders() }
        case "orderUpdates":
            Task { await refreshOrders() }
        case "notification":
            let text = data["notification"].str
            if !text.isEmpty { show(.info, text) }
        default:
            break
        }
    }

    // MARK: Alerts

    private func checkAlerts() {
        guard !alerts.isEmpty, Date().timeIntervalSince(lastAlertCheck) > 1 else { return }
        lastAlertCheck = Date()
        var fired: [PriceAlert] = []
        for a in alerts {
            guard let px = mids[a.coin] else { continue }
            if (a.above && px >= a.price) || (!a.above && px <= a.price) { fired.append(a) }
        }
        guard !fired.isEmpty else { return }
        for a in fired {
            let text = L("{0} {1} {2} — now {3}", a.name, a.above ? L("above") : L("below"), Fmt.price(a.price), Fmt.price(mids[a.coin] ?? 0))
            Notifier.notify(title: L("Price alert"), body: text)
            show(.info, "🔔 " + text)
        }
        let firedIds = Set(fired.filter { !$0.repeating }.map(\.id))
        alerts.removeAll { firedIds.contains($0.id) }
        // Repeating alerts flip direction to avoid spamming.
        for a in fired where a.repeating {
            if let i = alerts.firstIndex(where: { $0.id == a.id }) { alerts[i].above.toggle() }
        }
    }

    // MARK: Toasts

    func show(_ kind: Toast.Kind, _ text: String) {
        let t = Toast(kind: kind, text: text)
        toast = t
        Task {
            try? await Task.sleep(for: .seconds(kind == .error ? 5 : 3))
            if toast?.id == t.id { toast = nil }
        }
    }

    // MARK: Signing helpers

    func nextNonce() -> UInt64 {
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        lastNonce = max(now, lastNonce + 1)
        return lastNonce
    }

    func wallet() throws -> HLWallet {
        guard let acc = account else { throw HLError(L("Add an account in Settings")) }
        guard acc.kind.canTrade else { throw HLError(L("Account is watch-only")) }
        guard let key = acc.privateKey else { throw HLError(L("Key not found in Keychain")) }
        return try HLWallet(privateKeyHex: key)
    }

    var vaultForActions: String? {
        guard let v = account?.vaultAddress, !v.isEmpty else { return nil }
        return v.lowercased()
    }

    /// Signs and posts an L1 action. Returns `response.data` on success.
    @discardableResult
    func submit(_ action: MP, vault: String?? = .none) async throws -> JSON {
        let w = try wallet()
        let nonce = nextNonce()
        let v: String? = vault ?? vaultForActions
        let digest = HLSigning.l1Digest(action, vault: v, nonce: nonce, expiresAfter: nil, isMainnet: network.isMainnet)
        let sig = w.sign(digest: digest)
        let res = try await api.exchange(action: action, nonce: nonce, signature: sig, vault: v)
        return try checkResponse(res)
    }

    /// EIP-712 chain id for user-signed actions: the wallet's chain for WalletConnect accounts.
    var userSignChainId: UInt64 {
        if account?.kind == .wallet { return account?.wcChainId ?? 42161 }
        return HLSigning.userSignChainId
    }

    @discardableResult
    func submitUser(_ a: UserSignedAction) async throws -> JSON {
        guard let acc = account, acc.kind.canTransfer else {
            throw HLError(L("Transfers and withdrawals require the main wallet private key (an API wallet cannot sign them)"))
        }
        let sig: HLSignature
        if acc.kind == .wallet {
            guard let topic = acc.wcTopic else { throw HLError(L("Wallet is not connected. Reconnect it in Settings.")) }
            sig = try await WalletConnectService.shared.signTypedData(
                topic: topic, address: acc.address, chainId: a.chainId, json: a.typedDataJSON(),
                wallet: acc.walletApp.flatMap(WalletApp.init(rawValue:)))
        } else {
            sig = try wallet().sign(digest: HLSigning.userSignedDigest(a))
        }
        let res = try await api.exchange(action: a.action, nonce: a.nonce, signature: sig, vault: nil)
        return try checkResponse(res)
    }

    private func checkResponse(_ res: JSON) throws -> JSON {
        guard res["status"].str == "ok" else {
            let msg = res["response"].string ?? res["error"].string ?? L("Unknown error")
            throw HLError(translate(msg))
        }
        let data = res["response"]["data"]
        // For order/cancel: statuses may contain per-item errors.
        let statuses = data["statuses"].array
        let errors = statuses.compactMap { $0["error"].string }
        if !errors.isEmpty && errors.count == statuses.count {
            throw HLError(translate(errors.joined(separator: "\n")))
        }
        if !errors.isEmpty { show(.error, translate(errors.joined(separator: "\n"))) }
        return data
    }

    func translate(_ msg: String) -> String {
        let map: [(String, String)] = [
            ("Insufficient margin", L("Insufficient margin")),
            ("Order must have minimum value", L("Minimum order value is $10")),
            ("Post only order would have immediately matched", L("Post-only order would have matched immediately")),
            ("Order could not immediately match", L("Order could not fill immediately (IOC): no liquidity within slippage")),
            ("Reduce only order would increase position", L("Reduce-only order would increase the position")),
            ("Price must be divisible by tick size", L("Price is not a multiple of the tick size")),
            ("does not exist", L("User/agent not found. Make sure the API wallet is approved at app.hyperliquid.xyz/API")),
            ("Too many cumulative requests", L("Too many requests for the account's trading volume")),
        ]
        for (k, v) in map where msg.contains(k) { return "\(v)\n(\(msg))" }
        return msg
    }

    // MARK: Account management

    func addAccount(_ a: Account, key: String?) {
        if let key { Keychain.set(key, for: a.keychainKey) }
        accounts.append(a)
        activeAccountId = a.id
    }

    func removeAccount(_ a: Account) {
        Keychain.delete(a.keychainKey)
        if let topic = a.wcTopic { WalletConnectService.shared.disconnect(topic: topic) }
        accounts.removeAll { $0.id == a.id }
        if activeAccountId == a.id { activeAccountId = accounts.first?.id }
    }

    func toggleFavorite(_ coin: String) {
        if favorites.contains(coin) { favorites.remove(coin) } else { favorites.insert(coin) }
    }

    func select(_ coin: String, openTrade: Bool = true) {
        selectedCoin = coin
        if openTrade { tab = .trade }
    }
}
