import SwiftUI

struct OrderBookPanel: View {
    @Environment(AppModel.self) private var model
    let market: Market
    var rows = 10
    var wide = false                 // full-screen layout: extra Total column, larger font
    var onPick: (() -> Void)? = nil  // called after a price is tapped
    @State private var showUsd = false

    var body: some View {
        @Bindable var model = model
        let asks = Array(model.book.asks.prefix(rows))
        let bids = Array(model.book.bids.prefix(rows))
        let askCum = cumulative(asks)
        let bidCum = cumulative(bids)
        let maxCum = max(askCum.last ?? 0, bidCum.last ?? 0, 1e-12)
        let dec = decimals

        VStack(spacing: 1) {
            HStack(spacing: 8) {
                Menu {
                    Picker(L("Grouping"), selection: $model.bookSigFigs) {
                        Text(L("No grouping")).tag(Int?.none)
                        Text(L("5 digits")).tag(Int?.some(5))
                        Text(L("4 digits")).tag(Int?.some(4))
                        Text(L("3 digits")).tag(Int?.some(3))
                        Text(L("2 digits")).tag(Int?.some(2))
                    }
                } label: {
                    HStack(spacing: 2) {
                        Text(L("Price"))
                        Image(systemName: "line.3.horizontal.decrease").font(.system(size: 8))
                    }
                }
                .frame(maxWidth: wide ? .infinity : nil, alignment: .leading)
                if !wide { Spacer() }
                Button { showUsd.toggle() } label: { Text(showUsd ? "USD" : market.base) }
                    .frame(maxWidth: wide ? .infinity : nil, alignment: .trailing)
                if wide {
                    Text(L("Total")).frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.horizontal, wide ? 6 : 0)
            .font(.system(size: wide ? 12 : 10))
            .foregroundStyle(Color.hlMuted)
            .padding(.bottom, 2)

            // Fixed row count so the panel never changes height when a side is thin.
            ForEach(0..<max(0, rows - asks.count), id: \.self) { _ in Color.clear.frame(height: wide ? 26 : 17) }
            ForEach(Array(asks.enumerated().reversed()), id: \.element.id) { i, l in
                row(l, cum: askCum[i], maxCum: maxCum, isBid: false, dec: dec)
            }
            HStack {
                Text(model.topMid.map { Fmt.price($0, decimals: dec) } ?? "—")
                    .font(.system(size: wide ? 16 : 13, weight: .bold, design: .monospaced))
                Spacer()
                BookAgeBadge()
                if let s = model.topSpread, let mid = model.topMid, mid > 0 {
                    Text(L("Spread") + " " + Fmt.pct(s / mid, 3, signed: false))
                        .font(.system(size: wide ? 11 : 9)).foregroundStyle(Color.hlMuted)
                }
            }
            .padding(.vertical, 4)
            ForEach(Array(bids.enumerated()), id: \.element.id) { i, l in
                row(l, cum: bidCum[i], maxCum: maxCum, isBid: true, dec: dec)
            }
            ForEach(0..<max(0, rows - bids.count), id: \.self) { _ in Color.clear.frame(height: wide ? 26 : 17) }
            if model.book.bids.isEmpty && model.book.asks.isEmpty {
                ProgressView().padding()
            }
        }
    }

    private var decimals: Int {
        market.priceDecimals(model.mid(market.id))
    }

    private func cumulative(_ levels: [BookLevel]) -> [Double] {
        var acc = 0.0
        return levels.map { acc += $0.sz; return acc }
    }

    private func amount(_ sz: Double, _ px: Double) -> String {
        showUsd ? Fmt.compact(sz * px) : Fmt.num(sz, min(market.szDecimals, 4))
    }

    private func row(_ l: BookLevel, cum: Double, maxCum: Double, isBid: Bool, dec: Int) -> some View {
        let color = isBid ? Color.hlGreen : Color.hlRed
        return GeometryReader { g in
            ZStack(alignment: .trailing) {
                Rectangle().fill(color.opacity(0.14)).frame(width: g.size.width * CGFloat(cum / maxCum))
                Group {
                    if wide {
                        HStack(spacing: 8) {
                            Text(Fmt.price(l.px, decimals: dec)).foregroundStyle(color).frame(maxWidth: .infinity, alignment: .leading)
                            Text(amount(l.sz, l.px)).frame(maxWidth: .infinity, alignment: .trailing)
                            Text(amount(cum, l.px)).foregroundStyle(Color.hlMuted).frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .padding(.horizontal, 6)
                    } else {
                        HStack {
                            Text(Fmt.price(l.px, decimals: dec)).foregroundStyle(color)
                            Spacer()
                            Text(amount(l.sz, l.px))
                        }
                    }
                }
                .font(.system(size: wide ? 14 : 11, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
        }
        .frame(height: wide ? 26 : 17)
        .contentShape(Rectangle())
        .onTapGesture {
            model.pendingPrice = l.px
            Haptics.tap(enabled: model.haptics)
            onPick?()
        }
    }
}

/// Menu for the minimum trade size shown in the trades feed.
struct TradeFilterMenu: View {
    @Environment(AppModel.self) private var model
    static let presets: [Double] = [0, 500, 1_000, 5_000, 10_000, 50_000, 100_000]

    var body: some View {
        Menu {
            ForEach(Self.presets, id: \.self) { v in
                Button {
                    model.minTradeUsd = v
                } label: {
                    let title = v == 0 ? L("All trades") : "> " + Self.label(v)
                    if model.minTradeUsd == v { Label(title, systemImage: "checkmark") } else { Text(title) }
                }
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                if model.minTradeUsd > 0 { Text(">" + Self.label(model.minTradeUsd)) }
            }
            .font(.system(size: 11))
            .foregroundStyle(model.minTradeUsd > 0 ? Color.hlAccent : Color.hlMuted)
        }
    }
}

extension TradeFilterMenu {
    /// "$500", "$1K", "$50K" — short labels without trailing ".0".
    static func label(_ v: Double) -> String {
        if v >= 1_000 { return "$" + Fmt.input(v / 1_000, 1) + "K" }
        return "$" + Fmt.input(v, 0)
    }
}

struct TradesPanel: View {
    @Environment(AppModel.self) private var model
    let market: Market
    var limit = 22
    var wide = false
    @State private var picked: PublicTrade?

    var body: some View {
        let trades = model.trades.filter { $0.px * $0.sz >= model.minTradeUsd }
        VStack(spacing: 1) {
            if wide { wideHeader } else { compactHeader }
            ForEach(trades.prefix(limit)) { t in
                Group {
                    if wide { wideRow(t) } else { compactRow(t) }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    guard t.buyer != nil || t.seller != nil else { return }
                    picked = t
                    Haptics.tap(enabled: model.haptics)
                }
            }
            if model.trades.isEmpty {
                ProgressView().padding()
            } else if trades.isEmpty {
                Text(L("No trades above {0} yet", TradeFilterMenu.label(model.minTradeUsd)))
                    .font(.system(size: wide ? 12 : 10)).foregroundStyle(Color.hlMuted).padding(.vertical, 8)
            }
        }
        // Tap a trade: follow its taker or maker as a watch-only account.
        .confirmationDialog(dialogTitle, isPresented: Binding(get: { picked != nil }, set: { if !$0 { picked = nil } }),
                            titleVisibility: .visible, presenting: picked) { t in
            if let a = t.taker {
                Button(L("Watch taker {0} ({1})", Address.short(a), t.isBuy ? L("buyer") : L("seller"))) { model.addWatchAccount(a) }
            }
            if let a = t.maker {
                Button(L("Watch maker {0} ({1})", Address.short(a), t.isBuy ? L("seller") : L("buyer"))) { model.addWatchAccount(a) }
            }
            if let a = t.taker {
                Button(L("Copy taker address")) { UIPasteboard.general.string = a; model.show(.success, L("Address copied")) }
            }
            if let a = t.maker {
                Button(L("Copy maker address")) { UIPasteboard.general.string = a; model.show(.success, L("Address copied")) }
            }
            Button(L("Cancel"), role: .cancel) {}
        } message: { t in
            Text(L("{0} {1} at {2} · {3}. The taker crossed the spread (market or aggressive order); the maker's resting limit order was filled.",
                   t.isBuy ? L("Buy") : L("Sell"), Fmt.num(t.sz, min(market.szDecimals, 4)), Fmt.price(t.px), Fmt.compactUsd(t.px * t.sz)))
        }
    }

    private var dialogTitle: String { L("Follow a trader") }

    private var compactHeader: some View {
        HStack {
            Text(L("Price")); Spacer(); Text(L("Size"))
            Text(L("Time")).frame(width: 40, alignment: .trailing)
        }
        .font(.system(size: 9)).foregroundStyle(Color.hlMuted)
    }

    private func compactRow(_ t: PublicTrade) -> some View {
        HStack(spacing: 4) {
            Text(Fmt.price(t.px)).foregroundStyle(t.isBuy ? Color.hlGreen : Color.hlRed)
            Spacer()
            Text(Fmt.compact(t.sz))
            Text(String(Fmt.time(t.time).suffix(5))).foregroundStyle(Color.hlMuted).frame(width: 40, alignment: .trailing)
        }
        .font(.system(size: 10, design: .monospaced))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(height: 16)
    }

    /// Full-screen: four evenly spread columns.
    private var wideHeader: some View {
        HStack(spacing: 8) {
            Text(L("Price")).frame(maxWidth: .infinity, alignment: .leading)
            Text(L("Size") + " " + market.base).frame(maxWidth: .infinity, alignment: .trailing)
            Text("USD").frame(maxWidth: .infinity, alignment: .trailing)
            Text(L("Time")).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.hlMuted)
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
    }

    private func wideRow(_ t: PublicTrade) -> some View {
        let usd = t.px * t.sz
        let big = usd >= 100_000
        let color = t.isBuy ? Color.hlGreen : Color.hlRed
        return HStack(spacing: 8) {
            Text(Fmt.price(t.px)).foregroundStyle(color).frame(maxWidth: .infinity, alignment: .leading)
            Text(Fmt.num(t.sz, min(market.szDecimals, 4))).frame(maxWidth: .infinity, alignment: .trailing)
            Text(Fmt.compactUsd(usd)).fontWeight(big ? .bold : .regular).foregroundStyle(big ? color : .primary)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(Fmt.time(t.time)).foregroundStyle(Color.hlMuted).frame(maxWidth: .infinity, alignment: .trailing)
        }
        // Same type and row height as the side-by-side order book.
        .font(.system(size: 12, design: .monospaced))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.horizontal, 4)
        .frame(height: 20)
        .background(color.opacity(big ? 0.14 : 0), in: RoundedRectangle(cornerRadius: 4))
    }
}

/// Full-screen order book and trades feed.
struct MarketDepthScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let market: Market
    @State var tab: Int

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Picker("", selection: $tab) {
                    Text(L("Order book")).tag(0)
                    Text(L("Trades")).tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                ScrollView {
                    if tab == 0 {
                        OrderBookPanel(market: market, rows: 30, wide: true, onPick: { dismiss() })
                            .padding(.horizontal)
                    } else {
                        TradesPanel(market: market, limit: 500, wide: true)
                            .padding(.horizontal)
                    }
                }
            }
            .themedBackground()
            .navigationTitle(market.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Close")) { dismiss() } }
                if tab == 1 { ToolbarItem(placement: .topBarTrailing) { TradeFilterMenu() } }
            }
        }
    }
}
