import SwiftUI
import HyperCore

struct OrderFormView: View {
    @Environment(AppModel.self) private var model
    let market: Market

    @State private var isBuy = true
    @State private var type: OrderTypeUI = .market
    @State private var priceText = ""
    @State private var triggerText = ""
    @State private var sizeText = ""
    @State private var sizeInUsd = true
    @State private var pct: Double = 0
    @State private var reduceOnly = false
    @State private var tif: TIF = .gtc
    @State private var tpslOn = false
    @State private var tpText = ""
    @State private var slText = ""
    @State private var riskOn = false
    @State private var riskText = ""
    @State private var scaleStartText = ""
    @State private var scaleEndText = ""
    @State private var scaleCount = 5
    @State private var scaleSkew = 1.0
    @State private var twapMinutes = 30
    @State private var twapRandomize = true
    @State private var busy = false
    @State private var confirm: IdentifiedDraft?
    @State private var showLeverage = false

    var body: some View {
        VStack(spacing: 8) {
            if !market.isSpot { leverageRow }
            sideToggle
            typeMenu

            if type.needsTrigger {
                NumField(title: "Триггер", text: $triggerText, placeholder: Fmt.price(refMid)) { midButton { triggerText = $0 } }
            }
            if type.needsPrice {
                NumField(title: "Цена", text: $priceText, placeholder: Fmt.price(refMid)) { midButton { priceText = $0 } }
            }
            if type == .scale {
                NumField(title: "От", text: $scaleStartText, placeholder: Fmt.price(refMid)) { midButton { scaleStartText = $0 } }
                NumField(title: "До", text: $scaleEndText, placeholder: Fmt.price(refMid))
                Stepper("Ордеров: \(scaleCount)", value: $scaleCount, in: 2...50).font(.caption)
                HStack {
                    Text("Скос \(Fmt.num(scaleSkew, 1))").font(.caption).frame(width: 64, alignment: .leading)
                    Slider(value: $scaleSkew, in: 0.2...5, step: 0.1)
                }
            }
            if type == .twap {
                Stepper("Длительность: \(twapLabel)", value: $twapMinutes, in: 5...1440, step: twapMinutes < 60 ? 5 : 30).font(.caption)
                Toggle("Случайные интервалы", isOn: $twapRandomize).font(.caption)
            }

            sizeField
            Slider(value: $pct, in: 0...1)
            .tint(isBuy ? .hlGreen : .hlRed)
            .onChange(of: pct) { _, v in applyPct(v) }

            HStack {
                Text("Доступно").font(.caption2).foregroundStyle(Color.hlMuted)
                Spacer()
                Text(availableText).font(.system(size: 11, design: .monospaced))
            }

            options
            if tpslOn && !market.isSpot && !type.isTrigger && type != .scale && type != .twap { tpslFields }
            summary

            PrimaryButton(title: buttonTitle, color: isBuy ? .hlGreen : .hlRed, busy: busy, disabled: !model.canTrade) {
                submit()
            }
            if !model.canTrade {
                Text(model.account == nil ? "Добавьте аккаунт в Настройках" : "Аккаунт только для просмотра")
                    .font(.caption2).foregroundStyle(Color.hlMuted)
            }
        }
        .font(.subheadline)
        .onChange(of: model.pendingPrice) { _, p in
            guard let p else { return }
            let s = Fmt.input(p, market.priceDecimals(p))
            if type == .scale { scaleStartText = s }
            else if type.needsTrigger && !type.needsPrice { triggerText = s }
            else {
                if type == .market || type == .twap { type = .limit }
                priceText = s
            }
            model.pendingPrice = nil
        }
        .onChange(of: market.id) { _, _ in reset() }
        .onChange(of: riskOn) { _, on in if on { tpslOn = true } }
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
                Text(model.activeAsset.isCross && !market.onlyIsolated ? "Cross" : "Isolated")
                Spacer()
                Text("\(currentLeverage)x").bold()
                Image(systemName: "slider.horizontal.3").font(.caption)
            }
            .font(.caption)
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
        Button { withAnimation(.easeOut(duration: 0.15)) { isBuy = buy } } label: {
            Text(buy ? (market.isSpot ? "Купить" : "Лонг") : (market.isSpot ? "Продать" : "Шорт"))
                .font(.system(size: 14, weight: .bold))
                .frame(maxWidth: .infinity).frame(height: 34)
                .foregroundStyle(isBuy == buy ? .black : Color.hlMuted)
                .background(isBuy == buy ? (buy ? Color.hlGreen : Color.hlRed) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var typeMenu: some View {
        Menu {
            ForEach(availableTypes) { t in
                Button { type = t } label: { if t == type { Label(t.title, systemImage: "checkmark") } else { Text(t.title) } }
            }
        } label: {
            HStack {
                Text(type.title).font(.subheadline.weight(.semibold))
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.caption)
            }
            .padding(.horizontal, 10).frame(height: 34)
            .background(Color.hlCard2, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private var availableTypes: [OrderTypeUI] {
        market.isSpot ? [.market, .limit, .scale, .twap] : OrderTypeUI.allCases
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
        NumField(title: riskOn ? "Размер (риск)" : "Размер", text: $sizeText) {
            Button(sizeInUsd ? "USD" : market.base) {
                // Convert value to the new unit.
                if let v = Fmt.parse(sizeText), refPrice > 0 {
                    sizeText = sizeInUsd ? Fmt.input(v / refPrice, market.szDecimals) : Fmt.input(v * refPrice, 2)
                }
                sizeInUsd.toggle()
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.hlAccent)
            .lineLimit(1)
        }
        .disabled(riskOn)
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if !market.isSpot { Toggle("Reduce", isOn: $reduceOnly).toggleStyle(CheckToggle()) }
                Spacer()
                if type == .limit {
                    Picker("TIF", selection: $tif) {
                        Text("GTC").tag(TIF.gtc)
                        Text("IOC").tag(TIF.ioc)
                        Text("Post").tag(TIF.alo)
                    }
                    .pickerStyle(.menu)
                    .controlSize(.small)
                }
            }
            if !market.isSpot && !type.isTrigger && type != .scale && type != .twap {
                HStack {
                    Toggle("TP/SL", isOn: $tpslOn).toggleStyle(CheckToggle())
                    Spacer()
                    Toggle("Риск-сайзинг", isOn: $riskOn).toggleStyle(CheckToggle())
                }
            }
        }
        .font(.caption)
    }

    private var tpslFields: some View {
        VStack(spacing: 6) {
            NumField(title: "TP", text: $tpText, placeholder: "цена") {
                Text(roeText(tpText)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.hlGreen)
            }
            NumField(title: "SL", text: $slText, placeholder: "цена") {
                Text(roeText(slText)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.hlRed)
            }
            HStack(spacing: 4) {
                ForEach([0.01, 0.02, 0.05], id: \.self) { p in
                    Button("±\(Int(p * 100))%") {
                        let e = refPrice
                        tpText = Fmt.input(e * (isBuy ? 1 + 2 * p : 1 - 2 * p), market.priceDecimals(e))
                        slText = Fmt.input(e * (isBuy ? 1 - p : 1 + p), market.priceDecimals(e))
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 5)
                    .background(Color.hlCard2, in: RoundedRectangle(cornerRadius: 6))
                    .buttonStyle(.plain)
                }
            }
            Text("Кнопки: SL на ±%, TP на двойное расстояние (R:R 1:2)").font(.system(size: 9)).foregroundStyle(Color.hlMuted)
            if riskOn {
                NumField(title: "Риск $", text: $riskText, placeholder: "50") {
                    Menu {
                        ForEach([0.005, 0.01, 0.02, 0.05], id: \.self) { p in
                            Button("\(Fmt.num(p * 100, 1))% депозита") {
                                riskText = Fmt.input(model.summary.accountValue * p, 2)
                            }
                        }
                    } label: { Image(systemName: "percent").font(.caption) }
                }
                Text("Размер считается так, чтобы при срабатывании SL убыток был равен риску.")
                    .font(.system(size: 9)).foregroundStyle(Color.hlMuted)
            }
        }
        .onChange(of: riskText) { _, _ in applyRisk() }
        .onChange(of: slText) { _, _ in applyRisk() }
        .onChange(of: priceText) { _, _ in applyRisk() }
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
        switch type {
        case .limit, .stopLimit, .takeLimit: return Fmt.parse(priceText) ?? refMid
        case .stopMarket, .takeMarket: return Fmt.parse(triggerText) ?? refMid
        case .scale:
            let a = Fmt.parse(scaleStartText) ?? refMid, b = Fmt.parse(scaleEndText) ?? a
            return (a + b) / 2
        default: return refMid
        }
    }

    private var currentLeverage: Int {
        model.position(market.id)?.leverage ?? max(1, model.activeAsset.leverage)
    }

    /// Max size in coin units for the current side.
    private var maxSize: Double {
        if market.isSpot {
            if isBuy {
                let usdc = model.spotBalances.first { $0.coin == market.quote }?.available ?? 0
                return refPrice > 0 ? usdc / refPrice : 0
            }
            return model.spotBalances.first { $0.coin == market.base }?.available ?? 0
        }
        if reduceOnly, let p = model.position(market.id), p.isLong != isBuy { return p.size }
        let fromWs = isBuy ? model.activeAsset.maxBuy : model.activeAsset.maxSell
        if fromWs > 0 && type == .market { return fromWs }
        let avail = (isBuy ? model.activeAsset.availableBuy : model.activeAsset.availableSell)
        let margin = avail > 0 ? avail : model.summary.withdrawable
        return refPrice > 0 ? margin * Double(currentLeverage) / refPrice * 0.995 : 0
    }

    private var sizeCoin: Double {
        guard let v = Fmt.parse(sizeText), v > 0 else { return 0 }
        if sizeInUsd { return refPrice > 0 ? v / refPrice : 0 }
        return v
    }

    private var availableText: String {
        if market.isSpot {
            if isBuy {
                return Fmt.num(model.spotBalances.first { $0.coin == market.quote }?.available ?? 0, 2) + " " + market.quote
            }
            return Fmt.num(maxSize, market.szDecimals) + " " + market.base
        }
        let avail = isBuy ? model.activeAsset.availableBuy : model.activeAsset.availableSell
        return Fmt.usd(avail > 0 ? avail : model.summary.withdrawable)
    }

    private var twapLabel: String {
        twapMinutes < 60 ? "\(twapMinutes) мин" : "\(twapMinutes / 60)ч \(twapMinutes % 60 > 0 ? "\(twapMinutes % 60)м" : "")"
    }

    private func roeText(_ s: String) -> String {
        guard let px = Fmt.parse(s), refPrice > 0 else { return "" }
        let move = (px / refPrice - 1) * (isBuy ? 1 : -1)
        return Fmt.pct(move * Double(currentLeverage), 1)
    }

    private func applyPct(_ v: Double) {
        guard !riskOn else { return }
        let sz = maxSize * v
        guard sz > 0 else { if v == 0 { sizeText = "" }; return }
        sizeText = sizeInUsd ? Fmt.input(sz * refPrice, 2) : Fmt.input(NSDecimalNumber(decimal: market.roundSize(sz)).doubleValue, market.szDecimals)
    }

    private func applyRisk() {
        guard riskOn, let risk = Fmt.parse(riskText), let sl = Fmt.parse(slText) else { return }
        let dist = abs(refPrice - sl)
        guard dist > 0 else { return }
        let sz = risk / dist
        sizeText = sizeInUsd ? Fmt.input(sz * refPrice, 2) : Fmt.input(sz, market.szDecimals)
    }

    private var buttonTitle: String {
        let side = market.isSpot ? (isBuy ? "Купить" : "Продать") : (isBuy ? "Лонг" : "Шорт")
        return "\(side) \(market.base)"
    }

    private func draft() -> OrderDraft {
        var d = OrderDraft(market: market, isBuy: isBuy, type: type, size: sizeCoin)
        d.price = Fmt.parse(priceText)
        d.triggerPx = Fmt.parse(triggerText)
        d.tif = tif
        d.reduceOnly = reduceOnly
        if tpslOn && !type.isTrigger && !market.isSpot {
            d.tp = Fmt.parse(tpText)
            d.sl = Fmt.parse(slText)
        }
        d.scaleStart = Fmt.parse(scaleStartText)
        d.scaleEnd = Fmt.parse(scaleEndText)
        d.scaleCount = scaleCount
        d.scaleSkew = scaleSkew
        d.twapMinutes = twapMinutes
        d.twapRandomize = twapRandomize
        if type == .scale { d.size = sizeInUsd ? (Fmt.parse(sizeText) ?? 0) / max(refPrice, 1e-12) : sizeCoin }
        return d
    }

    func summaryLines(_ given: OrderDraft?) -> [SummaryLine] {
        let d = given ?? draft()
        let px = refPrice
        let value = d.size * px
        var lines: [SummaryLine] = []
        if given != nil {
            lines.append(SummaryLine("Рынок", market.name, .primary))
            lines.append(SummaryLine("Сторона", d.isBuy ? (market.isSpot ? "Покупка" : "Лонг") : (market.isSpot ? "Продажа" : "Шорт"), d.isBuy ? .hlGreen : .hlRed))
            lines.append(SummaryLine("Тип", d.type.title, .primary))
            lines.append(SummaryLine("Размер", "\(Fmt.num(d.size, market.szDecimals)) \(market.base)", .primary))
            if let p = d.price, d.type.needsPrice { lines.append(SummaryLine("Цена", Fmt.price(p), .primary)) }
            if let t = d.triggerPx, d.type.needsTrigger { lines.append(SummaryLine("Триггер", Fmt.price(t), .primary)) }
            if d.type == .market { lines.append(SummaryLine("Макс. проскальзывание", Fmt.pct(model.slippage, 1, signed: false), .primary)) }
            if d.type == .scale { lines.append(SummaryLine("Сетка", "\(d.scaleCount) ордеров \(Fmt.price(d.scaleStart ?? 0)) → \(Fmt.price(d.scaleEnd ?? 0))", .primary)) }
            if d.type == .twap { lines.append(SummaryLine("TWAP", twapLabel, .primary)) }
            if let tp = d.tp { lines.append(SummaryLine("Тейк-профит", Fmt.price(tp), .hlGreen)) }
            if let sl = d.sl { lines.append(SummaryLine("Стоп-лосс", Fmt.price(sl), .hlRed)) }
            if d.reduceOnly { lines.append(SummaryLine("Reduce only", "да", .primary)) }
        }
        lines.append(SummaryLine("Стоимость", value > 0 ? Fmt.usd(value) : "—", .primary))
        if !market.isSpot {
            lines.append(SummaryLine("Маржа", value > 0 ? Fmt.usd(value / Double(currentLeverage)) : "—", .primary))
            if value > 0, !d.reduceOnly,
               let liq = model.estimateLiq(m: market, isBuy: d.isBuy, entry: px, size: d.size, leverage: currentLeverage,
                                           isCross: model.activeAsset.isCross && !market.onlyIsolated) {
                lines.append(SummaryLine("Ликвидация ≈", Fmt.price(liq), .orange))
            }
        }
        let fee = (d.type == .market || d.type == .twap || d.type.triggerIsMarket) ? model.takerFee : model.makerFee
        lines.append(SummaryLine("Комиссия ≈", value > 0 ? Fmt.usd(value * fee, 3) : "—", .primary))
        if let sl = d.sl, sl > 0, d.size > 0 {
            lines.append(SummaryLine("Убыток по SL", Fmt.signedUsd(-abs(px - sl) * d.size), .hlRed))
        }
        if let tp = d.tp, tp > 0, d.size > 0 {
            lines.append(SummaryLine("Прибыль по TP", Fmt.signedUsd(abs(tp - px) * d.size), .hlGreen))
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
                sizeText = ""; pct = 0
                if riskOn { riskText = "" }
            } catch {
                model.show(.error, error.localizedDescription)
                Haptics.error(enabled: model.haptics)
            }
            busy = false
        }
    }

    private func reset() {
        priceText = ""; triggerText = ""; sizeText = ""; tpText = ""; slText = ""; pct = 0
        scaleStartText = ""; scaleEndText = ""
        if market.isSpot && !availableTypes.contains(type) { type = .market }
        if market.isSpot { reduceOnly = false; tpslOn = false; riskOn = false }
    }
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
            Text("Подтверждение ордера").font(.headline).padding(.top, 16)
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
                Button("Отмена") { dismiss() }
                    .frame(maxWidth: .infinity).frame(height: 46)
                    .background(Color.hlCard2, in: RoundedRectangle(cornerRadius: 10))
                PrimaryButton(title: "Подтвердить", color: draft.isBuy ? .hlGreen : .hlRed) { onConfirm() }
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
                    Picker("Режим маржи", selection: $isCross) {
                        Text("Cross").tag(true)
                        Text("Isolated").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .disabled(market.onlyIsolated)
                } footer: {
                    Text(isCross ? "Cross: вся свободная маржа аккаунта поддерживает позицию." : "Isolated: риск ограничен маржой, выделенной под эту позицию.")
                }
                Section("Плечо: \(Int(leverage))x") {
                    Slider(value: $leverage, in: 1...Double(max(market.maxLeverage, 1)), step: 1)
                    HStack {
                        ForEach(presets, id: \.self) { p in
                            Button("\(p)x") { leverage = Double(p) }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
                Section {
                    PrimaryButton(title: "Применить", busy: busy) {
                        busy = true
                        Task {
                            do {
                                try await model.updateLeverage(market, leverage: Int(leverage), isCross: isCross)
                                model.show(.success, "Плечо \(Int(leverage))x \(isCross ? "Cross" : "Isolated")")
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
            .navigationTitle("Плечо \(market.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
            .onAppear {
                leverage = Double(model.position(market.id)?.leverage ?? max(1, model.activeAsset.leverage))
                isCross = market.onlyIsolated ? false : model.activeAsset.isCross
            }
        }
        .presentationDetents([.medium])
    }

    private var presets: [Int] {
        [1, 2, 3, 5, 10, 20, 25, 40, 50].filter { $0 <= market.maxLeverage }.suffix(6).map { $0 }
    }
}
