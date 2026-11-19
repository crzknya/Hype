import SwiftUI
import HyperCore

struct ToolsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                Section("Калькуляторы") {
                    NavigationLink { PositionSizeCalculator() } label: {
                        Label("Размер позиции по риску", systemImage: "scalemass")
                    }
                    NavigationLink { PnlCalculator() } label: {
                        Label("PnL и ROE", systemImage: "function")
                    }
                    NavigationLink { LiquidationCalculator() } label: {
                        Label("Цена ликвидации", systemImage: "exclamationmark.triangle")
                    }
                }
                Section("Мониторинг") {
                    NavigationLink { AlertsView() } label: {
                        Label("Ценовые алерты (\(model.alerts.count))", systemImage: "bell.badge")
                    }
                    NavigationLink { FundingScannerView() } label: {
                        Label("Сканер фандинга", systemImage: "percent")
                    }
                    NavigationLink { MoversView() } label: {
                        Label("Лидеры роста и падения", systemImage: "chart.line.uptrend.xyaxis")
                    }
                }
                Section("Защита") {
                    NavigationLink { DeadMansSwitchView() } label: {
                        Label("Авто-отмена ордеров", systemImage: "timer")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.hlBg)
            .navigationTitle("Инструменты")
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
            Section("Параметры") {
                NumField(title: "Депозит $", text: $balanceText, placeholder: Fmt.input(model.summary.accountValue, 2))
                NumField(title: "Риск %", text: $riskPctText)
                NumField(title: "Вход", text: $entryText) {
                    Button("Mid") { entryText = Fmt.input(model.mid(model.selectedCoin), 6) }.font(.caption.bold())
                }
                NumField(title: "Стоп", text: $stopText)
                NumField(title: "Цель", text: $targetText, placeholder: "опц.")
                NumField(title: "Плечо", text: $leverageText)
            }
            Section("Результат") {
                LabeledContent("Направление", value: entry > 0 && stop > 0 ? (isLong ? "Лонг" : "Шорт") : "—")
                LabeledContent("Риск", value: Fmt.usd(risk))
                LabeledContent("Размер", value: Fmt.num(size, 4))
                LabeledContent("Стоимость позиции", value: Fmt.usd(notional))
                LabeledContent("Нужная маржа", value: Fmt.usd(notional / lev))
                LabeledContent("Дистанция стопа", value: entry > 0 ? Fmt.pct(dist / entry, 2, signed: false) : "—")
                if reward > 0 {
                    LabeledContent("Прибыль по цели", value: Fmt.usd(reward))
                    LabeledContent("R:R", value: risk > 0 ? "1 : " + Fmt.num(reward / risk, 2) : "—")
                }
                if notional / lev > balance && balance > 0 {
                    Text("Недостаточно маржи — увеличьте плечо или уменьшите риск").font(.caption).foregroundStyle(Color.hlRed)
                }
            }
        }
        .navigationTitle("Размер по риску")
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
            Picker("", selection: $isLong) { Text("Лонг").tag(true); Text("Шорт").tag(false) }.pickerStyle(.segmented)
            NumField(title: "Вход", text: $entryText)
            NumField(title: "Выход", text: $exitText)
            NumField(title: "Размер (монет)", text: $sizeText)
            NumField(title: "Плечо", text: $leverageText)
            Section("Результат") {
                LabeledContent("PnL") { Text(Fmt.signedUsd(pnl)).foregroundStyle(Color.pnl(pnl)) }
                LabeledContent("ROE") { Text(margin > 0 ? Fmt.pct(pnl / margin) : "—").foregroundStyle(Color.pnl(pnl)) }
                LabeledContent("Маржа", value: Fmt.usd(margin))
                LabeledContent("Комиссии (тейкер) ≈", value: Fmt.usd(fees))
                LabeledContent("PnL после комиссий") { Text(Fmt.signedUsd(pnl - fees)).foregroundStyle(Color.pnl(pnl - fees)) }
            }
        }
        .navigationTitle("PnL калькулятор")
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
                Picker("", selection: $isLong) { Text("Лонг").tag(true); Text("Шорт").tag(false) }.pickerStyle(.segmented)
                NumField(title: "Вход", text: $entryText) {
                    Button("Mid") { entryText = Fmt.input(model.mid(model.selectedCoin), 6) }.font(.caption.bold())
                }
                NumField(title: "Плечо", text: $leverageText)
            } footer: {
                Text("Изолированная маржа, рынок \(m?.name ?? "—") (макс. плечо \(Int(maxLev))x, поддерживающая маржа \(Fmt.pct(mmr, 2, signed: false))).")
            }
            Section("Результат") {
                LabeledContent("Цена ликвидации ≈") { Text(liq > 0 ? Fmt.price(liq) : "—").foregroundStyle(.orange) }
                LabeledContent("Расстояние", value: entry > 0 && liq > 0 ? Fmt.pct(abs(liq - entry) / entry, 2, signed: false) : "—")
            }
        }
        .navigationTitle("Ликвидация")
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
                            Text("\(a.above ? "выше" : "ниже") \(Fmt.price(a.price))\(a.repeating ? " · повтор" : "")").font(.caption)
                        }
                        Spacer()
                        Text(Fmt.price(model.mid(a.coin))).font(.caption.monospaced()).foregroundStyle(Color.hlMuted)
                    }
                }
                .onDelete { idx in model.alerts.remove(atOffsets: idx) }
                if model.alerts.isEmpty { Text("Алертов нет").foregroundStyle(Color.hlMuted) }
            } footer: {
                Text("Алерты проверяются в реальном времени, пока приложение открыто, и периодически в фоне (как часто — решает iOS).")
            }
        }
        .navigationTitle("Ценовые алерты")
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
                    LabeledContent("Рынок", value: model.displayName(coin))
                }
                LabeledContent("Текущая цена", value: Fmt.price(model.mid(coin)))
                NumField(title: "Цена алерта", text: $priceText)
                HStack {
                    ForEach([-5.0, -2, 2, 5], id: \.self) { p in
                        Button("\(p > 0 ? "+" : "")\(Int(p))%") {
                            let px = model.mid(coin) * (1 + p / 100)
                            priceText = Fmt.input(px, Fmt.autoDecimals(px))
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                    }
                }
                Toggle("Повторять", isOn: $repeating)
                PrimaryButton(title: "Создать алерт") {
                    guard let px = Fmt.parse(priceText), px > 0 else { return }
                    let above = px > model.mid(coin)
                    model.alerts.append(PriceAlert(coin: coin, name: model.displayName(coin), price: px, above: above, repeating: repeating))
                    Notifier.requestPermission()
                    model.show(.success, "Алерт: \(model.displayName(coin)) \(above ? "выше" : "ниже") \(Fmt.price(px))")
                    dismiss()
                }
                .listRowBackground(Color.clear)
            }
            .navigationTitle("Новый алерт")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
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
            .navigationTitle("Рынок")
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

    var body: some View {
        let list = model.perps.map { model.marketById[$0.id] ?? $0 }
            .filter { $0.dayNtlVlm > 100_000 }
            .sorted { positive ? $0.funding > $1.funding : $0.funding < $1.funding }
            .prefix(40)
        List {
            Picker("", selection: $positive) {
                Text("Высокий +").tag(true)
                Text("Отрицательный").tag(false)
            }
            .pickerStyle(.segmented)
            Section {
                ForEach(Array(list)) { m in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(m.name).font(.subheadline.bold())
                            Text("OI \(Fmt.compactUsd(m.openInterestUsd)) · Vol \(Fmt.compactUsd(m.dayNtlVlm))").font(.caption2).foregroundStyle(Color.hlMuted)
                        }
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text(Fmt.pct(m.funding, 4)).font(.caption.monospaced()).foregroundStyle(Color.pnl(m.funding))
                            Text(Fmt.pct(m.fundingAnnual, 1) + " год.").font(.caption2.monospaced()).foregroundStyle(Color.hlMuted)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { model.select(m.id) }
                }
            } footer: {
                Text("Положительный фандинг платят лонги шортам, отрицательный — наоборот. Выплаты каждый час. Рынки с объёмом > $100K.")
            }
        }
        .navigationTitle("Сканер фандинга")
    }
}

struct MoversView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let all = model.perps.map { model.marketById[$0.id] ?? $0 }.filter { $0.dayNtlVlm > 500_000 }
        let gainers = all.sorted { $0.change24h > $1.change24h }.prefix(10)
        let losers = all.sorted { $0.change24h < $1.change24h }.prefix(10)
        List {
            Section("Рост за 24ч") { ForEach(Array(gainers)) { row($0) } }
            Section("Падение за 24ч") { ForEach(Array(losers)) { row($0) } }
        }
        .navigationTitle("Лидеры")
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
                Stepper("Через \(minutes) мин", value: $minutes, in: 1...1440, step: minutes < 30 ? 1 : 15)
                PrimaryButton(title: "Включить авто-отмену", disabled: !model.canTrade) {
                    let m = minutes
                    model.perform {
                        try await model.scheduleCancel(minutes: m)
                        activeUntil = Date().addingTimeInterval(Double(m) * 60)
                        return "Все ордера будут отменены в \(Fmt.time(Date().addingTimeInterval(Double(m) * 60)))"
                    }
                }
                .listRowBackground(Color.clear)
                Button("Отключить", role: .destructive) {
                    model.perform {
                        try await model.scheduleCancel(minutes: nil)
                        activeUntil = nil
                        return "Авто-отмена отключена"
                    }
                }
                .disabled(!model.canTrade)
                if let a = activeUntil { LabeledContent("Сработает", value: Fmt.time(a)) }
            } footer: {
                Text("«Dead man's switch» Hyperliquid: если вы не продлите таймер, биржа отменит все ваши открытые ордера в указанное время. Полезно при потере связи. Требует торгового объёма на аккаунте; число срабатываний в день ограничено биржей.")
            }
        }
        .navigationTitle("Авто-отмена")
    }
}
