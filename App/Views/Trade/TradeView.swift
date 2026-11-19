import SwiftUI

struct TradeView: View {
    @Environment(AppModel.self) private var model
    @State private var showPicker = false
    @State private var rightPanel = 0   // 0 book, 1 trades
    @State private var depthFullScreen = false
    @State private var chartFullScreen = false
    @State private var showIndicators = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    if let m = model.selectedMarket {
                        TradeHeader(market: m)
                        if model.showChart { chartSection(m) }
                        HStack(alignment: .top, spacing: 8) {
                            OrderFormView(market: m)
                                .frame(maxWidth: .infinity)
                            VStack(spacing: 6) {
                                Picker("", selection: $rightPanel) {
                                    Text(L("Order book")).tag(0)
                                    Text(L("Trades")).tag(1)
                                }
                                .pickerStyle(.segmented)
                                .controlSize(.mini)
                                HStack {
                                    if rightPanel == 1 { TradeFilterMenu() }
                                    Spacer()
                                    Button { depthFullScreen = true } label: {
                                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11))
                                    }
                                    .foregroundStyle(Color.hlMuted)
                                }
                                if rightPanel == 0 { OrderBookPanel(market: m) } else { TradesPanel(market: m) }
                            }
                            .frame(width: 148)
                        }
                        .padding(.horizontal, 10)
                        AccountPanel(coin: m.id)
                            .padding(.horizontal, 10)
                    } else {
                        ProgressView().padding(.top, 80)
                    }
                }
                .padding(.bottom, 20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.hlBg)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Button { showPicker = true } label: {
                        HStack(spacing: 4) {
                            Text(model.selectedMarket?.name ?? model.selectedCoin).font(.headline)
                            if let m = model.selectedMarket, !m.isSpot { Badge(text: "\(m.maxLeverage)x") }
                            if let m = model.selectedMarket, m.isSpot { Badge(text: "SPOT", color: .orange) }
                            if let m = model.selectedMarket, m.isHip3 { Badge(text: m.dex, color: .orange) }
                            Image(systemName: "chevron.down").font(.caption)
                        }
                        .foregroundStyle(.primary)
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { model.toggleFavorite(model.selectedCoin) } label: {
                        Image(systemName: model.favorites.contains(model.selectedCoin) ? "star.fill" : "star")
                            .foregroundStyle(model.favorites.contains(model.selectedCoin) ? .yellow : Color.hlMuted)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { withAnimation { model.showChart.toggle() } } label: {
                        Image(systemName: model.showChart ? "chart.xyaxis.line" : "chart.line.flattrend.xyaxis")
                    }
                }
            }
            .keyboardDoneToolbar()
            .sheet(isPresented: $showPicker) { MarketPickerSheet() }
            .fullScreenCover(isPresented: $chartFullScreen) {
                if let m = model.selectedMarket { ChartScreen(market: m) }
            }
            .sheet(isPresented: $showIndicators) { IndicatorsSheet() }
            .fullScreenCover(isPresented: $depthFullScreen) {
                if let m = model.selectedMarket { MarketDepthScreen(market: m, tab: rightPanel) }
            }
        }
    }

    @ViewBuilder
    private func chartSection(_ m: Market) -> some View {
        VStack(spacing: 6) {
            ChartToolbar(onFullScreen: { chartFullScreen = true }, onIndicators: { showIndicators = true })
            PriceChartView(market: m)
                .frame(height: 250)
                .padding(.horizontal, 6)
        }
    }

}

struct TradeHeader: View {
    @Environment(AppModel.self) private var model
    let market: Market
    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        let px = model.mid(market.id)
        let change = market.prevDayPx > 0 && px > 0 ? px / market.prevDayPx - 1 : market.change24h
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(Fmt.price(px))
                    .font(.system(size: 26, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.pnl(change))
                    .contentTransition(.numericText())
                Text(Fmt.pct(change)).font(.subheadline.monospaced()).foregroundStyle(Color.pnl(change))
                Spacer()
                ConnectionDot(connected: model.wsConnected)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    if !market.isSpot {
                        Stat(title: "Mark", value: Fmt.price(market.markPx))
                        Stat(title: "Oracle", value: Fmt.price(market.oraclePx))
                        Stat(title: L("Funding / countdown"),
                             value: "\(Fmt.pct(market.funding, 4)) · \(Fmt.countdown(secondsToFunding))",
                             color: Color.pnl(market.funding))
                        Stat(title: L("Funding APR"), value: Fmt.pct(market.fundingAnnual, 1), color: Color.pnl(market.funding))
                        Stat(title: L("Open interest"), value: Fmt.compactUsd(market.openInterestUsd))
                    }
                    Stat(title: L("24h volume"), value: Fmt.compactUsd(market.dayNtlVlm))
                    if let s = model.book.spread, let mid = model.book.mid, mid > 0 {
                        Stat(title: L("Spread"), value: Fmt.pct(s / mid, 3, signed: false))
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .onReceive(timer) { now = $0 }
    }

    private var secondsToFunding: Int {
        let s = Int(now.timeIntervalSince1970)
        return 3600 - s % 3600
    }
}

extension AppModel {
    func chartLines(_ m: Market) -> [PriceLine] {
        var lines: [PriceLine] = []
        if let p = position(m.id) {
            lines.append(PriceLine(price: p.entryPx, color: p.isLong ? .hlGreen : .hlRed,
                                   label: "\(p.isLong ? L("Long") : L("Short")) \(Fmt.num(p.size, m.szDecimals)) · \(Fmt.signedUsd(p.unrealizedPnl))"))
            if let liq = p.liquidationPx { lines.append(PriceLine(price: liq, color: .orange, label: L("Liquidation"))) }
        }
        for o in orders(for: m.id) {
            let px = o.isTrigger ? o.triggerPx : o.limitPx
            lines.append(PriceLine(price: px, color: o.isBuy ? .hlGreen.opacity(0.8) : .hlRed.opacity(0.8),
                                   label: "\(o.typeTitle) \(Fmt.num(o.sz, m.szDecimals))"))
        }
        for a in alerts where a.coin == m.id {
            lines.append(PriceLine(price: a.price, color: .yellow, label: "🔔"))
        }
        return lines
    }
}
