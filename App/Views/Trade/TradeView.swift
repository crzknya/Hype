import SwiftUI

/// Trade screen layouts, selectable in Settings.
enum TradeLayout: String, CaseIterable, Identifiable, Codable {
    case sheet, tabs, classic
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sheet: return L("Order sheet")
        case .tabs: return L("Two tabs")
        case .classic: return L("Classic")
        }
    }
    var help: String {
        switch self {
        case .sheet: return L("Chart, order book and positions full width; Long/Short open the order form in a sheet.")
        case .tabs: return L("Separate Chart and Order tabs at the top of the trade screen.")
        case .classic: return L("Order form and order book side by side under a collapsible chart.")
        }
    }
}

struct OrderSheetRequest: Identifiable {
    let id = UUID()
    let isBuy: Bool
}

struct TradeView: View {
    @Environment(AppModel.self) private var model
    @State private var showPicker = false
    @State private var rightPanel = 0   // classic layout: 0 book, 1 trades
    @State private var depthFullScreen = false
    @State private var depthTab = 0
    @State private var chartFullScreen = false
    @State private var showIndicators = false
    @State private var orderBar = OrderBarState()
    @State private var dragStartHeight: Double?
    @State private var page = 0               // tabs layout: 0 chart, 1 order
    @State private var pageSide: Bool?        // side requested when switching to the order tab
    @State private var orderSheet: OrderSheetRequest?
    @State private var lastSide = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    if let m = model.selectedMarket {
                        TradeHeader(market: m)
                        switch model.tradeLayout {
                        case .sheet: sheetLayout(m)
                        case .tabs: tabsLayout(m)
                        case .classic: classicLayout(m)
                        }
                    } else {
                        ProgressView().padding(.top, 80)
                    }
                }
                .padding(.bottom, 20)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                if let m = model.selectedMarket { bottomBar(m) }
            }
            .themedBackground()
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
                    if model.tradeLayout == .classic {
                        Button { withAnimation { model.showChart.toggle() } } label: {
                            Image(systemName: model.showChart ? "chart.xyaxis.line" : "chart.line.flattrend.xyaxis")
                        }
                    } else {
                        Button { chartFullScreen = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    }
                }
            }
            .keyboardDoneToolbar()
            .sheet(isPresented: $showPicker) { MarketPickerSheet() }
            .onChange(of: model.tradeTabReselected) { _, _ in
                switch model.tradeLayout {
                case .tabs: withAnimation { page = page == 0 ? 1 : 0 }
                case .sheet: orderSheet = orderSheet == nil ? OrderSheetRequest(isBuy: lastSide) : nil
                case .classic: break
                }
            }
            .sheet(item: $orderSheet) { req in
                if let m = model.selectedMarket { OrderSheet(market: m, isBuy: req.isBuy) }
            }
            .fullScreenCover(isPresented: $chartFullScreen) {
                if let m = model.selectedMarket { ChartScreen(market: m) }
            }
            .sheet(isPresented: $showIndicators) { IndicatorsSheet() }
            .fullScreenCover(isPresented: $depthFullScreen) {
                if let m = model.selectedMarket { MarketDepthScreen(market: m, tab: depthTab) }
            }
            .onChange(of: model.pendingPrice) { _, p in
                // A price tapped in the book opens the order form where it isn't on screen.
                guard p != nil else { return }
                switch model.tradeLayout {
                case .sheet: if orderSheet == nil { orderSheet = OrderSheetRequest(isBuy: lastSide) }
                case .tabs: if page == 0 { withAnimation { page = 1 } }
                case .classic: break
                }
            }
        }
    }

    // MARK: Layouts

    @ViewBuilder
    private func sheetLayout(_ m: Market) -> some View {
        chartSection(m)
        MarketDataTabs(market: m) { tab in depthTab = tab; depthFullScreen = true }
            .padding(.horizontal, 10)
    }

    @ViewBuilder
    private func tabsLayout(_ m: Market) -> some View {
        Picker("", selection: $page) {
            Text(L("Chart")).tag(0)
            Text(L("Order")).tag(1)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 10)
        // A side requested by the Long / Short buttons applies once; switching tabs back keeps the user's choice.
        .onChange(of: page) { _, p in if p == 0 { pageSide = nil } }
        if page == 0 {
            chartSection(m)
            MarketDataTabs(market: m) { tab in depthTab = tab; depthFullScreen = true }
                .padding(.horizontal, 10)
        } else {
            formAndBook(m)
            AccountPanel(coin: m.id).padding(.horizontal, 10)
        }
    }

    @ViewBuilder
    private func classicLayout(_ m: Market) -> some View {
        if model.showChart { chartSection(m) }
        formAndBook(m)
        AccountPanel(coin: m.id).padding(.horizontal, 10)
    }

    @ViewBuilder
    private func bottomBar(_ m: Market) -> some View {
        switch model.tradeLayout {
        case .sheet:
            LongShortBar(market: m) { buy in
                lastSide = buy
                orderSheet = OrderSheetRequest(isBuy: buy)
            }
        case .tabs:
            if page == 1 {
                OrderActionBar(bar: orderBar)
            } else {
                LongShortBar(market: m) { buy in
                    pageSide = buy
                    withAnimation { page = 1 }
                }
            }
        case .classic:
            OrderActionBar(bar: orderBar)
        }
    }

    /// Order form with a compact book/trades column (tabs and classic layouts).
    private func formAndBook(_ m: Market) -> some View {
        HStack(alignment: .top, spacing: 8) {
            OrderFormView(market: m, bar: orderBar, initialBuy: pageSide)
                .frame(maxWidth: .infinity)
            VStack(spacing: 6) {
                Picker("", selection: $rightPanel) {
                    Text(L("Book")).tag(0)
                    Text(L("Trades")).tag(1)
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)
                HStack {
                    if rightPanel == 1 { TradeFilterMenu() }
                    Spacer()
                    Button { depthTab = rightPanel; depthFullScreen = true } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11))
                    }
                    .foregroundStyle(Color.hlMuted)
                }
                if rightPanel == 0 { OrderBookPanel(market: m) } else { TradesPanel(market: m) }
            }
            .frame(width: 148)
        }
        .padding(.horizontal, 10)
    }

    @ViewBuilder
    private func chartSection(_ m: Market) -> some View {
        VStack(spacing: 6) {
            ChartToolbar(onFullScreen: { chartFullScreen = true }, onIndicators: { showIndicators = true })
            PriceChartView(market: m, inScrollingPage: true)
                .frame(height: model.chartHeight)
                .padding(.horizontal, 6)
            resizeHandle
        }
    }

    /// Drag to change the chart height (persisted).
    private var resizeHandle: some View {
        ZStack {
            Color.clear.frame(height: 16)
            Capsule().fill(Color.hlMuted.opacity(0.28)).frame(width: 36, height: 4)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .highPriorityGesture(
            // Global coordinates: the handle moves while the chart resizes, so local translation would oscillate.
            DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { v in
                    if dragStartHeight == nil { dragStartHeight = model.chartHeight }
                    model.chartHeight = min(560, max(140, (dragStartHeight ?? 250) + v.translation.height))
                }
                .onEnded { _ in
                    dragStartHeight = nil
                    Haptics.tap(enabled: model.haptics)
                }
        )
        .accessibilityLabel(L("Resize chart"))
    }
}

struct TradeHeader: View {
    @Environment(AppModel.self) private var model
    let market: Market
    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        let px = model.lastPrice(market.id)
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
                    if let s = model.topSpread, let mid = model.topMid, mid > 0 {
                        Stat(title: L("Spread"), value: Fmt.pct(s / mid, 3, signed: false))
                    }
                }
            }
            if market.isHip3 { Hip3Banner(market: market) }
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


/// The order form publishes its primary action here so the button can be pinned above the tab bar.
@Observable
final class OrderBarState {
    var title = ""
    var isBuy = true
    var busy = false
    var enabled = false
    var detail = ""
    var submit: () -> Void = {}
}

/// Pinned "Long / Short" button at the bottom of the trade screen.
struct OrderActionBar: View {
    let bar: OrderBarState

    var body: some View {
        VStack(spacing: 4) {
            if !bar.detail.isEmpty {
                Text(bar.detail).font(.caption2.monospacedDigit()).foregroundStyle(Color.hlMuted)
            }
            PrimaryButton(title: bar.title, color: bar.isBuy ? .hlGreen : .hlRed, busy: bar.busy, disabled: !bar.enabled) {
                bar.submit()
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(.ultraThinMaterial)
    }
}
