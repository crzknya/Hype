import SwiftUI

/// Full-width tabs under the chart: order book, public trades, positions, orders and your own fills.
struct MarketDataTabs: View {
    @Environment(AppModel.self) private var model
    let market: Market
    let onExpand: (Int) -> Void
    @State private var tab: Tab = .book

    enum Tab: Hashable { case book, trades, positions, orders, fills, funding }

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .center, spacing: 0) {
                UnderlineTabs(items: [
                    .init(id: Tab.book, title: L("Book")),
                    .init(id: Tab.trades, title: L("Trades")),
                    .init(id: Tab.positions, title: L("Positions"), count: model.positions.count),
                    .init(id: Tab.orders, title: L("Orders"), count: model.openOrders.count),
                    .init(id: Tab.fills, title: L("Fills")),
                    .init(id: Tab.funding, title: L("Funding")),
                ], selection: $tab)
                if tab == .trades { TradeFilterMenu() }
                if tab == .book || tab == .trades {
                    Button { onExpand(tab == .book ? 0 : 1) } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 30, height: 28)
                            .contentShape(Rectangle())
                    }
                    .foregroundStyle(Color.hlMuted)
                }
            }
            switch tab {
            case .book: SideBySideBook(market: market)
            case .trades: TradesPanel(market: market, limit: 30, wide: true)
            case .positions: AccountPanel(coin: market.id, fixedTab: 0)
            case .orders: AccountPanel(coin: market.id, fixedTab: 1)
            case .fills: AccountPanel(coin: market.id, fixedTab: 2)
            case .funding: TradeFundingPanel(coin: market.id)
            }
        }
    }
}

/// Funding payments on the trade screen, optionally only this market's.
struct TradeFundingPanel: View {
    @Environment(AppModel.self) private var model
    let coin: String
    @State private var onlyThisCoin = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(L("Only {0}", model.displayName(coin)), isOn: $onlyThisCoin).toggleStyle(CheckToggle()).font(.caption)
            if model.account == nil {
                EmptyState(text: L("Connect an account in Settings to see positions and trade"), icon: "person.crop.circle.badge.plus")
            } else {
                FundingSection(coin: onlyThisCoin ? coin : nil)
            }
        }
    }
}

/// Full-width order book: bids on the left, asks on the right.
struct SideBySideBook: View {
    @Environment(AppModel.self) private var model
    let market: Market
    var rows = 12
    @State private var showUsd = false

    var body: some View {
        @Bindable var model = model
        let bids = Array(model.book.bids.prefix(rows))
        let asks = Array(model.book.asks.prefix(rows))
        let bidCum = cumulative(bids), askCum = cumulative(asks)
        let maxCum = max(bidCum.last ?? 0, askCum.last ?? 0, 1e-12)
        let dec = market.priceDecimals(model.mid(market.id))
        VStack(spacing: 4) {
            HStack {
                Menu {
                    Picker(L("Grouping"), selection: $model.bookSigFigs) {
                        Text(L("No grouping")).tag(Int?.none)
                        Text(L("5 digits")).tag(Int?.some(5))
                        Text(L("4 digits")).tag(Int?.some(4))
                        Text(L("3 digits")).tag(Int?.some(3))
                        Text(L("2 digits")).tag(Int?.some(2))
                    }
                } label: {
                    Label(L("Grouping"), systemImage: "line.3.horizontal.decrease")
                        .labelStyle(.iconOnly)
                        .frame(width: 28, height: 22)
                }
                Spacer()
                if let mid = model.topMid {
                    Text(Fmt.price(mid, decimals: dec)).font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                    if let s = model.topSpread, mid > 0 {
                        Text(Fmt.pct(s / mid, 3, signed: false)).font(.system(size: 10)).foregroundStyle(Color.hlMuted)
                    }
                }
                BookAgeBadge()
                Spacer()
                Button { showUsd.toggle() } label: {
                    Text(showUsd ? "USD" : market.base).font(.system(size: 11, weight: .semibold))
                        .frame(minWidth: 28, minHeight: 22)
                }
            }
            .foregroundStyle(Color.hlMuted)
            HStack(spacing: 6) {
                Text(L("Bids")).foregroundStyle(Color.hlGreen).frame(maxWidth: .infinity, alignment: .leading)
                Text(L("Asks")).foregroundStyle(Color.hlRed).frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .semibold))
            HStack(alignment: .top, spacing: 6) {
                VStack(spacing: 1) {
                    ForEach(Array(bids.enumerated()), id: \.element.id) { i, l in
                        row(l, cum: bidCum[i], maxCum: maxCum, isBid: true, dec: dec)
                    }
                    ForEach(0..<max(0, rows - bids.count), id: \.self) { _ in Color.clear.frame(height: 20) }
                }
                VStack(spacing: 1) {
                    ForEach(Array(asks.enumerated()), id: \.element.id) { i, l in
                        row(l, cum: askCum[i], maxCum: maxCum, isBid: false, dec: dec)
                    }
                    ForEach(0..<max(0, rows - asks.count), id: \.self) { _ in Color.clear.frame(height: 20) }
                }
            }
            if bids.isEmpty && asks.isEmpty { ProgressView().padding() }
        }
    }

    private func cumulative(_ levels: [BookLevel]) -> [Double] {
        var acc = 0.0
        return levels.map { acc += $0.sz; return acc }
    }

    private func amount(_ l: BookLevel) -> String {
        showUsd ? Fmt.compact(l.sz * l.px) : Fmt.num(l.sz, min(market.szDecimals, 4))
    }

    private func row(_ l: BookLevel, cum: Double, maxCum: Double, isBid: Bool, dec: Int) -> some View {
        let color = isBid ? Color.hlGreen : Color.hlRed
        return GeometryReader { g in
            ZStack(alignment: isBid ? .trailing : .leading) {
                Rectangle().fill(color.opacity(0.14)).frame(width: g.size.width * CGFloat(cum / maxCum))
                HStack {
                    if isBid {
                        Text(amount(l))
                        Spacer(minLength: 4)
                        Text(Fmt.price(l.px, decimals: dec)).foregroundStyle(color)
                    } else {
                        Text(Fmt.price(l.px, decimals: dec)).foregroundStyle(color)
                        Spacer(minLength: 4)
                        Text(amount(l))
                    }
                }
                .padding(.horizontal, 4)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
        }
        .frame(height: 20)
        .contentShape(Rectangle())
        .onTapGesture {
            model.pendingPrice = l.px
            Haptics.tap(enabled: model.haptics)
        }
    }
}

/// Pinned Long / Short pair.
struct LongShortBar: View {
    let market: Market
    let action: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            PrimaryButton(title: market.isSpot ? L("Buy") : L("Long"), color: .hlGreen) { action(true) }
            PrimaryButton(title: market.isSpot ? L("Sell") : L("Short"), color: .hlRed) { action(false) }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(.ultraThinMaterial)
    }
}

/// Order form in a sheet; at the half-height detent the chart and book stay usable behind it.
struct OrderSheet: View {
    @Environment(\.dismiss) private var dismiss
    let market: Market
    let isBuy: Bool
    @State private var bar = OrderBarState()
    @State private var detent: PresentationDetent = .large

    var body: some View {
        NavigationStack {
            ScrollView {
                OrderFormView(market: market, bar: bar, initialBuy: isBuy, onPlaced: { dismiss() })
                    .padding(.horizontal, 14)
                    .padding(.top, 4)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) { OrderActionBar(bar: bar) }
            .themedBackground()
            .navigationTitle(market.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Close")) { dismiss() } } }
            .keyboardDoneToolbar()
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .presentationDragIndicator(.visible)
    }
}


/// Shows "⚠ Ns" when the order-book ladder hasn't been refreshed for a while.
struct BookAgeBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { t in
            let age = t.date.timeIntervalSince(model.bookReceivedAt)
            if model.bookReceivedAt != .distantPast && age > 3 {
                Text("⚠ \(Int(age))s").font(.system(size: 10, weight: .semibold)).foregroundStyle(.orange)
            }
        }
    }
}
