import SwiftUI
import HyperCore

struct OrderFormView: View {
    @Environment(AppModel.self) private var model
    let market: Market
    let bar: OrderBarState
    /// Side to start with (from the Long/Short buttons); nil keeps the default.
    var initialBuy: Bool? = nil
    /// Called after an order was placed successfully (the sheet closes itself).
    var onPlaced: (() -> Void)? = nil

    /// Form fields live in a shared store so switching Chart ⇄ Order (or reopening the sheet) keeps them.
    @Bindable private var f = OrderFormFields.shared
    @State private var busy = false
    @State private var confirm: IdentifiedDraft?
    @State private var showLeverage = false

    var body: some View {
        VStack(spacing: 8) {
            if !market.isSpot { leverageRow }
            sideToggle
            typeMenu

            if f.type.needsTrigger {
                NumField(title: L("Trigger"), text: $f.triggerText, placeholder: Fmt.price(refMid)) { midButton { f.triggerText = $0 } }
            }
            if f.type.needsPrice {
                NumField(title: L("Price"), text: $f.priceText, placeholder: Fmt.price(refMid)) { midButton { f.priceText = $0 } }
            }
            if f.type == .scale {
                NumField(title: L("From"), text: $f.scaleStartText, placeholder: Fmt.price(refMid)) { midButton { f.scaleStartText = $0 } }
                NumField(title: L("To"), text: $f.scaleEndText, placeholder: Fmt.price(refMid))
                Stepper(L("Orders: {0}", f.scaleCount), value: $f.scaleCount, in: 2...100).font(.caption)
                HStack {
                    Text(L("Skew {0}", Fmt.num(f.scaleSkew, 1))).font(.caption).frame(width: 64, alignment: .leading)
                    Slider(value: $f.scaleSkew, in: 0.2...5, step: 0.1)
                }
            }
            if f.type == .twap {
                Stepper(L("Duration: {0}", twapLabel), value: $f.twapMinutes, in: 5...1440, step: f.twapMinutes < 60 ? 5 : 30).font(.caption)
                Toggle(L("Randomize intervals"), isOn: $f.twapRandomize).font(.caption)
            }
            if f.type == .trailing { trailingFields }
            if f.type == .chase {
                NumField(title: L("Max distance %"), text: $f.chaseDistText, placeholder: L("none")) {
                    if let d = Fmt.parse(f.chaseDistText), d > 0, refMid > 0 {
                        Text("≈ \(Fmt.usd(refMid * d / 100))").font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.hlMuted)
                    }
                }
                HStack(spacing: 4) {
                    ForEach([0.02, 0.05, 0.1, 0.25], id: \.self) { p in
                        Button(Fmt.num(p, 2) + "%") { f.chaseDistText = Fmt.input(p, 2) }
                            .font(.system(size: 10, weight: .semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 5)
                            .background(Fmt.parse(f.chaseDistText) == p ? Color.hlAccent.opacity(0.25) : Color.hlCard2,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .buttonStyle(.plain)
                    }
                    Button(L("none")) { f.chaseDistText = "" }
                        .font(.system(size: 10, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                        .background(f.chaseDistText.isEmpty ? Color.hlAccent.opacity(0.25) : Color.hlCard2,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .buttonStyle(.plain)
                }
                Text(L("Post-only limit kept one tick inside the spread until it fills. Runs while the app is open; stopping leaves a normal limit order."))
                    .font(.system(size: 10)).foregroundStyle(Color.hlMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            sizeField
            sizeSlider

            HStack {
                Text(L("Available")).font(.system(size: 11)).foregroundStyle(Color.hlMuted)
                Spacer()
                Text(availableText).font(.system(size: 11, design: .monospaced))
            }

            options
            if f.tpslOn && !market.isSpot && f.type.allowsTpsl { tpslFields }
            summary

            if !model.canTrade {
                Text(model.account == nil ? L("Add an account in Settings") : L("Watch-only account"))
                    .font(.caption2).foregroundStyle(Color.hlMuted)
            }
        }
        .font(.system(size: 13))
        .onChange(of: model.pendingPrice) { _, _ in applyPendingPrice() }
        .onChange(of: market.id) { _, _ in reset(); syncBar() }
        .onAppear {
            // Fields persist across Chart ⇄ Order switches; only another market starts from scratch.
            if f.marketId != market.id { reset() }
            if let b = initialBuy { f.isBuy = b }
            // Remember the last order type between sheet openings.
            if let t = OrderTypeUI(rawValue: model.lastOrderType), availableTypes.contains(t) { f.type = t }
            applyPendingPrice()
            syncBar()
        }
        .onChange(of: f.type) { _, t in model.lastOrderType = t.rawValue }
        .onChange(of: f.isBuy) { _, _ in syncBar() }
        .onChange(of: f.type) { _, _ in syncBar() }
        .onChange(of: busy) { _, _ in syncBar() }
        .onChange(of: model.canTrade) { _, _ in syncBar() }
        .onChange(of: f.sizeText) { _, _ in syncBar() }
        .onChange(of: f.priceText) { _, _ in syncBar() }
        .onChange(of: f.riskOn) { _, on in if on { f.tpslOn = true } }
        .onChange(of: f.tpslOn) { _, on in if !on { f.riskOn = false } }
        .onChange(of: f.type) { _, t in
            // TP/SL and risk sizing only exist for plain market/limit orders.
            if !t.allowsTpsl { f.riskOn = false }
            if f.pct > 0 { applyPct(f.pct) }
        }
        .onChange(of: f.isBuy) { _, _ in if f.pct > 0 { applyPct(f.pct) } }
        .onChange(of: f.reduceOnly) { _, _ in if f.pct > 0 { applyPct(f.pct) } }
        .sheet(isPresented: $showLeverage) { LeverageSheet(market: market) }
        .sheet(item: $confirm) { d in
            OrderConfirmSheet(draft: d.draft, summary: summaryLines(d.draft)) { send(d.draft) }
                .presentationDetents([.medium])
        }
    }

    // MARK: Subviews

    private var leverageRow: some View {
        Button { showLeverage = true } label: {
            HStack {
                Text(model.activeAsset.isCross && model.crossAllowed(market) ? "Cross" : "Isolated")
                Spacer()
                Text("\(currentLeverage)x").bold()
                Image(systemName: "slider.horizontal.3").font(.caption)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10).frame(height: 30)
            .background(Color.hlCard2, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!model.canTrade)
    }

    private var sideToggle: some View {
        HStack(spacing: 0) {
            sideButton(true)
            sideButton(false)
        }
        .background(Color.hlCard2, in: RoundedRectangle(cornerRadius: 8))
    }

    private func sideButton(_ buy: Bool) -> some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { f.isBuy = buy } } label: {
            Text(buy ? (market.isSpot ? L("Buy") : L("Long")) : (market.isSpot ? L("Sell") : L("Short")))
                .font(.system(size: 14, weight: .bold))
                .frame(maxWidth: .infinity).frame(height: 32)
                .foregroundStyle(f.isBuy == buy ? Color.hlOnAccent : Color.hlMuted)
                .background(f.isBuy == buy ? (buy ? Color.hlGreen : Color.hlRed) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var typeMenu: some View {
        Menu {
            ForEach(availableTypes) { t in
                Button { f.type = t } label: { if t == f.type { Label(t.title, systemImage: "checkmark") } else { Text(t.title) } }
            }
        } label: {
            HStack {
                Text(f.type.title).font(.system(size: 14, weight: .semibold))
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.hlMuted)
            }
            .padding(.horizontal, 10).frame(height: 34)
            .background(Color.hlCard2, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var availableTypes: [OrderTypeUI] {
        market.isSpot ? [.market, .limit, .chase, .scale, .twap] : OrderTypeUI.allCases
    }

    private func midButton(_ set: @escaping (String) -> Void) -> some View {
        Button("Mid") {
            let p = refMid
            set(Fmt.input(p, market.priceDecimals(p)))
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Color.hlAccent)
    }

    private var sizeField: some View {
        NumField(title: f.riskOn ? L("Size (risk)") : L("Size"), text: $f.sizeText) {
            Button(f.sizeInUsd ? "USD" : market.base) {
                // Convert value to the new unit.
                if let v = Fmt.parse(f.sizeText), refPrice > 0 {
                    f.sizeText = f.sizeInUsd ? Fmt.input(v / refPrice, market.szDecimals) : Fmt.input(v * refPrice, 2)
                }
                f.sizeInUsd.toggle()
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.hlAccent)
            .lineLimit(1)
        }
        .disabled(f.riskOn)
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if !market.isSpot { Toggle("Reduce", isOn: $f.reduceOnly).toggleStyle(CheckToggle()) }
                Spacer()
                if f.type == .limit {
                    // Same size as the checkboxes in this row (a menu picker uses the large body font).
                    Menu {
                        Picker("TIF", selection: $f.tif) {
                            Text("GTC").tag(TIF.gtc)
                            Text("IOC").tag(TIF.ioc)
                            Text("Post").tag(TIF.alo)
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(f.tif == .gtc ? "GTC" : f.tif == .ioc ? "IOC" : "Post").font(.system(size: 12, weight: .semibold))
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(Color.hlAccent)
                        .padding(.horizontal, 8).frame(height: 24)
                        .background(Color.hlAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            if !market.isSpot && f.type.allowsTpsl {
                HStack {
                    Toggle("TP/SL", isOn: $f.tpslOn).toggleStyle(CheckToggle())
                    Spacer()
                    Toggle(L("Risk sizing"), isOn: $f.riskOn).toggleStyle(CheckToggle())
                }
            }
        }
        .font(.system(size: 12))
    }

    /// Size as a share of what's available: slider with its percentage and quick 25 / 50 / 75 / 100 % steps.
    private var sizeSlider: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Slider(value: $f.pct, in: 0...1)
                    .tint(f.isBuy ? .hlGreen : .hlRed)
                Text("\(Int((f.pct * 100).rounded()))%")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(f.pct > 0 ? Color.primary : Color.hlMuted)
                    .frame(width: 36, alignment: .trailing)
            }
            HStack(spacing: 4) {
                ForEach([0.25, 0.5, 0.75, 1.0], id: \.self) { p in
                    let on = abs(f.pct - p) < 0.005
                    Button("\(Int(p * 100))%") { f.pct = p }
                        .font(.system(size: 10, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                        .foregroundStyle(on ? Color.primary : Color.hlMuted)
                        .background(on ? (f.isBuy ? Color.hlGreen : Color.hlRed).opacity(0.25) : Color.hlCard2,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .buttonStyle(.plain)
                }
            }
        }
        .onChange(of: f.pct) { _, v in applyPct(v) }
    }

    private var trailingFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            NumField(title: L("Retracement"), text: $f.trailText, placeholder: f.trailIsPct ? "1" : Fmt.price(refMid * 0.01)) {
                Button(f.trailIsPct ? "%" : market.quote) { f.trailIsPct.toggle() }
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.hlAccent)
            }
            if f.trailIsPct {
                HStack(spacing: 4) {
                    ForEach([0.5, 1.0, 2.0, 5.0], id: \.self) { p in
                        Button(Fmt.num(p, p < 1 ? 1 : 0) + "%") { f.trailText = Fmt.input(p, 1) }
                            .font(.system(size: 10, weight: .semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 5)
                            .background(Color.hlCard2, in: RoundedRectangle(cornerRadius: 6))
                            .buttonStyle(.plain)
                    }
                }
            }
            Toggle(L("Activation price"), isOn: $f.trailActivationOn).toggleStyle(CheckToggle()).font(.caption)
            if f.trailActivationOn {
                NumField(title: L("Activation"), text: $f.trailActivationText, placeholder: Fmt.price(refMid)) { midButton { f.trailActivationText = $0 } }
            }
            Text(trailingExplainer).font(.system(size: 10)).foregroundStyle(Color.hlMuted)
        }
    }

    private var trailingExplainer: String {
        let r = f.trailText.isEmpty ? "—" : (f.trailIsPct ? f.trailText + "%" : f.trailText + " " + market.quote)
        if f.trailActivationOn, !f.trailActivationText.isEmpty {
            return L("When the mark price reaches {0}, the trailing stop activates; once the price retraces by {1} from the best price since activation, a stop market order is placed.", f.trailActivationText, r)
        }
        return L("When the mark price retraces by {0} from the best price since activation, a stop market order is placed.", r)
    }

    private var tpslFields: some View {
        VStack(spacing: 6) {
            NumField(title: "TP", text: $f.tpText, placeholder: L("price")) {
                Text(roeText(f.tpText)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.hlGreen)
            }
            NumField(title: "SL", text: $f.slText, placeholder: L("price")) {
                Text(roeText(f.slText)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.hlRed)
            }
            HStack(spacing: 4) {
                ForEach([0.01, 0.02, 0.05], id: \.self) { p in
                    Button("±\(Int(p * 100))%") {
                        let e = refPrice
                        f.tpText = Fmt.input(e * (f.isBuy ? 1 + 2 * p : 1 - 2 * p), market.priceDecimals(e))
                        f.slText = Fmt.input(e * (f.isBuy ? 1 - p : 1 + p), market.priceDecimals(e))
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 5)
                    .background(Color.hlCard2, in: RoundedRectangle(cornerRadius: 6))
                    .buttonStyle(.plain)
                }
            }
            if let atr = currentATR, atr > 0 {
                // Volatility stops: SL at k × ATR(14) of the chart's interval, TP at twice the distance.
                HStack(spacing: 4) {
                    ForEach([1.0, 1.5, 2.0], id: \.self) { k in
                        Button("\(Fmt.num(k, k == 1.5 ? 1 : 0))×ATR") {
                            let e = refPrice
                            f.slText = Fmt.input(f.isBuy ? e - k * atr : e + k * atr, market.priceDecimals(e))
                            f.tpText = Fmt.input(f.isBuy ? e + 2 * k * atr : e - 2 * k * atr, market.priceDecimals(e))
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                        .background(Color.hlCard2, in: RoundedRectangle(cornerRadius: 6))
                        .buttonStyle(.plain)
                    }
                }
            }
            Text(L("Buttons: SL at ±% or k × ATR (chart interval), TP at double the distance (R:R 1:2)")).font(.system(size: 9)).foregroundStyle(Color.hlMuted)
            if f.riskOn {
                NumField(title: L("Risk $"), text: $f.riskText, placeholder: "50") {
                    Menu {
                        ForEach([0.005, 0.01, 0.02, 0.05], id: \.self) { p in
                            Button(L("{0}% of balance", Fmt.num(p * 100, 1))) {
                                f.riskText = Fmt.input(model.tradingEquity * p, 2)
                            }
                        }
                    } label: { Image(systemName: "percent").font(.caption) }
                }
                Text(L("Size is calculated so that the loss at SL equals the risk."))
                    .font(.system(size: 9)).foregroundStyle(Color.hlMuted)
            }
        }
        .onChange(of: f.riskText) { _, _ in applyRisk() }
        .onChange(of: f.slText) { _, _ in applyRisk() }
        .onChange(of: f.priceText) { _, _ in applyRisk() }
    }

    private var summary: some View {
        VStack(spacing: 3) {
            ForEach(summaryLines(nil)) { l in
                HStack {
                    Text(l.label).foregroundStyle(Color.hlMuted)
                    Spacer()
                    Text(l.value).font(.system(size: 11, design: .monospaced)).foregroundStyle(l.color)
                }
                .font(.system(size: 11))
            }
        }
    }

    // MARK: Computations

    private var refMid: Double { model.mid(market.id) }

    private var refPrice: Double {
        switch f.type {
        case .limit, .stopLimit, .takeLimit: return Fmt.parse(f.priceText) ?? refMid
        case .stopMarket, .takeMarket: return Fmt.parse(f.triggerText) ?? refMid
        case .scale:
            let a = Fmt.parse(f.scaleStartText) ?? refMid, b = Fmt.parse(f.scaleEndText) ?? a
            return (a + b) / 2
        default: return refMid
        }
    }

    /// Limit (GTC / IOC) priced at or through the best opposite price: executes immediately as a taker.
    private func limitCrosses(_ d: OrderDraft) -> Bool {
        guard d.type == .limit, d.tif != .alo, let p = d.price, p > 0, market.id == model.selectedCoin else { return false }
        let bid = model.bbo?.bid ?? model.book.bestBid, ask = model.bbo?.ask ?? model.book.bestAsk
        if d.isBuy, let ask { return p >= ask }
        if !d.isBuy, let bid { return p <= bid }
        return false
    }

    /// ATR(14) of the chart's candles for this market (volatility stop distance).
    private var currentATR: Double? {
        guard market.id == model.selectedCoin else { return nil }
        return TA.atr(model.candles, 14).last ?? nil
    }

    private var currentLeverage: Int {
        model.position(market.id)?.leverage ?? max(1, model.activeAsset.leverage)
    }

    /// Max size in coin units for the current side.
    private var maxSize: Double {
        if market.isSpot {
            if f.isBuy {
                let usdc = model.spotBalances.first { $0.coin == market.quote }?.available ?? 0
                return refPrice > 0 ? usdc / refPrice : 0
            }
            return model.spotBalances.first { $0.coin == market.base }?.available ?? 0
        }
        if f.reduceOnly, let p = model.position(market.id), p.isLong != f.isBuy { return p.size }
        let fromWs = f.isBuy ? model.activeAsset.maxBuy : model.activeAsset.maxSell
        if fromWs > 0 && f.type == .market { return fromWs }
        let avail = (f.isBuy ? model.activeAsset.availableBuy : model.activeAsset.availableSell)
        let margin = avail > 0 ? avail : model.withdrawable(for: market)
        return refPrice > 0 ? margin * Double(currentLeverage) / refPrice * 0.995 : 0
    }

    private var sizeCoin: Double {
        guard let v = Fmt.parse(f.sizeText), v > 0 else { return 0 }
        if f.sizeInUsd { return refPrice > 0 ? v / refPrice : 0 }
        return v
    }

    private var availableText: String {
        if market.isSpot {
            if f.isBuy {
                return Fmt.num(model.spotBalances.first { $0.coin == market.quote }?.available ?? 0, 2) + " " + market.quote
            }
            return Fmt.num(maxSize, market.szDecimals) + " " + market.base
        }
        let avail = f.isBuy ? model.activeAsset.availableBuy : model.activeAsset.availableSell
        return Fmt.usd(avail > 0 ? avail : model.withdrawable(for: market))
    }

    private var twapLabel: String {
        f.twapMinutes < 60 ? L("{0} min", f.twapMinutes) : L("{0}h {1}", f.twapMinutes / 60, f.twapMinutes % 60 > 0 ? L("{0}m", f.twapMinutes % 60) : "")
    }

    private func roeText(_ s: String) -> String {
        guard let px = Fmt.parse(s), refPrice > 0 else { return "" }
        let move = (px / refPrice - 1) * (f.isBuy ? 1 : -1)
        return Fmt.pct(move * Double(currentLeverage), 1)
    }

    private func applyPct(_ v: Double) {
        guard !f.riskOn else { return }
        let sz = maxSize * v
        guard sz > 0 else { if v == 0 { f.sizeText = "" }; return }
        f.sizeText = f.sizeInUsd ? Fmt.input(sz * refPrice, 2) : Fmt.input(NSDecimalNumber(decimal: market.roundSize(sz)).doubleValue, market.szDecimals)
    }

    private func applyRisk() {
        guard f.riskOn, let risk = Fmt.parse(f.riskText), let sl = Fmt.parse(f.slText) else { return }
        let dist = abs(refPrice - sl)
        guard dist > 0 else { return }
        let sz = risk / dist
        f.sizeText = f.sizeInUsd ? Fmt.input(sz * refPrice, 2) : Fmt.input(sz, market.szDecimals)
    }

    /// Puts a price tapped in the order book into the right field.
    private func applyPendingPrice() {
        guard let p = model.pendingPrice else { return }
        let s = Fmt.input(p, market.priceDecimals(p))
        if f.type == .scale { f.scaleStartText = s }
        else if f.type.needsTrigger && !f.type.needsPrice { f.triggerText = s }
        else if f.type == .trailing { f.trailActivationOn = true; f.trailActivationText = s }
        else {
            if f.type == .market || f.type == .twap || f.type == .chase { f.type = .limit }
            f.priceText = s
        }
        model.pendingPrice = nil
    }

    /// Publishes the primary action to the pinned bottom bar.
    private func syncBar() {
        bar.title = buttonTitle
        bar.isBuy = f.isBuy
        bar.busy = busy
        bar.enabled = model.canTrade
        let value = sizeCoin * refPrice
        // Value and the rest are in the summary right above; the button needs no repeat of it.
        bar.detail = ""
        bar.submit = { submit() }
    }

    private var buttonTitle: String {
        let side = market.isSpot ? (f.isBuy ? L("Buy") : L("Sell")) : (f.isBuy ? L("Long") : L("Short"))
        return "\(side) \(market.base)"
    }

    private func draft() -> OrderDraft {
        var d = OrderDraft(market: market, isBuy: f.isBuy, type: f.type, size: sizeCoin)
        d.price = Fmt.parse(f.priceText)
        d.triggerPx = Fmt.parse(f.triggerText)
        d.tif = f.tif
        d.reduceOnly = f.reduceOnly
        if f.tpslOn && f.type.allowsTpsl && !market.isSpot {
            d.tp = Fmt.parse(f.tpText)
            d.sl = Fmt.parse(f.slText)
        }
        d.scaleStart = Fmt.parse(f.scaleStartText)
        d.scaleEnd = Fmt.parse(f.scaleEndText)
        d.scaleCount = f.scaleCount
        d.scaleSkew = f.scaleSkew
        d.twapMinutes = f.twapMinutes
        d.twapRandomize = f.twapRandomize
        d.trailValue = Fmt.parse(f.trailText)
        d.trailIsPct = f.trailIsPct
        d.trailActivation = f.trailActivationOn ? Fmt.parse(f.trailActivationText) : nil
        d.chaseMaxDistance = (Fmt.parse(f.chaseDistText) ?? 0) / 100
        if f.type == .scale { d.size = f.sizeInUsd ? (Fmt.parse(f.sizeText) ?? 0) / max(refPrice, 1e-12) : sizeCoin }
        return d
    }

    func summaryLines(_ given: OrderDraft?) -> [SummaryLine] {
        let d = given ?? draft()
        let px = refPrice
        let value = d.size * px
        var lines: [SummaryLine] = []
        if given != nil {
            lines.append(SummaryLine(L("Market"), market.name, .primary))
            lines.append(SummaryLine(L("Side"), d.isBuy ? (market.isSpot ? L("Purchase") : L("Long")) : (market.isSpot ? L("Sale") : L("Short")), d.isBuy ? .hlGreen : .hlRed))
            lines.append(SummaryLine(L("Type"), d.type.title, .primary))
            lines.append(SummaryLine(L("Size"), "\(Fmt.num(d.size, market.szDecimals)) \(market.base)", .primary))
            if let p = d.price, d.type.needsPrice { lines.append(SummaryLine(L("Price"), Fmt.price(p), .primary)) }
            if let t = d.triggerPx, d.type.needsTrigger { lines.append(SummaryLine(L("Trigger"), Fmt.price(t), .primary)) }
            if d.type == .market { lines.append(SummaryLine(L("Max slippage"), Fmt.pct(model.slippage, 1, signed: false), .primary)) }
            if d.type == .scale { lines.append(SummaryLine(L("Grid"), L("{0} orders {1} → {2}", d.scaleCount, Fmt.price(d.scaleStart ?? 0), Fmt.price(d.scaleEnd ?? 0)), .primary)) }
            if d.type == .twap { lines.append(SummaryLine("TWAP", twapLabel, .primary)) }
            if let tp = d.tp { lines.append(SummaryLine(L("Take profit"), Fmt.price(tp), .hlGreen)) }
            if let sl = d.sl { lines.append(SummaryLine(L("Stop loss"), Fmt.price(sl), .hlRed)) }
            if d.reduceOnly { lines.append(SummaryLine("Reduce only", L("yes"), .primary)) }
        }
        lines.append(SummaryLine(L("Value"), value > 0 ? Fmt.usd(value) : "—", .primary))
        if !market.isSpot {
            lines.append(SummaryLine(L("Margin"), value > 0 ? Fmt.usd(value / Double(currentLeverage)) : "—", .primary))
            if value > 0, !d.reduceOnly,
               let liq = model.estimateLiq(m: market, isBuy: d.isBuy, price: px, size: d.size, leverage: currentLeverage,
                                           isCross: model.activeAsset.isCross && model.crossAllowed(market)) {
                lines.append(SummaryLine(L("Liquidation ≈"), Fmt.price(liq), .orange))
            }
        }
        let rates = model.fees(for: market)
        // A limit order priced through the opposite side fills at once as a taker (not post-only).
        let crosses = limitCrosses(d)
        let fee = d.type.isTaker || crosses ? rates.taker : rates.maker
        lines.append(SummaryLine(crosses ? L("Fee ≈ (taker, crosses the spread)") : L("Fee ≈"),
                                 value > 0 ? Fmt.usd(value * fee) : "—", crosses ? .orange : .primary))
        // Expected fill of a market order from the live book (and √-impact beyond its visible depth).
        var slip = 0.0
        if d.type == .market || crosses, d.size > 0, market.id == model.selectedCoin,
           let est = QuantMath.estimateFill(book: model.book, isBuy: d.isBuy, size: d.size,
                                            limit: crosses ? d.price : nil) {
            slip = est.slippage
            lines.append(SummaryLine(L("Est. fill ≈"), Fmt.price(est.avgPrice), .primary))
            lines.append(SummaryLine(L("Est. slippage"), "\(Fmt.pct(est.slippage, 3, signed: false)) · \(Fmt.usd(est.slippage * est.avgPrice * est.filled, 2)) · \(L("{0} lvl", est.levels))",
                                     est.slippage > 0.005 ? .orange : .primary))
            if est.exhausted && d.type == .market {
                let impact = QuantMath.sqrtImpact(notional: value, dailyVolume: market.dayNtlVlm,
                                                  dailyVol: QuantMath.dailyVol(model.candles, interval: model.interval) ?? 0)
                lines.append(SummaryLine(L("Beyond visible book"), impact.map { L("impact ≈ {0}", Fmt.pct($0, 2, signed: false)) } ?? "—", .orange))
                if let impact { slip = max(slip, impact) }
            }
        }
        // Round trip: this entry + a taker exit; the move needed to cover it (plus slippage).
        if value > 0, !d.reduceOnly {
            let rt = value * (fee + rates.taker)
            lines.append(SummaryLine(L("Round-trip fees ≈"), Fmt.usd(rt), .primary))
            lines.append(SummaryLine(L("Break-even move"), Fmt.pct(fee + rates.taker + slip, 3, signed: false), .primary))
        }
        if let sl = d.sl, sl > 0, d.size > 0 {
            lines.append(SummaryLine(L("Loss at SL"), Fmt.signedUsd(-abs(px - sl) * d.size), .hlRed))
        }
        if let tp = d.tp, tp > 0, d.size > 0 {
            lines.append(SummaryLine(L("Profit at TP"), Fmt.signedUsd(abs(tp - px) * d.size), .hlGreen))
        }
        return lines
    }

    // MARK: Actions

    private func submit() {
        hideKeyboard()
        let d = draft()
        do {
            try model.validate(d)
        } catch {
            model.show(.error, error.localizedDescription)
            Haptics.error(enabled: model.haptics)
            return
        }
        if model.confirmOrders { confirm = IdentifiedDraft(draft: d) } else { send(d) }
    }

    private func send(_ d: OrderDraft) {
        confirm = nil
        busy = true
        Task {
            do {
                let msg = try await model.place(d)
                model.show(.success, msg)
                Haptics.success(enabled: model.haptics)
                f.sizeText = ""; f.pct = 0
                if f.riskOn { f.riskText = "" }
                onPlaced?()
            } catch {
                model.show(.error, error.localizedDescription)
                Haptics.error(enabled: model.haptics)
            }
            busy = false
        }
    }

    private func reset() {
        f.marketId = market.id
        f.priceText = ""; f.triggerText = ""; f.sizeText = ""; f.tpText = ""; f.slText = ""; f.pct = 0
        f.scaleStartText = ""; f.scaleEndText = ""
        if market.isSpot && !availableTypes.contains(f.type) { f.type = .market }
        if market.isSpot { f.reduceOnly = false; f.tpslOn = false; f.riskOn = false }
    }
}

/// Order form fields, kept while the app runs (cleared when the market changes).
@Observable
final class OrderFormFields {
    static let shared = OrderFormFields()
    var marketId = ""
    var isBuy = true
    var type: OrderTypeUI = .market
    var priceText = ""
    var triggerText = ""
    var sizeText = ""
    var sizeInUsd = true
    var pct: Double = 0
    var reduceOnly = false
    var tif: TIF = .gtc
    var tpslOn = false
    var tpText = ""
    var slText = ""
    var riskOn = false
    var riskText = ""
    var scaleStartText = ""
    var scaleEndText = ""
    var scaleCount = 5
    var scaleSkew = 1.0
    var twapMinutes = 30
    var twapRandomize = true
    var trailText = ""
    var trailIsPct = true
    var trailActivationOn = false
    var trailActivationText = ""
    var chaseDistText = ""
}

struct IdentifiedDraft: Identifiable {
    let id = UUID()
    let draft: OrderDraft
}

struct SummaryLine: Identifiable {
    let label: String
    let value: String
    let color: Color
    var id: String { label }
    init(_ label: String, _ value: String, _ color: Color) { self.label = label; self.value = value; self.color = color }
}

struct CheckToggle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(configuration.isOn ? Color.hlAccent : Color.hlMuted)
                configuration.label
            }
        }
        .buttonStyle(.plain)
    }
}

struct OrderConfirmSheet: View {
    @Environment(\.dismiss) private var dismiss
    let draft: OrderDraft
    let summary: [SummaryLine]
    let onConfirm: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text(L("Order confirmation")).font(.headline).padding(.top, 16)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(summary) { l in
                        HStack {
                            Text(l.label).foregroundStyle(Color.hlMuted)
                            Spacer()
                            Text(l.value).font(.system(.subheadline, design: .monospaced)).foregroundStyle(l.color)
                        }
                        .font(.subheadline)
                    }
                }
            }
            HStack(spacing: 10) {
                Button(L("Cancel")) { dismiss() }
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(Color.hlCard2, in: RoundedRectangle(cornerRadius: 10))
                PrimaryButton(title: L("Confirm"), color: draft.isBuy ? .hlGreen : .hlRed) { onConfirm() }
            }
        }
        .padding(.horizontal)
        .padding(.bottom)
        .background(Color.hlBg)
    }
}

struct LeverageSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let market: Market
    @State private var leverage: Double = 1
    @State private var isCross = true
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(L("Margin mode"), selection: $isCross) {
                        Text("Cross").tag(true)
                        Text("Isolated").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .disabled(!model.crossAllowed(market))
                } footer: {
                    if market.isHip3 && !market.onlyIsolated && !model.crossAllowed(market) {
                        Text(L("Cross margin on HIP-3 is not supported for a standard account. Use isolated margin or switch to a unified account (Portfolio → account type)."))
                    } else {
                        Text(isCross ? L("Cross: all free account margin backs the position.") : L("Isolated: risk is limited to the margin allocated to this position."))
                    }
                }
                Section(L("Leverage: {0}x", Int(leverage))) {
                    Slider(value: $leverage, in: 1...Double(max(market.maxLeverage, 1)), step: 1)
                    HStack {
                        ForEach(presets, id: \.self) { p in
                            Button("\(p)x") { leverage = Double(p) }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
                Section {
                    PrimaryButton(title: L("Apply"), busy: busy) {
                        busy = true
                        Task {
                            do {
                                try await model.updateLeverage(market, leverage: Int(leverage), isCross: isCross)
                                model.show(.success, L("Leverage {0}x {1}", Int(leverage), isCross ? "Cross" : "Isolated"))
                                dismiss()
                            } catch {
                                model.show(.error, error.localizedDescription)
                            }
                            busy = false
                        }
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle(L("Leverage {0}", market.name))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Close")) { dismiss() } } }
            .onAppear {
                leverage = Double(model.position(market.id)?.leverage ?? max(1, model.activeAsset.leverage))
                isCross = model.crossAllowed(market) ? model.activeAsset.isCross : false
            }
        }
        .presentationDetents([.medium])
    }

    private var presets: [Int] {
        [1, 2, 3, 5, 10, 20, 25, 40, 50].filter { $0 <= market.maxLeverage }.suffix(6).map { $0 }
    }
}
