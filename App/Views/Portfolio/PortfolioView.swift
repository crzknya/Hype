import SwiftUI
import Charts
import HyperCore

struct PortfolioView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: Tab = .positions
    @State private var transfer: TransferKind?
    @State private var pending: PendingConfirm?

    enum Tab: String, CaseIterable, Identifiable {
        case positions = "Positions", orders = "Orders", twap = "TWAP", fills = "Trades", funding = "Funding", spot = "Spot", ledger = "Transfers"
        var id: String { rawValue }
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
                        if !model.portfolioHistory.isEmpty { equityChart }
                        actions
                        tabs
                        content
                    }
                }
                .padding(12)
            }
            .background(Color.hlBg)
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
            .confirmDialog($pending)
        }
    }

    private var summaryCard: some View {
        let s = model.summary
        let spotValue = model.spotValue
        return Card {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Account value (perps)")).font(.caption).foregroundStyle(Color.hlMuted)
                    Text(Fmt.usd(s.accountValue)).font(.system(size: 28, weight: .bold, design: .monospaced))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(L("Unrealized PnL")).font(.caption).foregroundStyle(Color.hlMuted)
                    Text(Fmt.signedUsd(model.unrealizedPnl)).font(.system(size: 17, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.pnl(model.unrealizedPnl))
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Stat(title: L("Spot"), value: Fmt.usd(spotValue))
                    Stat(title: L("Withdrawable"), value: Fmt.usd(s.withdrawable))
                    Stat(title: L("Margin"), value: Fmt.usd(s.totalMarginUsed))
                }
                GridRow {
                    Stat(title: L("Positions"), value: Fmt.compactUsd(s.totalNtlPos))
                    Stat(title: L("Account leverage"), value: Fmt.num(s.leverage, 2) + "x")
                    Stat(title: L("Margin ratio"), value: Fmt.pct(s.marginRatio, 1, signed: false),
                         color: s.marginRatio > 0.8 ? .hlRed : s.marginRatio > 0.5 ? .orange : .hlGreen)
                }
            }
            let dexNames: [String] = model.dexSummaries.keys.sorted().filter { (k: String) -> Bool in (model.dexSummaries[k]?.accountValue ?? 0) > 0 }
            if !dexNames.isEmpty {
                HStack(spacing: 12) {
                    ForEach(dexNames, id: \.self) { k in
                        Stat(title: "HIP-3 · \(k)", value: Fmt.usd(model.dexSummaries[k]?.accountValue ?? 0))
                    }
                }
            }
            if let err = model.accountError {
                Text(err).font(.caption2).foregroundStyle(Color.hlRed)
            }
        }
    }

    private var equityChart: some View {
        Card {
            Text(L("Account value, 30 days")).font(.caption).foregroundStyle(Color.hlMuted)
            let pts = model.portfolioHistory
            let first = pts.first?.1 ?? 0, last = pts.last?.1 ?? 0
            Chart {
                ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                    LineMark(x: .value(L("Date"), p.0), y: .value("USD", p.1))
                        .foregroundStyle(last >= first ? Color.hlGreen : Color.hlRed)
                        .interpolationMethod(.monotone)
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.day().month()) } }
            .frame(height: 120)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            actionTile(L("Transfer"), "arrow.left.arrow.right") { transfer = .classTransfer }
            actionTile(L("Withdrawal"), "arrow.up.circle") { transfer = .withdraw }
            actionTile(L("Send"), "paperplane") { transfer = .send }
            actionTile(L("Deposit"), "arrow.down.circle") { transfer = .deposit }
        }
    }

    private func actionTile(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 10)
            .background(Color.hlCard, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Tab.allCases) { t in
                    Button { tab = t } label: {
                        Text(title(t))
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(tab == t ? Color.hlAccent.opacity(0.2) : Color.hlCard, in: Capsule())
                            .foregroundStyle(tab == t ? Color.hlAccent : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func title(_ t: Tab) -> String {
        switch t {
        case .positions: return L("Positions {0}", model.positions.count)
        case .orders: return L("Orders {0}", model.openOrders.count)
        case .twap: return "TWAP \(model.twaps.count)"
        default: return L(t.rawValue)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
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
            if model.openOrders.isEmpty { EmptyState(text: L("No open orders")) }
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
        case .fills:
            FillsSection()
        case .funding:
            FundingSection()
        case .spot:
            if model.spotBalances.isEmpty { EmptyState(text: L("No spot balances")) }
            ForEach(model.spotBalances) { b in
                let px: Double = model.spotPrice(b.coin)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(b.coin).font(.subheadline.bold())
                        if b.hold > 0 { Text(L("In orders: {0}", Fmt.num(b.hold, 4))).font(.caption2).foregroundStyle(Color.hlMuted) }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Fmt.num(b.total, 4)).font(.system(size: 14, design: .monospaced))
                        Text(Fmt.usd(b.total * px)).font(.caption2.monospaced()).foregroundStyle(Color.hlMuted)
                        if b.entryNtl > 0 && px > 0 && b.coin != "USDC" {
                            let pnl = b.total * px - b.entryNtl
                            Text(Fmt.signedUsd(pnl)).font(.caption2.monospaced()).foregroundStyle(Color.pnl(pnl))
                        }
                    }
                }
                .padding(10)
                .background(Color.hlCard, in: RoundedRectangle(cornerRadius: 10))
            }
        case .ledger:
            if model.ledger.isEmpty { EmptyState(text: L("No deposits or transfers")) }
            ForEach(model.ledger.prefix(100)) { e in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.detail).font(.subheadline)
                        Text(Fmt.dateTime(e.time)).font(.caption2).foregroundStyle(Color.hlMuted)
                    }
                    Spacer()
                    Text(Fmt.signedUsd(e.usdc)).font(.system(size: 13, design: .monospaced)).foregroundStyle(Color.pnl(e.usdc))
                }
                .padding(10)
                .background(Color.hlCard, in: RoundedRectangle(cornerRadius: 10))
            }
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
            ForEach(fills.prefix(150)) { FillRow(fill: $0) }
        }
    }
}

struct FundingSection: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let total = model.fundingHistory.reduce(0) { $0 + $1.usdc }
        VStack(spacing: 8) {
            Card {
                Stat(title: L("Funding, 4 weeks"), value: Fmt.signedUsd(total, 4), color: Color.pnl(total))
            }
            if model.fundingHistory.isEmpty { EmptyState(text: L("No funding payments")) }
            ForEach(model.fundingHistory.prefix(200)) { f in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.displayName(f.coin)).font(.subheadline.bold())
                        Text(L("{0} · rate {1}", Fmt.dateTime(f.time), Fmt.pct(f.rate, 4))).font(.caption2).foregroundStyle(Color.hlMuted)
                    }
                    Spacer()
                    Text(Fmt.signedUsd(f.usdc, 4)).font(.system(size: 13, design: .monospaced)).foregroundStyle(Color.pnl(f.usdc))
                }
                .padding(10)
                .background(Color.hlCard, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

struct AccountSwitcher: View {
    @Environment(AppModel.self) private var model
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
            Divider()
            Button(L("Manage accounts")) { model.tab = .settings }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: model.account?.kind == .watch ? "eye" : "person.crop.circle")
                Text(model.account?.name ?? L("Account")).font(.headline)
                Image(systemName: "chevron.down").font(.caption)
            }
            .foregroundStyle(.primary)
        }
    }
}
