import SwiftUI
import Charts
import HyperCore

/// Portfolio laid out like app.hyperliquid.xyz/portfolio: total equity, account type, the equity/PnL
/// chart with ranges, actions (Deposit, Withdraw, Send, Perps ⇄ Spot only for standard accounts)
/// and the account tables starting with Balances.
struct PortfolioView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: Tab = .balances
    @State private var transfer: TransferKind?
    @State private var pending: PendingConfirm?
    @State private var showAccountType = false
    @State private var showSwap = false
    @State private var showEvm = false
    @State private var range: ChartRange = .month
    @State private var graph: Graph = .value

    enum Tab: String, CaseIterable, Identifiable {
        case balances = "Balances", positions = "Positions", orders = "Orders", twap = "TWAP", fills = "Trades", history = "Order history", funding = "Funding", ledger = "Transfers"
        var id: String { rawValue }
    }

    enum ChartRange: String, CaseIterable, Identifiable {
        case day, week, month, allTime
        var id: String { rawValue }
        var title: String {
            switch self {
            case .day: return L("24h")
            case .week: return L("7d")
            case .month: return L("30d")
            case .allTime: return L("All")
            }
        }
    }

    enum Graph: String, CaseIterable, Identifiable {
        case value, pnl
        var id: String { rawValue }
        var title: String { self == .value ? L("Account value") : L("PnL") }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if model.account == nil {
                        EmptyState(text: L("No account connected.\nAdd an API wallet or a watch address in Settings."), icon: "person.crop.circle.badge.plus")
                        Button(L("Open Settings")) { model.tab = .settings }.buttonStyle(.borderedProminent).tint(.hlAccent)
                    } else {
                        summaryCard
                        chartCard
                        performanceCard
                        actions
                        tabs
                        content
                    }
                }
                .padding(12)
            }
            .themedBackground()
            .refreshable {
                await model.refreshAllAccounts()
                await model.refreshHistory()
            }
            .navigationTitle(L("Portfolio"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { AccountSwitcher() }
            }
            .sheet(item: $transfer) { TransferSheet(kind: $0) }
            .sheet(isPresented: $showAccountType) { AccountTypeSheet() }
            .sheet(isPresented: $showSwap) { SwapStablecoinsSheet() }
            .sheet(isPresented: $showEvm) { EvmCoreSheet() }
            .confirmDialog($pending)
        }
    }

    // MARK: Summary

    private var summaryCard: some View {
        let unified = model.isUnified
        let ratio = model.marginRatio
        return Card {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Total equity")).font(.caption).foregroundStyle(Color.hlMuted)
                    Text(Fmt.usd(model.totalEquity)).font(.system(size: 28, weight: .bold, design: .monospaced))
                        .lineLimit(1).minimumScaleFactor(0.6)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(L("Unrealized PnL")).font(.caption).foregroundStyle(Color.hlMuted)
                    Text(Fmt.signedUsd(model.unrealizedPnl)).font(.system(size: 17, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.pnl(model.unrealizedPnl))
                }
            }
            Button { showAccountType = true } label: {
                HStack(spacing: 5) {
                    Image(systemName: unified ? "square.stack.3d.up.fill" : "square.split.2x1")
                    Text(model.accountModeTitle)
                    Image(systemName: "chevron.right").font(.caption2)
                }
                .font(.caption.bold())
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color.hlAccent.opacity(0.15), in: Capsule())
                .foregroundStyle(Color.hlAccent)
            }
            .buttonStyle(.plain)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                if unified {
                    GridRow {
                        Stat(title: L("Trading equity"), value: Fmt.usd(model.tradingEquity))
                        Stat(title: L("Available"), value: Fmt.usd(model.withdrawableUSDC))
                        Stat(title: L("Margin used"), value: Fmt.usd(model.marginUsed))
                    }
                } else {
                    GridRow {
                        Stat(title: L("Perps equity"), value: Fmt.usd(model.totalPerpValue))
                        Stat(title: L("Spot equity"), value: Fmt.usd(model.spotValue))
                        Stat(title: L("Withdrawable"), value: Fmt.usd(model.summary.withdrawable))
                    }
                }
                GridRow {
                    Stat(title: L("Positions"), value: Fmt.compactUsd(model.positionsNotional))
                    Stat(title: L("Leverage"), value: Fmt.num(model.accountLeverage, 2) + "x")
                    Stat(title: L("Margin ratio"), value: Fmt.pct(ratio, 1, signed: false),
                         color: ratio > 0.8 ? .hlRed : ratio > 0.5 ? .orange : .hlGreen)
                }
            }
            if model.vaultEquity > 0 || model.stakedHype > 0 {
                HStack(spacing: 12) {
                    if model.vaultEquity > 0 { Stat(title: L("Vaults"), value: Fmt.usd(model.vaultEquity)) }
                    if model.stakedHype > 0 { Stat(title: L("Staking"), value: Fmt.num(model.stakedHype, 2) + " HYPE") }
                }
            }
            if !unified {
                let dexNames: [String] = model.dexSummaries.keys.sorted().filter { (k: String) -> Bool in (model.dexSummaries[k]?.accountValue ?? 0) > 0 }
                if !dexNames.isEmpty {
                    HStack(spacing: 12) {
                        ForEach(dexNames, id: \.self) { k in
                            Stat(title: "HIP-3 · \(k)", value: Fmt.usd(model.dexSummaries[k]?.accountValue ?? 0))
                        }
                    }
                }
            }
            if let err = model.accountError {
                Text(err).font(.caption2).foregroundStyle(Color.hlRed)
            }
        }
    }

    // MARK: Chart

    private var chartCard: some View {
        let r = model.portfolioRanges[range.rawValue]
        let pts: [(Date, Double)] = (graph == .value ? r?.accountValue : r?.pnl) ?? []
        let first = pts.first?.1 ?? 0, last = pts.last?.1 ?? 0
        return Card {
            HStack {
                Picker("", selection: $graph) {
                    ForEach(Graph.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).fixedSize()
                Spacer()
                Menu {
                    Picker("", selection: $range) { ForEach(ChartRange.allCases) { Text($0.title).tag($0) } }
                } label: {
                    HStack(spacing: 3) { Text(range.title); Image(systemName: "chevron.down").font(.caption2) }
                        .font(.caption.bold()).foregroundStyle(Color.hlAccent)
                }
            }
            if pts.count > 1 {
                Chart {
                    ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                        LineMark(x: .value(L("Date"), p.0), y: .value("USD", p.1))
                            .foregroundStyle(last >= first ? Color.hlGreen : Color.hlRed)
                            .interpolationMethod(.monotone)
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: axisFormat) }
                }
                // Dollar amounts as $5M / -$10M instead of the default 5,0E6.
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { v in
                        AxisGridLine()
                        AxisValueLabel {
                            if let d = v.as(Double.self) { Text(Fmt.compactUsd(d)).font(.system(size: 9, design: .monospaced)) }
                        }
                    }
                }
                .frame(height: 120)
            } else {
                Text(L("No history yet")).font(.caption).foregroundStyle(Color.hlMuted)
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
            if let r {
                HStack(spacing: 12) {
                    Stat(title: L("PnL"), value: Fmt.signedUsd(r.pnlChange), color: Color.pnl(r.pnlChange))
                    Stat(title: L("Volume"), value: Fmt.usd(r.volume))
                }
            }
        }
    }

    /// Sharpe / Sortino / drawdown / Calmar of the selected range (returns net of deposits and withdrawals).
    @ViewBuilder
    private var performanceCard: some View {
        if let r = model.portfolioRanges[range.rawValue],
           let perf = QuantMath.performance(accountValue: r.accountValue, pnl: r.pnl) {
            Card {
                HStack {
                    Text(L("Performance · {0}", range.title)).font(.caption.bold())
                    Spacer()
                    Text(L("{0} periods", perf.periods)).font(.caption2).foregroundStyle(Color.hlMuted)
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Stat(title: L("Return"), value: Fmt.pct(perf.totalReturn, 2), color: Color.pnl(perf.totalReturn))
                        Stat(title: L("Max drawdown"), value: Fmt.pct(-perf.maxDrawdown, 2), color: .hlRed)
                        Stat(title: L("Win periods"), value: Fmt.pct(perf.winRate, 0, signed: false))
                    }
                    GridRow {
                        Stat(title: "Sharpe", value: perf.sharpe.map { Fmt.num($0, 2) } ?? "—", color: Color.pnl(perf.sharpe ?? 0))
                        Stat(title: "Sortino", value: perf.sortino.map { Fmt.num($0, 2) } ?? "—", color: Color.pnl(perf.sortino ?? 0))
                        Stat(title: "Calmar", value: perf.calmar.map { Fmt.num($0, 2) } ?? "—", color: Color.pnl(perf.calmar ?? 0))
                    }
                    GridRow {
                        Stat(title: L("Volatility (ann.)"), value: Fmt.pct(perf.annualVol, 1, signed: false))
                        Stat(title: L("Return (ann.)"), value: abs(perf.annualReturn) < 100 ? Fmt.pct(perf.annualReturn, 1) : "—",
                             color: Color.pnl(perf.annualReturn))
                    }
                }
                Text(L("Returns between history points, net of deposits and withdrawals; Sharpe and Sortino annualized, no risk-free rate. Short ranges give noisy numbers."))
                    .font(.system(size: 9)).foregroundStyle(Color.hlMuted)
            }
        }
    }

    private var axisFormat: Date.FormatStyle {
        range == .day ? .dateTime.hour().minute() : .dateTime.day().month()
    }

    // MARK: Actions

    private var actions: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                actionTile(L("Deposit"), "arrow.down.circle") { transfer = .deposit }
                actionTile(L("Withdraw"), "arrow.up.circle") { transfer = .withdraw }
                actionTile(L("Send"), "paperplane") { transfer = .send }
                if !model.isUnified && model.abstraction != nil {
                    actionTile(L("Perps ⇄ Spot"), "arrow.left.arrow.right") { transfer = .classTransfer }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip(L("Swap stablecoins"), "arrow.triangle.2.circlepath") { showSwap = true }
                    chip(L("EVM ⇄ Core"), "arrow.up.arrow.down") { showEvm = true }
                    NavigationLink { SubAccountsView() } label: {
                        chipLabel(L("Sub-accounts"), "person.2")
                    }
                    .buttonStyle(.plain)
                    chip(model.accountModeTitle, "slider.horizontal.3") { showAccountType = true }
                }
            }
        }
    }

    private func chip(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { chipLabel(title, icon) }.buttonStyle(.plain)
    }

    private func chipLabel(_ title: String, _ icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.hlCard, in: Capsule())
    }

    private func actionTile(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 10)
            .themedCard()
        }
        .buttonStyle(.plain)
    }

    // MARK: Tables

    private var tabs: some View {
        UnderlineTabs(items: Tab.allCases.map { .init(id: $0, title: L($0.rawValue), count: count($0)) },
                      selection: $tab)
    }

    private func count(_ t: Tab) -> Int? {
        switch t {
        case .positions: return model.positions.count
        case .orders: return model.openOrders.count + model.activeChases.count
        case .twap: return model.twaps.count
        default: return nil
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .balances:
            BalancesSection()
        case .positions:
            if model.positions.isEmpty { EmptyState(text: L("No open positions")) }
            else {
                if model.canTrade {
                    HStack {
                        Spacer()
                        Button(L("Close all positions")) {
                            pending = PendingConfirm(title: L("Close all positions"),
                                                     message: L("Market close of all positions: {0}", model.positions.count),
                                                     button: L("Close all")) { model.perform { try await model.closeAll() } }
                        }
                            .font(.caption.bold()).foregroundStyle(Color.hlRed)
                    }
                }
                ForEach(model.positions) { PositionRow(position: $0) }
            }
        case .orders:
            ChaseList()
            if model.openOrders.isEmpty && model.activeChases.isEmpty { EmptyState(text: L("No open orders")) }
            else {
                if model.canTrade {
                    HStack {
                        Spacer()
                        Button(L("Cancel all orders")) {
                            pending = PendingConfirm(title: L("Cancel all orders"),
                                                     message: L("Orders to cancel: {0}", model.openOrders.count),
                                                     button: L("Cancel all")) { model.perform { try await model.cancelAll() } }
                        }
                            .font(.caption.bold()).foregroundStyle(Color.hlRed)
                    }
                }
                ForEach(model.openOrders) { OrderRow(order: $0) }
            }
        case .twap:
            if model.twaps.isEmpty { EmptyState(text: L("No active TWAPs")) }
            ForEach(model.twaps) { TwapRow(twap: $0) }
            if !model.twapFills.isEmpty {
                Text(L("TWAP fills")).font(.caption.bold()).foregroundStyle(Color.hlMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(FillGroup.group(Array(model.twapFills.prefix(300))).prefix(100)) { FillGroupRow(group: $0) }
            }
        case .history:
            if model.orderHistory.isEmpty { EmptyState(text: L("No orders yet")) }
            ForEach(model.orderHistory.prefix(200)) { HistoryOrderRow(entry: $0) }
        case .fills:
            FillsSection()
        case .funding:
            FundingSection()
        case .ledger:
            if model.ledger.isEmpty { EmptyState(text: L("No deposits or transfers")) }
            ForEach(model.ledger.prefix(100)) { e in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.detail).font(.subheadline)
                        Text(Fmt.dateTime(e.time)).font(.caption2).foregroundStyle(Color.hlMuted)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(e.isInternal ? Fmt.usd(abs(e.usdc)) : Fmt.signedUsd(e.usdc))
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(e.isInternal ? Color.primary : Color.pnl(e.usdc))
                        if let t = e.tokenLine {
                            Text(t).font(.caption2.monospaced()).foregroundStyle(Color.hlMuted)
                        }
                    }
                }
                .padding(10)
                .themedCard()
            }
        }
    }
}

/// Balances table as on the web: coin, total, available (total − hold), USD value and PnL.
/// Standard accounts get a "USDC · Perps" row (and one per funded HIP-3 dex); unified accounts
/// have a single balance per token shared by spot and perps.
struct BalancesSection: View {
    @Environment(AppModel.self) private var model

    struct Row: Identifiable {
        let id: String
        let coin: String
        let place: String
        let total: Double
        let available: Double
        let usd: Double
        let pnl: Double?
        let roe: Double?
        let decimals: Int
    }

    private var rows: [Row] {
        var out: [Row] = []
        let unified = model.isUnified
        if !unified {
            let s = model.summary
            if s.accountValue != 0 {
                out.append(Row(id: "perps", coin: "USDC", place: L("Perps"), total: s.accountValue, available: s.withdrawable,
                               usd: s.accountValue, pnl: nil, roe: nil, decimals: 2))
            }
            for (dex, sum) in model.dexSummaries.sorted(by: { $0.key < $1.key }) where sum.accountValue != 0 {
                let c = model.collateralName(dex)
                out.append(Row(id: "dex-\(dex)", coin: c, place: "HIP-3 · \(dex)", total: sum.accountValue, available: sum.withdrawable,
                               usd: sum.accountValue * model.spotPrice(c), pnl: nil, roe: nil, decimals: 2))
            }
        }
        for b in model.spotBalances {
            let px = model.spotPrice(b.coin)
            let value = b.total * px
            let isStable = b.coin == "USDC"
            let pnl: Double? = (!isStable && b.entryNtl > 0 && px > 0) ? value - b.entryNtl : nil
            let decimals = model.spotTokens[b.token]?.szDecimals ?? 4
            let isOutcome = b.coin.hasPrefix("+")
            out.append(Row(id: "spot-\(b.coin)", coin: isOutcome ? model.displayName(b.coin) : b.coin,
                           place: isOutcome ? L("Outcome") : (unified ? L("Unified") : L("Spot")),
                           total: b.total, available: max(0, b.available), usd: value,
                           pnl: pnl, roe: pnl.map { $0 / b.entryNtl }, decimals: isStable ? 2 : max(decimals, 2)))
        }
        return out.sorted { $0.usd > $1.usd }
    }

    var body: some View {
        let rows = self.rows
        VStack(spacing: 8) {
            if rows.isEmpty { EmptyState(text: L("No balances yet")) }
            ForEach(rows) { r in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(r.coin).font(.subheadline.bold())
                        Text(r.place).font(.caption2).foregroundStyle(Color.hlMuted)
                        Spacer()
                        Text(Fmt.usd(r.usd)).font(.system(size: 14, weight: .medium, design: .monospaced))
                    }
                    HStack(spacing: 12) {
                        Stat(title: L("Total"), value: Fmt.num(r.total, r.decimals))
                        Stat(title: L("Available"), value: Fmt.num(r.available, r.decimals))
                        Spacer()
                        if let pnl = r.pnl {
                            Stat(title: L("PnL (ROE)"), value: Fmt.signedUsd(pnl) + (r.roe.map { " (" + Fmt.pct($0, 1) + ")" } ?? ""),
                                 color: Color.pnl(pnl), align: .trailing)
                        }
                    }
                }
                .padding(10)
                .themedCard()
            }
            if model.isUnified && !rows.isEmpty {
                Text(L("Unified account: spot and perps share one balance per token. The available amount can be withdrawn or sent; the order form shows what is available to trade for each market."))
                    .font(.caption2).foregroundStyle(Color.hlMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Account type picker (app.hyperliquid.xyz → Portfolio → Account Type).
struct AccountTypeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selected = "unifiedAccount"
    @State private var busy = false
    @State private var pending: PendingConfirm?

    private struct Option: Identifiable {
        let id: String
        let title: String
        let text: String
    }

    private var options: [Option] {
        [Option(id: "unifiedAccount", title: L("Unified account (recommended)"),
                text: L("Spot and perps balances are merged for all tokens, and cross margin works on every market, including HIP-3. All USDC is used as cross margin.")),
         Option(id: "portfolioMargin", title: L("Portfolio margin"),
                text: L("For advanced users: eligible assets such as HYPE and BTC can be used directly as collateral for perps. Borrowing and supplying happen automatically and accrue interest. Only for eligible accounts.")),
         Option(id: "disabled", title: L("Standard account"),
                text: L("Only recommended for automated traders. Perps, spot and every HIP-3 dex have separate balances; move USDC between them with Perps ⇄ Spot transfers."))]
    }

    private var current: String {
        switch model.abstraction {
        case "unifiedAccount", "portfolioMargin": return model.abstraction!
        default: return "disabled"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(options) { o in
                        Button { selected = o.id } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: selected == o.id ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(selected == o.id ? Color.hlAccent : Color.hlMuted)
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(o.title).font(.subheadline.bold())
                                        if o.id == current { Badge(text: L("Current"), color: .hlGreen) }
                                    }
                                    Text(o.text).font(.caption).foregroundStyle(Color.hlMuted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    if !(model.account?.kind.canTransfer ?? false) {
                        Text(L("Changing the account type is signed by the main wallet. An API wallet cannot do it."))
                            .foregroundStyle(.orange)
                    }
                }
                Section {
                    PrimaryButton(title: L("Apply"), busy: busy,
                                  disabled: selected == current || !(model.account?.kind.canTransfer ?? false)) {
                        let title = options.first { $0.id == selected }?.title ?? selected
                        pending = PendingConfirm(title: L("Change account type"), message: title, button: L("Apply")) {
                            busy = true
                            Task {
                                do {
                                    try await model.setAbstraction(selected)
                                    model.show(.success, L("Account type changed"))
                                    Haptics.success(enabled: model.haptics)
                                    dismiss()
                                } catch {
                                    model.show(.error, error.localizedDescription)
                                    Haptics.error(enabled: model.haptics)
                                }
                                busy = false
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle(L("Account type"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Close")) { dismiss() } } }
            .onAppear { selected = current }
            .confirmDialog($pending)
        }
    }
}

struct FillsSection: View {
    @Environment(AppModel.self) private var model
    @State private var period = 1

    var body: some View {
        let since = Date().addingTimeInterval(-[86400.0, 7 * 86400, 30 * 86400][period])
        let fills = model.fills.filter { $0.time >= since }
        let pnl = fills.reduce(0) { $0 + $1.closedPnl }
        let fees = fills.reduce(0) { $0 + $1.fee }
        let volume = fills.reduce(0) { $0 + $1.px * $1.sz }
        let closed = fills.filter { $0.closedPnl != 0 }
        let wins = closed.filter { $0.closedPnl > 0 }.count
        VStack(spacing: 8) {
            Picker("", selection: $period) {
                Text(L("24h")).tag(0); Text(L("7d")).tag(1); Text(L("30d")).tag(2)
            }
            .pickerStyle(.segmented)
            Card {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Stat(title: L("Realized PnL"), value: Fmt.signedUsd(pnl), color: Color.pnl(pnl))
                        Stat(title: L("Fees"), value: Fmt.usd(fees))
                        Stat(title: L("Net PnL"), value: Fmt.signedUsd(pnl - fees), color: Color.pnl(pnl - fees))
                    }
                    GridRow {
                        Stat(title: L("Volume"), value: Fmt.compactUsd(volume))
                        Stat(title: L("Trades count"), value: "\(fills.count)")
                        Stat(title: L("Win rate"), value: closed.isEmpty ? "—" : Fmt.pct(Double(wins) / Double(closed.count), 0, signed: false))
                    }
                }
            }
            if fills.isEmpty { EmptyState(text: L("No trades in this period")) }
            ForEach(FillGroup.group(Array(fills.prefix(600))).prefix(150)) { FillGroupRow(group: $0) }
        }
    }
}

struct FundingSection: View {
    @Environment(AppModel.self) private var model
    /// Only this market's payments (trade screen), or all.
    var coin: String? = nil
    var body: some View {
        let list = coin.map { c in model.fundingHistory.filter { $0.coin == c } } ?? model.fundingHistory
        let total = list.reduce(0) { $0 + $1.usdc }
        VStack(spacing: 8) {
            Card {
                Stat(title: L("Funding, 4 weeks"), value: Fmt.signedUsd(total, 4), color: Color.pnl(total))
            }
            if list.isEmpty { EmptyState(text: L("No funding payments")) }
            ForEach(list.prefix(200)) { f in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.displayName(f.coin)).font(.subheadline.bold())
                        Text(L("{0} · rate {1}", Fmt.dateTime(f.time), Fmt.pct(f.rate, 4))).font(.caption2).foregroundStyle(Color.hlMuted)
                    }
                    Spacer()
                    Text(Fmt.signedUsd(f.usdc, 4)).font(.system(size: 13, design: .monospaced)).foregroundStyle(Color.pnl(f.usdc))
                }
                .padding(10)
                .themedCard()
            }
        }
    }
}

struct AccountSwitcher: View {
    @Environment(AppModel.self) private var model

    private var accountTitle: String {
        let base = model.account?.name ?? L("Account")
        if let sub = model.activeSubAccount {
            return base + " · " + (model.subAccounts.first { $0.address == sub }?.name ?? Address.short(sub))
        }
        return base
    }
    var body: some View {
        Menu {
            ForEach(model.accounts) { a in
                Button {
                    model.activeAccountId = a.id
                } label: {
                    if a.id == model.activeAccountId { Label("\(a.name) · \(Address.short(a.address))", systemImage: "checkmark") }
                    else { Text("\(a.name) · \(Address.short(a.address))") }
                }
            }
            if !model.subAccounts.isEmpty {
                Section(L("Sub-accounts")) {
                    Button {
                        model.activeSubAccount = nil
                    } label: {
                        if model.activeSubAccount == nil { Label(L("Master account"), systemImage: "checkmark") } else { Text(L("Master account")) }
                    }
                    ForEach(model.subAccounts) { sub in
                        Button {
                            model.activeSubAccount = sub.address
                        } label: {
                            if model.activeSubAccount == sub.address { Label(sub.name, systemImage: "checkmark") } else { Text(sub.name) }
                        }
                    }
                }
            }
            Divider()
            Button(L("Manage accounts")) { model.tab = .settings }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: model.account?.kind == .watch ? "eye" : "person.crop.circle")
                Text(accountTitle).font(.headline)
                Image(systemName: "chevron.down").font(.caption)
            }
            .foregroundStyle(.primary)
        }
    }
}

/// A row of the order history (historicalOrders).
struct HistoryOrderRow: View {
    @Environment(AppModel.self) private var model
    let entry: HistoricalOrder

    var body: some View {
        let o = entry.order
        let m = model.market(o.coin)
        let dec = m?.szDecimals ?? 4
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(model.displayName(o.coin)).font(.subheadline.bold())
                    SideBadge(isLong: o.isBuy, spot: m?.isSpot ?? false)
                    Text(o.typeTitle).font(.caption).foregroundStyle(Color.hlMuted)
                    if o.reduceOnly { Badge(text: "RO", color: .hlMuted) }
                }
                HStack(spacing: 10) {
                    if o.isTrigger { Text(L("Trigger {0}", Fmt.price(o.triggerPx))) }
                    if !o.orderType.contains("Market") { Text(L("Price {0}", Fmt.price(o.limitPx))) }
                    Text(o.origSz == 0 ? L("position") : Fmt.num(o.origSz, dec))
                }
                .font(.system(size: 11, design: .monospaced))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(entry.statusTitle).font(.caption.bold()).foregroundStyle(color)
                Text(Fmt.dateTime(entry.time)).font(.caption2).foregroundStyle(Color.hlMuted)
            }
        }
        .padding(10)
        .themedCard()
    }

    private var color: Color {
        switch entry.status {
        case "filled": return .hlGreen
        case "open", "triggered": return .hlAccent
        case "canceled": return .hlMuted
        default: return .orange
        }
    }
}
