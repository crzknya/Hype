import SwiftUI
import HyperCore

struct ToolsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                Section(L("Calculators")) {
                    NavigationLink { PositionSizeCalculator() } label: {
                        Label(L("Position size by risk"), systemImage: "scalemass")
                    }
                    NavigationLink { PnlCalculator() } label: {
                        Label(L("PnL & ROE"), systemImage: "function")
                    }
                    NavigationLink { LiquidationCalculator() } label: {
                        Label(L("Liquidation price"), systemImage: "exclamationmark.triangle")
                    }
                }
                Section(L("Monitoring")) {
                    NavigationLink { AlertsView() } label: {
                        Label(L("Price alerts ({0})", model.alerts.count), systemImage: "bell.badge")
                    }
                    NavigationLink { FundingScannerView() } label: {
                        Label(L("Funding scanner"), systemImage: "percent")
                    }
                    NavigationLink { MoversView() } label: {
                        Label(L("Top gainers & losers"), systemImage: "chart.line.uptrend.xyaxis")
                    }
                }
                Section(L("Protection")) {
                    NavigationLink { DeadMansSwitchView() } label: {
                        Label(L("Auto-cancel orders"), systemImage: "timer")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.hlBg)
            .navigationTitle(L("Tools"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct PositionSizeCalculator: View {
    @Environment(AppModel.self) private var model
    @State private var balanceText = ""
    @State private var riskPctText = "1"
    @State private var entryText = ""
    @State private var stopText = ""
    @State private var targetText = ""
    @State private var leverageText = "10"

    var body: some View {
        let balance = Fmt.parse(balanceText) ?? model.summary.accountValue
        let risk = balance * (Fmt.parse(riskPctText) ?? 0) / 100
        let entry = Fmt.parse(entryText) ?? 0
        let stop = Fmt.parse(stopText) ?? 0
        let lev = max(1, Fmt.parse(leverageText) ?? 1)
        let dist = abs(entry - stop)
        let size = dist > 0 ? risk / dist : 0
        let notional = size * entry
        let isLong = stop < entry
        let target = Fmt.parse(targetText) ?? 0
        let reward = target > 0 ? abs(target - entry) * size : 0
        Form {
            Section(L("Parameters")) {
                NumField(title: L("Balance $"), text: $balanceText, placeholder: Fmt.input(model.summary.accountValue, 2))
                NumField(title: L("Risk %"), text: $riskPctText)
                NumField(title: L("Entry"), text: $entryText) {
                    Button("Mid") { entryText = Fmt.input(model.mid(model.selectedCoin), 6) }.font(.caption.bold())
                }
                NumField(title: L("Stop"), text: $stopText)
                NumField(title: L("Target"), text: $targetText, placeholder: L("opt."))
                NumField(title: L("Leverage"), text: $leverageText)
            }
            Section(L("Result")) {
                LabeledContent(L("Direction"), value: entry > 0 && stop > 0 ? (isLong ? L("Long") : L("Short")) : "—")
                LabeledContent(L("Risk"), value: Fmt.usd(risk))
                LabeledContent(L("Size"), value: Fmt.num(size, 4))
                LabeledContent(L("Position value"), value: Fmt.usd(notional))
                LabeledContent(L("Required margin"), value: Fmt.usd(notional / lev))
                LabeledContent(L("Stop distance"), value: entry > 0 ? Fmt.pct(dist / entry, 2, signed: false) : "—")
                if reward > 0 {
                    LabeledContent(L("Profit at target"), value: Fmt.usd(reward))
                    LabeledContent("R:R", value: risk > 0 ? "1 : " + Fmt.num(reward / risk, 2) : "—")
                }
                if notional / lev > balance && balance > 0 {
                    Text(L("Not enough margin: increase leverage or reduce risk")).font(.caption).foregroundStyle(Color.hlRed)
                }
            }
        }
        .navigationTitle(L("Risk sizing"))
        .keyboardDoneToolbar()
    }
}

struct PnlCalculator: View {
    @State private var isLong = true
    @State private var entryText = ""
    @State private var exitText = ""
    @State private var sizeText = ""
    @State private var leverageText = "10"
    @Environment(AppModel.self) private var model

    var body: some View {
        let entry = Fmt.parse(entryText) ?? 0, exit = Fmt.parse(exitText) ?? 0, size = Fmt.parse(sizeText) ?? 0
        let lev = max(1, Fmt.parse(leverageText) ?? 1)
        let pnl = (exit - entry) * size * (isLong ? 1 : -1)
        let margin = entry * size / lev
        let fees = (entry + exit) * size * model.takerFee
        Form {
            Picker("", selection: $isLong) { Text(L("Long")).tag(true); Text(L("Short")).tag(false) }.pickerStyle(.segmented)
            NumField(title: L("Entry"), text: $entryText)
            NumField(title: L("Exit"), text: $exitText)
            NumField(title: L("Size (coins)"), text: $sizeText)
            NumField(title: L("Leverage"), text: $leverageText)
            Section(L("Result")) {
                LabeledContent("PnL") { Text(Fmt.signedUsd(pnl)).foregroundStyle(Color.pnl(pnl)) }
                LabeledContent("ROE") { Text(margin > 0 ? Fmt.pct(pnl / margin) : "—").foregroundStyle(Color.pnl(pnl)) }
                LabeledContent(L("Margin"), value: Fmt.usd(margin))
                LabeledContent(L("Fees (taker) ≈"), value: Fmt.usd(fees))
                LabeledContent(L("PnL after fees")) { Text(Fmt.signedUsd(pnl - fees)).foregroundStyle(Color.pnl(pnl - fees)) }
            }
        }
        .navigationTitle(L("PnL calculator"))
        .keyboardDoneToolbar()
    }
}

struct LiquidationCalculator: View {
    @Environment(AppModel.self) private var model
    @State private var isLong = true
    @State private var entryText = ""
    @State private var leverageText = "10"

    var body: some View {
        let m = model.selectedMarket
        let entry = Fmt.parse(entryText) ?? 0
        let lev = max(1, Fmt.parse(leverageText) ?? 1)
        let maxLev = Double(m?.maxLeverage ?? 50)
        let mmr = 1 / (2 * maxLev)
        let side: Double = isLong ? 1 : -1
        // Isolated: margin = entry/lev per unit; liq when equity == maintenance
        let liq = entry > 0 ? (entry - side * entry / lev) / (1 - side * mmr) : 0
        Form {
            Section {
                Picker("", selection: $isLong) { Text(L("Long")).tag(true); Text(L("Short")).tag(false) }.pickerStyle(.segmented)
                NumField(title: L("Entry"), text: $entryText) {
                    Button("Mid") { entryText = Fmt.input(model.mid(model.selectedCoin), 6) }.font(.caption.bold())
                }
                NumField(title: L("Leverage"), text: $leverageText)
            } footer: {
                Text(L("Isolated margin, market {0} (max leverage {1}x, maintenance margin {2}).", m?.name ?? "—", Int(maxLev), Fmt.pct(mmr, 2, signed: false)))
            }
            Section(L("Result")) {
                LabeledContent(L("Liquidation price ≈")) { Text(liq > 0 ? Fmt.price(liq) : "—").foregroundStyle(.orange) }
                LabeledContent(L("Distance"), value: entry > 0 && liq > 0 ? Fmt.pct(abs(liq - entry) / entry, 2, signed: false) : "—")
            }
        }
        .navigationTitle(L("Liquidation"))
        .keyboardDoneToolbar()
    }
}

struct AlertsView: View {
    @Environment(AppModel.self) private var model
    @State private var adding = false

    var body: some View {
        List {
            Section {
                ForEach(model.alerts) { a in
                    HStack {
                        Image(systemName: a.above ? "arrow.up.circle" : "arrow.down.circle")
                            .foregroundStyle(a.above ? Color.hlGreen : Color.hlRed)
                        VStack(alignment: .leading) {
                            Text(a.name).font(.subheadline.bold())
                            Text("\(a.above ? L("above") : L("below")) \(Fmt.price(a.price))\(a.repeating ? L(" · repeat") : "")").font(.caption)
                        }
                        Spacer()
                        Text(Fmt.price(model.mid(a.coin))).font(.caption.monospaced()).foregroundStyle(Color.hlMuted)
                    }
                }
                .onDelete { idx in model.alerts.remove(atOffsets: idx) }
                if model.alerts.isEmpty { Text(L("No alerts")).foregroundStyle(Color.hlMuted) }
            } footer: {
                Text(L("Alerts are checked in real time while the app is open and periodically in the background (iOS decides how often)."))
            }
        }
        .navigationTitle(L("Price alerts"))
        .toolbar { Button { adding = true } label: { Image(systemName: "plus") } }
        .sheet(isPresented: $adding) { AddAlertSheet(coin: model.selectedCoin) }
        .onAppear { Notifier.requestPermission() }
    }
}

struct AddAlertSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var coin: String
    @State private var priceText = ""
    @State private var repeating = false
    @State private var picking = false

    var body: some View {
        NavigationStack {
            Form {
                Button { picking = true } label: {
                    LabeledContent(L("Market"), value: model.displayName(coin))
                }
                LabeledContent(L("Current price"), value: Fmt.price(model.mid(coin)))
                NumField(title: L("Alert price"), text: $priceText)
                HStack {
                    ForEach([-5.0, -2, 2, 5], id: \.self) { p in
                        Button("\(p > 0 ? "+" : "")\(Int(p))%") {
                            let px = model.mid(coin) * (1 + p / 100)
                            priceText = Fmt.input(px, Fmt.autoDecimals(px))
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                    }
                }
                Toggle(L("Repeat"), isOn: $repeating)
                PrimaryButton(title: L("Create alert")) {
                    guard let px = Fmt.parse(priceText), px > 0 else { return }
                    let above = px > model.mid(coin)
                    model.alerts.append(PriceAlert(coin: coin, name: model.displayName(coin), price: px, above: above, repeating: repeating))
                    Notifier.requestPermission()
                    model.show(.success, L("Alert: {0} {1} {2}", model.displayName(coin), above ? L("above") : L("below"), Fmt.price(px)))
                    dismiss()
                }
                .listRowBackground(Color.clear)
            }
            .navigationTitle(L("New alert"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { dismiss() } } }
            .sheet(isPresented: $picking) {
                CoinPicker { coin = $0; picking = false }
            }
        }
    }
}

/// Lightweight coin picker that does not change the selected trading market.
struct CoinPicker: View {
    @Environment(AppModel.self) private var model
    @State private var search = ""
    let onPick: (String) -> Void
    var body: some View {
        NavigationStack {
            List {
                ForEach(list) { m in
                    Button { onPick(m.id) } label: {
                        HStack {
                            Text(m.name)
                            Spacer()
                            Text(Fmt.price(model.mid(m.id))).font(.caption.monospaced()).foregroundStyle(Color.hlMuted)
                        }
                    }
                }
            }
            .searchable(text: $search)
            .navigationTitle(L("Market"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    var list: [Market] {
        let all = (model.perps + model.spots.filter { $0.dayNtlVlm > 0 }).sorted { $0.dayNtlVlm > $1.dayNtlVlm }
        return search.isEmpty ? all : all.filter { $0.name.uppercased().contains(search.uppercased()) }
    }
}

struct FundingScannerView: View {
    @Environment(AppModel.self) private var model
    @State private var positive = true

    private var list: [Market] {
        let all: [Market] = model.perps.map { (m: Market) -> Market in model.marketById[m.id] ?? m }
        let liquid: [Market] = all.filter { (m: Market) -> Bool in m.dayNtlVlm > 100_000 }
        let desc = positive
        let sorted: [Market] = liquid.sorted { (a: Market, b: Market) -> Bool in desc ? a.funding > b.funding : a.funding < b.funding }
        return Array(sorted.prefix(40))
    }

    var body: some View {
        List {
            Picker("", selection: $positive) {
                Text(L("Highest +")).tag(true)
                Text(L("Negative")).tag(false)
            }
            .pickerStyle(.segmented)
            Section {
                ForEach(list) { m in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(m.name).font(.subheadline.bold())
                            Text("OI \(Fmt.compactUsd(m.openInterestUsd)) · Vol \(Fmt.compactUsd(m.dayNtlVlm))").font(.caption2).foregroundStyle(Color.hlMuted)
                        }
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text(Fmt.pct(m.funding, 4)).font(.caption.monospaced()).foregroundStyle(Color.pnl(m.funding))
                            Text(Fmt.pct(m.fundingAnnual, 1) + L(" APR")).font(.caption2.monospaced()).foregroundStyle(Color.hlMuted)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { model.select(m.id) }
                }
            } footer: {
                Text(L("Positive funding is paid by longs to shorts, negative the other way round. Paid every hour. Markets with volume > $100K."))
            }
        }
        .navigationTitle(L("Funding scanner"))
    }
}

struct MoversView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let all: [Market] = model.perps.map { (m: Market) -> Market in model.marketById[m.id] ?? m }.filter { (m: Market) -> Bool in m.dayNtlVlm > 500_000 }
        let gainers: [Market] = Array(all.sorted { (a: Market, b: Market) -> Bool in a.change24h > b.change24h }.prefix(10))
        let losers: [Market] = Array(all.sorted { (a: Market, b: Market) -> Bool in a.change24h < b.change24h }.prefix(10))
        List {
            Section(L("24h gainers")) { ForEach(gainers) { row($0) } }
            Section(L("24h losers")) { ForEach(losers) { row($0) } }
        }
        .navigationTitle(L("Movers"))
    }
    private func row(_ m: Market) -> some View {
        HStack {
            Text(m.name).font(.subheadline.bold())
            Spacer()
            Text(Fmt.price(model.mid(m.id))).font(.caption.monospaced())
            ChangePill(value: m.change24h)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.select(m.id) }
    }
}

struct DeadMansSwitchView: View {
    @Environment(AppModel.self) private var model
    @State private var minutes = 60
    @State private var activeUntil: Date?

    var body: some View {
        Form {
            Section {
                Stepper(L("In {0} min", minutes), value: $minutes, in: 1...1440, step: minutes < 30 ? 1 : 15)
                PrimaryButton(title: L("Enable auto-cancel"), disabled: !model.canTrade) {
                    let m = minutes
                    model.perform {
                        try await model.scheduleCancel(minutes: m)
                        activeUntil = Date().addingTimeInterval(Double(m) * 60)
                        return L("All orders will be cancelled at {0}", Fmt.time(Date().addingTimeInterval(Double(m) * 60)))
                    }
                }
                .listRowBackground(Color.clear)
                Button(L("Disable"), role: .destructive) {
                    model.perform {
                        try await model.scheduleCancel(minutes: nil)
                        activeUntil = nil
                        return L("Auto-cancel disabled")
                    }
                }
                .disabled(!model.canTrade)
                if let a = activeUntil { LabeledContent(L("Fires at"), value: Fmt.time(a)) }
            } footer: {
                Text(L("Hyperliquid “dead man's switch”: unless you extend the timer, the exchange cancels all your open orders at the set time. Useful if you lose connection. Requires trading volume on the account; the number of triggers per day is limited by the exchange."))
            }
        }
        .navigationTitle(L("Auto-cancel"))
    }
}
