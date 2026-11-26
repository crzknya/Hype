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
    var activeAccountId: UUID? { didSet { activeSubAccount = nil; save(); accountChanged() } }
    /// Trading as a sub-account of the active (master) account: its address is used as the vault address.
    var activeSubAccount: String? { didSet { if oldValue != activeSubAccount { accountChanged() } } }
    var subAccounts: [SubAccount] = []
    var favorites: Set<String> = [] { didSet { save() } }
    var alerts: [PriceAlert] = [] { didSet { save() } }
    var slippage: Double = 0.08 { didSet { save() } }   // web default 8%
    var confirmOrders = true { didSet { save() } }
    var haptics = true { didSet { save() } }
    /// Fill notifications: in-app toast, sound, and a local notification while the app is in the background.
    /// Small CPU / memory / FPS overlay for diagnosing heat and battery use.
    var perfOverlay = false
    /// Experimental energy saving: market streams only while the Trade tab is open, slower UI updates.
    var energySaving = false { didSet { save(); if oldValue != energySaving { updateMarketStreams() } } }
    /// Certificate pinning for the Hyperliquid API (Settings → Security); read by the session delegate.
    var certPinning = CertificatePinning.enabled {
        didSet {
            UserDefaults.standard.set(certPinning, forKey: CertificatePinning.enabledKey)
            if oldValue != certPinning { reconnectSocket() }
        }
    }
    var fillToasts = true { didSet { save() } }
    var fillSound = false { didSet { save() } }
    var backgroundFillAlerts = false { didSet { save() } }
    var biometricLock = false { didSet { save() } }
    var selectedCoin: String = "BTC" { didSet { save(); if oldValue != selectedCoin { coinChanged(old: oldValue) } } }
    var interval: CandleInterval = .h1 { didSet { save(); if oldValue != interval { intervalChanged(old: oldValue) } } }
    var bookSigFigs: Int? = nil { didSet { if oldValue != bookSigFigs { bookAggChanged(old: oldValue) } } }
    var showChart = true { didSet { save() } }
    var minTradeUsd: Double = 0 { didSet { save() } }
    var indicators: [IndicatorConfig] = IndicatorConfig.defaults { didSet { save() } }
    var showVolume = true { didSet { save() } }
    var chartHeight: Double = 250 { didSet { save() } }
    /// Chart bar width (zoom), kept when switching markets or intervals; stored on its own key (changes often).
    @ObservationIgnored var chartSpacing: CGFloat = CGFloat(UserDefaults.standard.object(forKey: "chartSpacing") as? Double ?? 6) {
        didSet { UserDefaults.standard.set(Double(chartSpacing), forKey: "chartSpacing") }
    }
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
    var takerFee: Double = 0.00045        // perps, before referral discount
    var makerFee: Double = 0.00015
    var spotTakerFee: Double = 0.0007
    var spotMakerFee: Double = 0.0004
    var referralDiscount: Double = 0
    /// Market-order notional limits by max leverage, and markets at their open-interest cap.
    @ObservationIgnored var maxMarketNtls: [(leverage: Int, notional: Double)] = []
    var perpsAtOiCap: Set<String> = []
    /// Market categories (perpCategories: stocks, commodities, indices, fx, …) and HIP-3 descriptions.
    var categories: [String: String] = [:]
    /// HIP-4 outcome markets.
    var outcomeTemplates: [String: OutcomeTemplate] = [:]
    var outcomeSpecs: [OutcomeSpec] = []
    var outcomeQuestions: [OutcomeQuestion] = []
    @ObservationIgnored var outcomeCtx: [String: (mid: Double, mark: Double, volume: Double)] = [:]
    var annotations: [String: String] = [:]
    /// Client-side chase orders (repriced while the app runs) and their runner.
    var chases: [ChaseOrder] = []
    @ObservationIgnored var chaseTask: Task<Void, Never>?
    /// When the open-orders list was last updated (stream or REST) and last fetched for chases.
    @ObservationIgnored var ordersUpdatedAt = Date.distantPast
    @ObservationIgnored var chaseOrdersFetchAt = Date.distantPast
    /// Order history (historicalOrders) and TWAP slice fills.
    var orderHistory: [HistoricalOrder] = []
    var twapFills: [Fill] = []
    /// USDC routes recommended by Hyperliquid ("cctp" or "bridge").
    var usdcWithdrawRoute = "cctp"
    var usdcDepositRoute = "cctp"
    var portfolioHistory: [(Date, Double)] = []
    /// "day" / "week" / "month" / "allTime" → account value & PnL history from the `portfolio` request.
    var portfolioRanges: [String: PortfolioRange] = [:]
    var accountError: String?
    /// Account mode from `userAbstraction`: "unifiedAccount", "portfolioMargin", "disabled", "dexAbstraction", "default".
    var abstraction: String?
    /// Spot token index → amount available after maintenance margin (unified / portfolio margin accounts).
    var availableAfterMaintenance: [Int: Double] = [:]
    var vaultEquity: Double = 0
    var stakedHype: Double = 0

    // MARK: UI
    var tab: AppTab = .markets { didSet { if oldValue != tab { updateMarketStreams() } } }
    /// Bumped when the user taps the Trade tab while it is already open (switches Chart ⇄ Order).
    var tradeTabReselected = 0
    var toast: Toast?
    var locked = false
    var pendingPrice: Double?      // price tapped in order book -> order form

    let api: HLAPI
    let socket: HLSocket
    @ObservationIgnored private var loops: [Task<Void, Never>] = []
    @ObservationIgnored private var lastNonce: UInt64 = 0
    @ObservationIgnored private var lastAlertCheck = Date.distantPast
    @ObservationIgnored private var tick = 0
    /// Last WebSocket account / open-orders snapshot; REST polling only runs while these are stale.
    @ObservationIgnored private var accountStreamAt = Date.distantPast
    @ObservationIgnored private var ordersStreamAt = Date.distantPast
    var accountStreamLive: Bool { Date().timeIntervalSince(accountStreamAt) < 8 }

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
        if d.object(forKey: "fillToasts") != nil { fillToasts = d.bool(forKey: "fillToasts") }
        fillSound = d.bool(forKey: "fillSound")
        backgroundFillAlerts = d.bool(forKey: "backgroundFillAlerts")
        biometricLock = d.bool(forKey: "biometricLock")
        energySaving = d.bool(forKey: "energySaving")
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
            guard let self else { return }
            let reconnected = c && !self.wsConnected
            self.wsConnected = c
            if c { self.wsError = nil }
            // After a dropped connection the account streams resume without the gap: fill it from REST.
            if reconnected { Task { await self.refreshHistoryThrottled() } }
        }
        socket.onError = { [weak self] e in
            self?.wsError = CertificatePinning.failedRecently ? CertificatePinning.failureMessage : e
        }
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
        d.set(fillToasts, forKey: "fillToasts")
        d.set(fillSound, forKey: "fillSound")
        d.set(backgroundFillAlerts, forKey: "backgroundFillAlerts")
        d.set(biometricLock, forKey: "biometricLock")
        d.set(energySaving, forKey: "energySaving")
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
    var userAddress: String? {
        if let sub = activeSubAccount { return sub }
        return account.map { ($0.vaultAddress?.isEmpty == false ? $0.vaultAddress! : $0.address).lowercased() }
    }
    var canTrade: Bool { account?.kind.canTrade ?? false }
    /// Display names for addresses in the transfer history: sub-accounts and the master account.
    var ledgerNames: [String: String] {
        var n: [String: String] = [:]
        for sub in subAccounts { n[sub.address] = L("sub-account {0}", sub.name) }
        if let m = masterAddress, activeSubAccount != nil { n[m] = L("master account") }
        return n
    }

    /// The master account address (never a sub-account / vault).
    var masterAddress: String? { account?.address.lowercased() }
    var selectedMarket: Market? { marketById[selectedCoin] }
    var unrealizedPnl: Double { positions.reduce(0) { $0 + $1.unrealizedPnl } }

    func market(_ coin: String) -> Market? { marketById[coin] }
    func displayName(_ coin: String) -> String {
        if let m = marketById[coin] { return m.name }
        if let o = outcomeSide(of: coin) { return outcomeSideTitle(o.spec, o.side) }
        return coin
    }
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
        if coin.hasPrefix("+") { return mid("#" + coin.dropFirst()) }   // outcome tokens
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
        // Prices for every market (perps, HIP-3, spot) once a second — the stream the web app uses;
        // the documented allMids stream only pushes every ~10 s.
        socket.subscribe(.map([("type", .str("fastAssetCtxs"))]))
        marketStreamsPaused = energySaving && tab != .trade
        subscribeCoin(selectedCoin)
        subscribeUser()
        loops.append(Task { [weak self] in
            var n = 0
            while !Task.isCancelled {
                await self?.pollBook()
                n += 1
                // The l2 stream sends deltas without sequence numbers: take a fresh snapshot every 30 s so a
                // lost message cannot leave the ladder wrong for long.
                if n % 30 == 0 { self?.resyncBook() }
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
                // REST fallback while the account streams are silent (reconnect, older servers).
                if self?.accountStreamLive != true { await self?.refreshAccount() }
                try? await Task.sleep(for: .seconds(3))
            }
        })
        loops.append(Task { [weak self] in
            // Safety net: history (funding, fills, transfers) re-synced every 10 minutes.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(600))
                await self?.refreshHistoryThrottled()
            }
        })
        Task { await loadCandles() }
        Task { await refreshHistoryThrottled() }
        Task { await refreshFees() }
        Task { await loadLimits() }
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
        // Chases belong to the previous account: stop repricing (their orders stay as limit orders there).
        if chases.contains(where: { $0.status == .working }) {
            for i in chases.indices where chases[i].status == .working { chases[i].status = .stopped }
            show(.info, L("Chase orders stopped: the account changed. Their orders stay on the book as limit orders."))
        }
        summary = AccountSummary(); positions = []; openOrders = []; fills = []; fundingHistory = []
        mainPositions = []; dexPositions = [:]; dexSummaries = [:]; activeDexes = []
        ledger = []; spotBalances = []; twaps = []; portfolioHistory = []; portfolioRanges = [:]; accountError = nil
        orderHistory = []; twapFills = []
        abstraction = nil; availableAfterMaintenance = [:]; vaultEquity = 0; stakedHype = 0
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

    /// Live account streams used by app.hyperliquid.xyz: user state (account type, OI caps, vaults),
    /// clearinghouse states of every perp dex, spot balances, open orders and TWAPs on all dexes.
    private func accountSubs(_ u: String) -> [MP] {
        [.map([("type", .str("webData3")), ("user", .str(u))]),
         .map([("type", .str("allDexsClearinghouseState")), ("user", .str(u))]),
         .map([("type", .str("spotState")), ("user", .str(u))]),
         .map([("type", .str("openOrders")), ("user", .str(u)), ("dex", .str("ALL_DEXS"))]),
         .map([("type", .str("twapStates")), ("user", .str(u)), ("dex", .str("ALL_DEXS"))]),
         .map([("type", .str("userNonFundingLedgerUpdates")), ("user", .str(u))]),
         .map([("type", .str("userFundings")), ("user", .str(u))])]
    }

    private func subscribeUser() {
        if let u = subscribedUser {
            for t in ["userFills", "orderUpdates", "notification", "userEvents"] {
                socket.unsubscribe(.map([("type", .str(t)), ("user", .str(u))]))
            }
            for sub in accountSubs(u) { socket.unsubscribe(sub) }
            socket.unsubscribe(.map([("type", .str("activeAssetData")), ("user", .str(u)), ("coin", .str(selectedCoin))]))
        }
        subscribedUser = userAddress
        accountStreamAt = .distantPast
        ordersStreamAt = .distantPast
        guard let u = userAddress else { return }
        for t in ["userFills", "orderUpdates", "notification"] {
            socket.subscribe(.map([("type", .str(t)), ("user", .str(u))]))
        }
        for sub in accountSubs(u) { socket.subscribe(sub) }
        if marketById[selectedCoin]?.isSpot == false {
            socket.subscribe(.map([("type", .str("activeAssetData")), ("user", .str(u)), ("coin", .str(selectedCoin))]))
        }
    }

    /// Book, trades, candles and best bid/ask: only needed on the Trade tab (paused there in energy saving).
    private func marketSubs(_ coin: String) -> [MP] {
        [
            l2Sub(coin, bookSigFigs),
            .map([("type", .str("trades")), ("coin", .str(coin))]),
            .map([("type", .str("candle")), ("coin", .str(coin)), ("interval", .str(interval.rawValue))]),
            .map([("type", .str("bbo")), ("coin", .str(coin))]),
        ]
    }

    private func coinSubs(_ coin: String) -> [MP] {
        var subs: [MP] = marketStreamsPaused ? [] : marketSubs(coin)
        subs.append(.map([("type", .str("activeAssetCtx")), ("coin", .str(coin))]))
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

    /// Indicators are recomputed only when the candles or settings change, not on every view refresh.
    @ObservationIgnored private var layersCache: (key: String, layers: ChartLayers)?

    func chartLayers() -> ChartLayers {
        let last = candles.last
        let key = "\(candles.count)|\(candles.first?.t ?? 0)|\(last?.t ?? 0)|\(last?.c ?? 0)|\(last?.h ?? 0)|\(last?.l ?? 0)|\(last?.v ?? 0)|\(interval.rawValue)|\(indicators.hashValue)"
        if let c = layersCache, c.key == key { return c.layers }
        let layers = ChartLayers.build(candles, configs: indicators, interval: interval)
        layersCache = (key, layers)
        return layers
    }

    @ObservationIgnored private var pendingBbo: (coin: String, value: BestBidAsk)?
    @ObservationIgnored private var bboFlushScheduled = false
    @ObservationIgnored private var pendingCandles: [Double: Candle] = [:]
    @ObservationIgnored private var pendingCandlesKey = ""
    @ObservationIgnored private var candleFlushScheduled = false

    private func scheduleBboFlush() {
        guard !bboFlushScheduled else { return }
        bboFlushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.batchDelay(100, saving: 500) ?? .milliseconds(100))
            guard let self else { return }
            self.bboFlushScheduled = false
            if let p = self.pendingBbo, p.coin == self.selectedCoin, p.value != self.bbo { self.bbo = p.value }
            self.pendingBbo = nil
        }
    }

    private func scheduleCandleFlush() {
        guard !candleFlushScheduled else { return }
        candleFlushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.batchDelay(250, saving: 1000) ?? .milliseconds(250))
            guard let self else { return }
            self.candleFlushScheduled = false
            let batch = self.pendingCandles.values.sorted { $0.t < $1.t }
            self.pendingCandles = [:]
            guard self.pendingCandlesKey == "\(self.selectedCoin)|\(self.interval.rawValue)", !batch.isEmpty else { return }
            var list = self.candles
            for c in batch {
                if let last = list.last, last.t == c.t { list[list.count - 1] = c }
                else if list.last.map({ c.t > $0.t }) ?? true { list.append(c) }
            }
            self.candles = list
        }
    }

    private func scheduleMidsFlush() {
        guard !midsFlushScheduled else { return }
        midsFlushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.batchDelay(300, saving: 1000) ?? .milliseconds(300))
            self?.flushMids()
        }
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

    private func resyncBook() {
        guard tab == .trade, wsConnected else { return }
        let sub = l2Sub(selectedCoin, bookSigFigs)
        socket.unsubscribe(sub)
        socket.subscribe(sub)
    }

    /// Order-book subscription. "l2" is the stream app.hyperliquid.xyz uses (snapshot + compressed deltas,
    /// ~2 updates/s); the documented "l2Book" stream only pushes a snapshot every ~10 s.
    private func l2Sub(_ coin: String, _ sig: Int?) -> MP {
        var kv: [(String, MP)] = [("type", .str("l2")), ("c", .str(coin))]
        if let sig { kv.append(("s", .int(Int64(sig)))) }
        return .map(kv)
    }

    private func subscribeCoin(_ coin: String) { coinSubs(coin).forEach { socket.subscribe($0) } }

    // MARK: Energy saving

    @ObservationIgnored private var marketStreamsPaused = false
    @ObservationIgnored private var pendingBook: JSON?
    @ObservationIgnored private var bookFlushScheduled = false
    @ObservationIgnored private var pendingTrades: [PublicTrade] = []
    @ObservationIgnored private var tradesFlushScheduled = false

    /// UI batching interval: normal, or slower in energy saving.
    private func batchDelay(_ normalMs: Int, saving savingMs: Int) -> Duration {
        .milliseconds(energySaving ? savingMs : normalMs)
    }

    /// In energy saving the book / trades / candles / bbo streams run only while the Trade tab is open;
    /// coming back resubscribes (the book and trades arrive as fresh snapshots) and reloads candles.
    private func updateMarketStreams() {
        guard !loading else { return }
        let pause = energySaving && tab != .trade
        guard pause != marketStreamsPaused else { return }
        marketStreamsPaused = pause
        if pause {
            marketSubs(selectedCoin).forEach { socket.unsubscribe($0) }
        } else {
            marketSubs(selectedCoin).forEach { socket.subscribe($0) }
            Task { await loadCandles() }
        }
    }

    /// Energy saving: the book is redrawn at most once a second (normally on every snapshot, ~2/s).
    private func scheduleBookFlush(_ data: JSON) {
        pendingBook = data
        guard !bookFlushScheduled else { return }
        bookFlushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            self.bookFlushScheduled = false
            if let b = self.pendingBook, b["coin"].str == self.selectedCoin { self.applyBookSnapshot(b, fromSocket: true) }
            self.pendingBook = nil
        }
    }

    private func addTrades(_ new: [PublicTrade]) {
        var seen = Set(trades.map(\.tid))
        let fresh = new.reversed().filter { seen.insert($0.tid).inserted }
        guard !fresh.isEmpty else { return }
        trades = Array((fresh + trades).prefix(500))
    }

    /// Energy saving: trades are added once a second instead of on every message.
    private func scheduleTradesFlush(_ new: [PublicTrade]) {
        pendingTrades.append(contentsOf: new)
        guard !tradesFlushScheduled else { return }
        tradesFlushScheduled = true
        let coin = selectedCoin
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            self.tradesFlushScheduled = false
            let batch = self.pendingTrades
            self.pendingTrades = []
            if coin == self.selectedCoin { self.addTrades(batch) }
        }
    }

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
        if !marketStreamsPaused {
            socket.subscribe(.map([("type", .str("candle")), ("coin", .str(selectedCoin)), ("interval", .str(interval.rawValue))]))
        }
        candles = []
        Task { await loadCandles() }
    }

    private func bookAggChanged(old: Int?) {
        socket.unsubscribe(l2Sub(selectedCoin, old))
        book = OrderBook()
        if !marketStreamsPaused { socket.subscribe(l2Sub(selectedCoin, bookSigFigs)) }
    }

    func toggleIntervalVisibility(_ iv: CandleInterval) {
        if let i = visibleIntervals.firstIndex(of: iv) {
            if visibleIntervals.count > 1 { visibleIntervals.remove(at: i) }
        } else {
            visibleIntervals.append(iv)
            visibleIntervals.sort { $0.seconds < $1.seconds }
        }
    }

    /// Messages per second by channel over the last few seconds (diagnostics in Settings).
    func socketRates(previous: [String: Int], seconds: Double) -> ([String: Int], String) {
        let now = socket.channelCounts
        let parts = ["l2Book", "bbo", "trades", "fastAssetCtxs"].map { ch -> String in
            let r = Double((now[ch] ?? 0) - (previous[ch] ?? 0)) / max(seconds, 0.1)
            return "\(ch) \(Fmt.num(r, 1))/s"
        }
        return (now, parts.joined(separator: " · "))
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
                // Streams miss whatever happened while the app was suspended (funding, fills, transfers):
                // reload the history too.
                Task { await refreshAccount(); await refreshMarkets(); await loadCandles(); await refreshHistoryThrottled() }
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
            if outcomeSpecs.isEmpty { await loadOutcomes() }
            if categories.isEmpty, let c = await tryInfo("perpCategories", []) {
                var map: [String: String] = [:]
                for e in c.array { map[e[0].str] = MarketCategory.normalize(e[1].str) }
                categories = map
            }
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
            _ = newNames  // HIP-3 prices come from fastAssetCtxs as well
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
        var tables: [Int: [(lowerBound: Double, maxLeverage: Int)]] = [:]
        for t in j[0]["marginTables"].array {
            guard let id = t[0].int else { continue }
            tables[id] = t[1]["marginTiers"].array.map { (lowerBound: $0["lowerBound"].dbl, maxLeverage: $0["maxLeverage"].int ?? 1) }
        }
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
            m.deployerFeeScale = u["deployerFeeScale"].dbl
            m.growthMode = u["growthMode"].str == "enabled"
            m.marginTiers = MarginTier.tiers(tableId: u["marginTableId"].int, maxLeverage: m.maxLeverage, tables: tables)
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
            tokens[idx]?.evmContract = t["evmContract"]["address"].string
            tokens[idx]?.evmExtraDecimals = t["evmContract"]["evm_extra_wei_decimals"].int ?? 0
        }
        spotTokens = tokens
        var ctxByCoin: [String: JSON] = [:]
        for c in j[1].array { ctxByCoin[c["coin"].str] = c }
        for (coin, c) in ctxByCoin where coin.hasPrefix("#") {
            outcomeCtx[coin] = (c["midPx"].double ?? c["markPx"].dbl, c["markPx"].dbl, c["dayNtlVlm"].dbl)
            if var m = marketById[coin] {
                m.midPx = c["midPx"].double ?? c["markPx"].dbl
                m.markPx = c["markPx"].dbl
                m.dayNtlVlm = c["dayNtlVlm"].dbl
                marketById[coin] = m
            }
        }
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
            summary = AccountSummary(ch)
            mainPositions = ch["assetPositions"].array.map(Position.init).filter { $0.szi != 0 }
            spotBalances = sp["balances"].array.map(SpotBalance.init).filter { $0.total != 0 }
            var avail: [Int: Double] = [:]
            for e in sp["tokenToAvailableAfterMaintenance"].array {
                if let t = e[0].int { avail[t] = e[1].dbl }
            }
            availableAfterMaintenance = avail
            if abstraction == nil || tick % 10 == 0 {
                if let a = await tryInfo("userAbstraction", [("user", .str(user))]), user == userAddress, let v = a.string {
                    abstraction = v
                }
            }
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
            let sum = AccountSummary(ch)
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
        ordersUpdatedAt = Date()
    }

    /// Full refresh including HIP-3 dex clearinghouses.
    func refreshAllAccounts() async {
        if let u = userAddress { await refreshDexAccounts(u) }
        await refreshAccount()
        await refreshOrders()
    }

    /// Free collateral for the dex a market trades on (unified accounts: the spot balance of the collateral token).
    func withdrawable(for m: Market) -> Double {
        if isUnified { return spotAvailable(collateralName(m.dex)) }
        return m.isHip3 ? (dexSummaries[m.dex]?.withdrawable ?? 0) : summary.withdrawable
    }

    /// Cross margin is unavailable for isolated-only markets, and for HIP-3 markets on standard
    /// accounts (only unified / portfolio-margin / dex-abstraction accounts share collateral with HIP-3 dexes).
    func crossAllowed(_ m: Market) -> Bool {
        if m.onlyIsolated { return false }
        guard m.isHip3, let a = abstraction else { return true }
        return isUnified || a == "dexAbstraction"
    }

    // MARK: Fees (as app.hyperliquid.xyz)

    static let stablecoins: Set<String> = ["USDC", "USDT0", "USDT", "USDH", "USDE", "USDHL", "USDXL", "FEUSD", "USDB"]

    /// Effective taker / maker rates for a market: spot or perp base rate with the referral discount,
    /// spot stable pairs × 0.2, HIP-3 deployer fee scale and growth mode (× 0.1).
    func fees(for m: Market) -> (taker: Double, maker: Double) {
        let disc = 1 - referralDiscount
        var taker = (m.isSpot ? spotTakerFee : takerFee) * disc
        var maker = m.isSpot ? spotMakerFee : makerFee
        if maker > 0 { maker *= disc }
        if m.isSpot {
            if Self.stablecoins.contains(m.base) && Self.stablecoins.contains(m.quote) { taker *= 0.2; maker *= 0.2 }
        } else if m.isHip3 {
            let scale = m.deployerFeeScale + max(1, m.deployerFeeScale)
            let growth = m.growthMode ? 0.1 : 1
            taker *= scale * growth
            maker *= growth
            if maker > 0 { maker *= scale }
        }
        return (taker, maker)
    }

    // MARK: Account mode (as app.hyperliquid.xyz)

    /// Unified account or portfolio margin: one balance per token shared by spot and every perp dex.
    var isUnified: Bool { abstraction == "unifiedAccount" || abstraction == "portfolioMargin" }
    var isPortfolioMargin: Bool { abstraction == "portfolioMargin" }

    var accountModeTitle: String {
        switch abstraction {
        case "unifiedAccount": return L("Unified account")
        case "portfolioMargin": return L("Portfolio margin")
        case "disabled", "dexAbstraction": return L("Standard account")
        case nil: return "…"
        default: return L("Standard account")
        }
    }

    func collateralName(_ dex: String) -> String { collateral(of: dex)?.name ?? "USDC" }

    /// total − hold of a spot token (what the web shows as "Available Balance").
    func spotAvailable(_ coin: String) -> Double {
        max(0, spotBalances.first { $0.coin == coin }?.available ?? 0)
    }

    /// USDC that can be withdrawn / sent: the spot balance on unified accounts, perps withdrawable otherwise.
    var withdrawableUSDC: Double { isUnified ? spotAvailable("USDC") : summary.withdrawable }

    /// Spot + perps equity used for trading (web: "Trading equity" on unified accounts).
    var tradingEquity: Double { isUnified ? spotValue : totalPerpValue }

    /// Total equity as computed by app.hyperliquid.xyz: vaults + spot + staking (+ perps unless unified).
    var totalEquity: Double {
        let staking = stakedHype * spotPrice("HYPE")
        return vaultEquity + spotValue + staking + (isUnified ? 0 : totalPerpValue)
    }

    var allSummaries: [AccountSummary] { [summary] + Array(dexSummaries.values) }

    /// Cross maintenance margin over all perp dexes.
    var crossMaintenance: Double { allSummaries.reduce(0) { $0 + $1.maintenanceMargin } }

    /// Unified: max over collateral tokens of cross maintenance / (balance − isolated margin);
    /// standard: cross maintenance / cross account value of the main dex.
    var marginRatio: Double {
        guard isUnified else { return summary.marginRatio }
        var mm: [String: Double] = [:], iso: [String: Double] = [:]
        mm[collateralName("")] = summary.maintenanceMargin
        for p in mainPositions where p.isIsolated { iso[collateralName(""), default: 0] += p.marginUsed }
        for d in perpDexs {
            let c = collateralName(d.name)
            mm[c, default: 0] += dexSummaries[d.name]?.maintenanceMargin ?? 0
            for p in dexPositions[d.name] ?? [] where p.isIsolated { iso[c, default: 0] += p.marginUsed }
        }
        var ratio = 0.0
        for (c, m) in mm {
            let free = (spotBalances.first { $0.coin == c }?.total ?? 0) - (iso[c] ?? 0)
            if free > 0 { ratio = max(ratio, m / free) }
        }
        return min(ratio, 1)
    }

    /// Unified: cross notional / collateral balances; standard: notional / perps account value.
    var accountLeverage: Double {
        guard isUnified else { return summary.leverage }
        let ntl = allSummaries.reduce(0) { $0 + $1.crossNtlPos }
        var collateral = Set<String>(["USDC"])
        for d in perpDexs { collateral.insert(collateralName(d.name)) }
        let bal = collateral.reduce(0.0) { acc, c in acc + (spotBalances.first { $0.coin == c }?.total ?? 0) * spotPrice(c) }
        return bal > 0 ? ntl / bal : 0
    }

    var marginUsed: Double { positions.reduce(0) { $0 + $1.marginUsed } }
    var positionsNotional: Double { positions.reduce(0) { $0 + $1.positionValue } }

    /// Value of all perp accounts (main + HIP-3 dexes).
    var totalPerpValue: Double {
        summary.accountValue + dexSummaries.values.reduce(0) { $0 + $1.accountValue }
    }

    @ObservationIgnored private var historyRefreshedAt: Date = .distantPast

    /// refreshHistory at most every 20 s (resume, reconnect and the periodic re-sync can coincide).
    func refreshHistoryThrottled() async {
        guard Date().timeIntervalSince(historyRefreshedAt) > 20 else { return }
        historyRefreshedAt = Date()
        await refreshHistory()
    }

    func refreshHistory() async {
        guard let user = userAddress else { return }
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        let week: UInt64 = 7 * 24 * 3600 * 1000
        async let f = tryInfo("userFills", [("user", .str(user)), ("aggregateByTime", .bool(true))])
        async let fu = fetchRange("userFunding", user: user, startTime: Int64(now - 4 * week))
        async let l = fetchRange("userNonFundingLedgerUpdates", user: user, startTime: Int64(now - 52 * week))
        async let t = tryInfo("twapHistory", [("user", .str(user))])
        async let p = tryInfo("portfolio", [("user", .str(user))])
        async let oh = tryInfo("historicalOrders", [("user", .str(user))])
        async let sa = tryInfo("subAccounts", [("user", .str(masterAddress ?? user))])
        async let tf = tryInfo("userTwapSliceFills", [("user", .str(user))])
        async let ve = tryInfo("userVaultEquities", [("user", .str(user))])
        async let ds = tryInfo("delegatorSummary", [("user", .str(user))])
        let (fills, funding, ledger, twap, portfolio) = await (f, fu, l, t, p)
        let (vaults, staking) = await (ve, ds)
        let (history, sliceFills) = await (oh, tf)
        let subs = await sa
        guard user == userAddress else { return }
        if let subs { subAccounts = subs.array.map(SubAccount.init) }
        if let history {
            orderHistory = history.array.map(HistoricalOrder.init).sorted { $0.time > $1.time }
        }
        if let sliceFills {
            twapFills = sliceFills.array.map { Fill($0["fill"]) }.sorted { $0.time > $1.time }
        }
        if let vaults { vaultEquity = vaults.array.reduce(0) { $0 + $1["equity"].dbl } }
        if let staking {
            stakedHype = staking["delegated"].dbl + staking["undelegated"].dbl + staking["totalPendingWithdrawal"].dbl
        }
        if let fills { self.fills = fills.array.map(Fill.init).sorted { $0.time > $1.time } }
        if let funding {
            var seen = Set<String>()
            fundingHistory = funding.map { FundingEntry($0) }.filter { seen.insert($0.id).inserted }.sorted { $0.time > $1.time }
        }
        if let ledger {
            let names = ledgerNames
            var seen = Set<String>()
            self.ledger = ledger.map { LedgerEntry($0, me: user, names: names) }.filter { seen.insert($0.id).inserted }
                .sorted { $0.time > $1.time }
        }
        if let twap { parseTwaps(twap) }
        if let portfolio { parsePortfolio(portfolio) }
    }

    /// History requests with a start time return a limited page (500 entries) starting from the OLDEST
    /// entry, so page forward until the present; otherwise recent funding / transfers are cut off.
    private func fetchRange(_ type: String, user: String, startTime: Int64, maxPages: Int = 20) async -> [JSON]? {
        var out: [JSON] = []
        var start = startTime
        for _ in 0..<maxPages {
            guard let j = await tryInfo(type, [("user", .str(user)), ("startTime", .int(start))]) else {
                return out.isEmpty ? nil : out
            }
            let page = j.array
            out += page
            guard page.count >= 500, let last = page.last?["time"].int64 else { break }
            // Entries can share a timestamp (several coins per funding hour): restart at the last time and
            // de-duplicate; step forward only if a whole page had the same time.
            start = last > start ? last : last + 1
        }
        return out
    }

    private func tryInfo(_ type: String, _ extra: [(String, MP)]) async -> JSON? {
        try? await api.info(type: type, extra)
    }

    private func twapState(id: Int64, _ s: JSON) -> TwapState {
        TwapState(id: id, coin: s["coin"].str, isBuy: s["side"].str == "B", sz: s["sz"].dbl,
                  executedSz: s["executedSz"].dbl, executedNtl: s["executedNtl"].dbl,
                  minutes: s["minutes"].int ?? 0,
                  started: Date(timeIntervalSince1970: s["timestamp"].dbl / 1000),
                  reduceOnly: s["reduceOnly"].bool ?? false)
    }

    private func parseTwaps(_ j: JSON) {
        // The live twapStates stream is authoritative once it has delivered.
        guard !accountStreamLive else { return }
        var out: [TwapState] = []
        for e in j.array {
            let status = e["status"]["status"].string ?? e["status"].str
            guard status == "activated", let id = e["twapId"].int64 else { continue }
            out.append(twapState(id: id, e["state"]))
        }
        twaps = out.filter { $0.endsAt > Date() }
    }

    private func parsePortfolio(_ j: JSON) {
        // [["day", {...}], ["week", {...}], ["month", {...}], ["allTime", {...}], ...]
        var ranges: [String: PortfolioRange] = [:]
        for entry in j.array {
            let pts: (JSON) -> [(Date, Double)] = { arr in arr.array.map { (Date(timeIntervalSince1970: $0[0].dbl / 1000), $0[1].dbl) } }
            ranges[entry[0].str] = PortfolioRange(accountValue: pts(entry[1]["accountValueHistory"]),
                                                  pnl: pts(entry[1]["pnlHistory"]), volume: entry[1]["vlm"].dbl)
        }
        portfolioRanges = ranges
        portfolioHistory = ranges["month"]?.accountValue ?? []
    }

    func refreshFees() async {
        guard let user = userAddress else { return }
        if let f = try? await api.info(type: "userFees", [("user", .str(user))]) {
            if let t = f["userCrossRate"].double { takerFee = t }
            if let m = f["userAddRate"].double { makerFee = m }
            if let t = f["userSpotCrossRate"].double { spotTakerFee = t }
            if let m = f["userSpotAddRate"].double { spotMakerFee = m }
            referralDiscount = f["activeReferralDiscount"].dbl
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
        let fresh = j.array.map(Candle.init).sorted { $0.t < $1.t }
        // Keep older history already loaded by scrolling back; replace the recent part (fills gaps after
        // the app was in the background).
        if let first = fresh.first, let have = candles.first, have.t < first.t {
            candles = candles.filter { $0.t < first.t } + fresh
        } else {
            candles = fresh
        }
    }

    @ObservationIgnored private var olderCandlesLoading = false
    @ObservationIgnored private var candleHistoryEnd = ""

    /// Loads 500 older candles in front of the loaded ones (scrolling back in the chart).
    func loadOlderCandles() async {
        let coin = selectedCoin, iv = interval
        let key = "\(coin)|\(iv.rawValue)"
        guard !olderCandlesLoading, candleHistoryEnd != key, let first = candles.first else { return }
        olderCandlesLoading = true
        defer { olderCandlesLoading = false }
        let end = first.t - 1
        let start = end - iv.seconds * 1000 * 500
        let req = MP.map([("coin", .str(coin)), ("interval", .str(iv.rawValue)),
                          ("startTime", .int(Int64(start))), ("endTime", .int(Int64(end)))])
        guard let j = try? await api.info(type: "candleSnapshot", [("req", req)]), coin == selectedCoin, iv == interval,
              let current = candles.first else { return }
        let older = j.array.map(Candle.init).filter { $0.t < current.t }.sorted { $0.t < $1.t }
        if older.isEmpty { candleHistoryEnd = key; return }      // the exchange keeps a limited history
        candles = older + candles
    }

    // MARK: WebSocket

    private func handle(channel: String, data: JSON) {
        PerfMonitor.messages += 1
        switch channel {
        case "fastAssetCtxs":
            // {coin: {markPx, midPx}}; later messages may carry only changed coins.
            for (k, v) in data.object {
                if let d = v["midPx"].double ?? v["markPx"].double { pendingMids[k] = d }
            }
            scheduleMidsFlush()
        case "allMids":
            // Kept for compatibility; prices normally come from fastAssetCtxs. Buffered like it.
            for (k, v) in data["mids"].object { if let d = v.double { pendingMids[k] = d } }
            scheduleMidsFlush()
        case "bbo":
            // Best bid/ask arrive on every change; used for the mid/spread line only. The ladder itself
            // always comes from the latest consistent l2Book snapshot (patching it made levels vanish).
            guard data["coin"].str == selectedCoin else { return }
            let pair = data["bbo"]
            // Up to ~50 updates/s: apply at most 10 times a second (each update redraws the trade screen).
            if let b = pair[0]["px"].double, let a = pair[1]["px"].double, a >= b {
                pendingBbo = (selectedCoin, BestBidAsk(bid: b, ask: a))
                scheduleBboFlush()
            }
        case "l2Book":
            guard data["coin"].str == selectedCoin else { return }
            if energySaving { scheduleBookFlush(data) } else { applyBookSnapshot(data, fromSocket: true) }
        case "trades":
            let new = data.array.filter { $0["coin"].str == selectedCoin }.map {
                PublicTrade(px: $0["px"].dbl, sz: $0["sz"].dbl, isBuy: $0["side"].str == "B",
                            time: Date(timeIntervalSince1970: $0["time"].dbl / 1000), tid: $0["tid"].int64 ?? Int64.random(in: 0...Int64.max))
            }
            guard !new.isEmpty else { return }
            if energySaving { scheduleTradesFlush(new) } else { addTrades(new) }
        case "candle":
            guard data["s"].str == selectedCoin, data["i"].str == interval.rawValue else { return }
            // One update per trade: batch them (4 per second) so the chart and indicators are not
            // recomputed on every trade.
            let c = Candle(data)
            pendingCandles[c.t] = c
            pendingCandlesKey = "\(selectedCoin)|\(interval.rawValue)"
            scheduleCandleFlush()
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
            let text = L("Filled: {0} {1} {2} at {3}", f.isBuy ? L("buy") : L("sell"), Fmt.num(total, market(f.coin)?.szDecimals ?? 4), displayName(f.coin), Fmt.price(f.px))
            if fillToasts { show(.success, text) }
            if fillSound { FillAlerts.playSound() }
            if backgroundFillAlerts { FillAlerts.notifyIfBackground(text) }
            Haptics.success(enabled: haptics)
            if !accountStreamLive { Task { await refreshAccount(); await refreshOrders() } }
        case "orderUpdates":
            if Date().timeIntervalSince(ordersStreamAt) > 8 { Task { await refreshOrders() } }
        case "webData3":
            let us = data["userState"]
            guard us["user"].str.lowercased() == userAddress else { return }
            if let a = us["abstraction"].string { abstraction = a }
            var capped = Set<String>()
            var vaults = 0.0
            for st in data["perpDexStates"].array {
                for c in st["perpsAtOpenInterestCap"].array { capped.insert(c.str) }
                vaults += st["totalVaultEquity"].dbl
            }
            if capped != perpsAtOiCap { perpsAtOiCap = capped }
            vaultEquity = vaults
        case "allDexsClearinghouseState":
            guard data["user"].str.lowercased() == userAddress else { return }
            for e in data["clearinghouseStates"].array {
                let dex = e[0].str, ch = e[1]
                let sum = AccountSummary(ch)
                let pos = ch["assetPositions"].array.map(Position.init).filter { $0.szi != 0 }
                if dex.isEmpty {
                    if sum != summary { summary = sum }
                    mainPositions = pos
                } else {
                    if dexSummaries[dex] != sum { dexSummaries[dex] = sum }
                    dexPositions[dex] = pos
                    if sum.accountValue > 0 || !pos.isEmpty { activeDexes.insert(dex) }
                }
            }
            let all = mainPositions + perpDexs.flatMap { dexPositions[$0.name] ?? [] }
            if all != positions { positions = all }
            accountStreamAt = Date()
            accountError = nil
        case "spotState":
            guard data["user"].str.lowercased() == userAddress else { return }
            let st = data["spotState"]
            let bals = st["balances"].array.map(SpotBalance.init).filter { $0.total != 0 }
            if bals != spotBalances { spotBalances = bals }
            var avail: [Int: Double] = [:]
            for e in st["tokenToAvailableAfterMaintenance"].array {
                if let t = e[0].int { avail[t] = e[1].dbl }
            }
            if avail != availableAfterMaintenance { availableAfterMaintenance = avail }
        case "openOrders":
            guard data["user"].str.lowercased() == userAddress else { return }
            var seen = Set<Int64>()
            let list = data["orders"].array.map(OpenOrder.init).filter { seen.insert($0.oid).inserted }
            if list != openOrders { openOrders = list }
            ordersStreamAt = Date()
            ordersUpdatedAt = Date()
        case "userFundings":
            // Hourly funding payments as they are applied (history comes from REST).
            guard let me = userAddress, data["user"].str.lowercased() == me, data["isSnapshot"].bool != true else { return }
            let new = data["fundings"].array.map { FundingEntry(stream: $0) }
            let known = Set(fundingHistory.map(\.id))
            let fresh = new.filter { !known.contains($0.id) }
            if !fresh.isEmpty { fundingHistory = (fresh + fundingHistory).sorted { $0.time > $1.time } }
        case "userNonFundingLedgerUpdates":
            // Deposits, withdrawals and transfers as they happen (the snapshot is covered by the REST history).
            guard let me = userAddress, data["user"].str.lowercased() == me, data["isSnapshot"].bool != true else { return }
            let names = ledgerNames
            let new = data["nonFundingLedgerUpdates"].array.map { LedgerEntry($0, me: me, names: names) }
            let known = Set(ledger.map(\.id))
            let fresh = new.filter { !known.contains($0.id) }
            guard !fresh.isEmpty else { return }
            ledger = (fresh + ledger).sorted { $0.time > $1.time }
            if let e = fresh.first, e.type == "deposit" || e.type == "withdraw" { show(.success, "\(e.detail): \(Fmt.signedUsd(e.usdc))") }
        case "twapStates":
            guard data["user"].str.lowercased() == userAddress else { return }
            twaps = data["states"].array.compactMap { e in
                e[0].int64.map { twapState(id: $0, e[1]) }
            }.filter { $0.endsAt > Date() }
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
        if let sub = activeSubAccount { return sub }
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
            guard sig.recoverAddress(digest: HLSigning.userSignedDigest(a))?.lowercased() == acc.address.lowercased() else {
                throw HLError(L("The wallet signed with a different account. Select {0} in the wallet and try again.", Address.short(acc.address)))
            }
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
            ("User or API Wallet", L("User/agent not found. Make sure the API wallet is approved at app.hyperliquid.xyz/API")),
            ("never placed, already canceled, or filled", L("The order is no longer open (filled or cancelled)")),
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
