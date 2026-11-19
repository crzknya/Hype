import SwiftUI
import HyperCore

struct ClosePositionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let position: Position
    @State private var priceText = ""
    @State private var pct: Double = 1
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NumField(title: L("Price"), text: $priceText) {
                        Button("Mid") { priceText = Fmt.input(model.mid(position.coin), Fmt.autoDecimals(model.mid(position.coin))) }
                            .font(.caption.bold())
                    }
                    VStack(alignment: .leading) {
                        Text(L("Amount: {0}% · {1}", Int(pct * 100), Fmt.num(position.size * pct, model.market(position.coin)?.szDecimals ?? 4)))
                            .font(.caption)
                        Slider(value: $pct, in: 0.05...1, step: 0.05)
                        PercentButtons(onSelect: { pct = $0 }, values: [0.25, 0.5, 0.75, 1])
                    }
                } footer: {
                    Text(L("Reduce-only limit order to close. Leave the price empty to close at market."))
                }
                if let px = Fmt.parse(priceText) {
                    Section {
                        let pnl = (px - position.entryPx) * position.size * pct * (position.isLong ? 1 : -1)
                        LabeledContent(L("Expected PnL")) { Text(Fmt.signedUsd(pnl)).foregroundStyle(Color.pnl(pnl)) }
                    }
                }
                Section {
                    PrimaryButton(title: Fmt.parse(priceText) == nil ? L("Close at market") : L("Place limit"), color: .hlRed, busy: busy) {
                        busy = true
                        Task {
                            do {
                                let msg = try await model.closePosition(position, fraction: pct, limitPx: Fmt.parse(priceText))
                                model.show(.success, msg)
                                dismiss()
                            } catch { model.show(.error, error.localizedDescription) }
                            busy = false
                        }
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle(L("Close {0}", model.displayName(position.coin)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { dismiss() } } }
            .keyboardDoneToolbar()
        }
        .presentationDetents([.medium, .large])
    }
}

struct TpslSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let position: Position
    @State private var tpText = ""
    @State private var slText = ""
    @State private var busy = false

    var body: some View {
        let lev = Double(position.leverage)
        NavigationStack {
            Form {
                Section(L("Position")) {
                    LabeledContent(L("Entry"), value: Fmt.price(position.entryPx))
                    LabeledContent(L("Mark"), value: Fmt.price(model.mid(position.coin)))
                    LabeledContent(L("Size"), value: Fmt.num(position.size, model.market(position.coin)?.szDecimals ?? 4))
                }
                Section {
                    NumField(title: L("Take profit"), text: $tpText, placeholder: L("price"))
                    roeButtons(isTp: true, lev: lev)
                    if let tp = Fmt.parse(tpText) { pnlLine(tp) }
                    NumField(title: L("Stop loss"), text: $slText, placeholder: L("price"))
                    roeButtons(isTp: false, lev: lev)
                    if let sl = Fmt.parse(slText) { pnlLine(sl) }
                } footer: {
                    Text(L("Orders for the whole position (market when triggered). Existing position TP/SL will be replaced. Buttons set % ROE including leverage."))
                }
                Section {
                    PrimaryButton(title: L("Save"), busy: busy) {
                        busy = true
                        Task {
                            do {
                                let msg = try await model.setPositionTpsl(position, tp: Fmt.parse(tpText), sl: Fmt.parse(slText))
                                model.show(.success, msg)
                                dismiss()
                            } catch { model.show(.error, error.localizedDescription) }
                            busy = false
                        }
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("TP/SL \(model.displayName(position.coin))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { dismiss() } } }
            .keyboardDoneToolbar()
            .onAppear {
                let existing = model.openOrders.filter { $0.coin == position.coin && $0.isTrigger && $0.reduceOnly }
                if let tp = existing.first(where: { $0.orderType.hasPrefix("Take") }) { tpText = Fmt.input(tp.triggerPx, 8) }
                if let sl = existing.first(where: { $0.orderType.hasPrefix("Stop") }) { slText = Fmt.input(sl.triggerPx, 8) }
            }
        }
    }

    private func roeButtons(isTp: Bool, lev: Double) -> some View {
        HStack {
            ForEach(isTp ? [10.0, 25, 50, 100] : [-5.0, -10, -25, -50], id: \.self) { roe in
                Button("\(roe > 0 ? "+" : "")\(Int(roe))%") {
                    let move = roe / 100 / lev * (position.isLong ? 1 : -1)
                    let px = position.entryPx * (1 + move)
                    let s = Fmt.input(px, Fmt.autoDecimals(px))
                    if isTp { tpText = s } else { slText = s }
                }
                .buttonStyle(.bordered).controlSize(.small)
                .tint(isTp ? .hlGreen : .hlRed)
            }
        }
    }

    private func pnlLine(_ px: Double) -> some View {
        let pnl = (px - position.entryPx) * position.size * (position.isLong ? 1 : -1)
        let roe = position.marginUsed > 0 ? pnl / position.marginUsed : 0
        return HStack {
            Text(L("PnL when triggered")).font(.caption).foregroundStyle(Color.hlMuted)
            Spacer()
            Text("\(Fmt.signedUsd(pnl)) (\(Fmt.pct(roe, 1)))").font(.caption.monospaced()).foregroundStyle(Color.pnl(pnl))
        }
    }
}

struct MarginSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let position: Position
    @State private var add = true
    @State private var amountText = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Picker("", selection: $add) {
                    Text(L("Add")).tag(true)
                    Text(L("Remove")).tag(false)
                }
                .pickerStyle(.segmented)
                NumField(title: L("Amount $"), text: $amountText)
                LabeledContent(L("Current margin"), value: Fmt.usd(position.marginUsed))
                LabeledContent(L("Available"), value: Fmt.usd(model.summary.withdrawable))
                PrimaryButton(title: L("Apply"), busy: busy) {
                    guard let a = Fmt.parse(amountText), a > 0 else { return }
                    busy = true
                    Task {
                        do {
                            try await model.updateIsolatedMargin(position, deltaUsd: add ? a : -a)
                            model.show(.success, L("Margin updated"))
                            dismiss()
                        } catch { model.show(.error, error.localizedDescription) }
                        busy = false
                    }
                }
                .listRowBackground(Color.clear)
            }
            .navigationTitle(L("Margin {0}", model.displayName(position.coin)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}

struct ModifyOrderSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let order: OpenOrder
    @State private var priceText = ""
    @State private var triggerText = ""
    @State private var sizeText = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                if order.isTrigger { NumField(title: L("Trigger"), text: $triggerText) }
                if !order.orderType.contains("Market") || !order.isTrigger { NumField(title: L("Price"), text: $priceText) }
                NumField(title: L("Size"), text: $sizeText)
                PrimaryButton(title: L("Modify order"), busy: busy) {
                    busy = true
                    Task {
                        do {
                            let trig = Fmt.parse(triggerText)
                            var px = Fmt.parse(priceText) ?? order.limitPx
                            if order.isTrigger && order.orderType.contains("Market"), let t = trig, t > 0 {
                                // keep the slippage limit relative to the new trigger
                                px = order.triggerPx > 0 ? order.limitPx / order.triggerPx * t : t
                            }
                            try await model.modify(order, price: px, size: Fmt.parse(sizeText) ?? order.sz, trigger: trig)
                            model.show(.success, L("Order modified"))
                            dismiss()
                        } catch { model.show(.error, error.localizedDescription) }
                        busy = false
                    }
                }
                .listRowBackground(Color.clear)
            }
            .navigationTitle(L("Modify order"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { dismiss() } } }
            .keyboardDoneToolbar()
            .onAppear {
                priceText = Fmt.input(order.limitPx, 8)
                triggerText = order.isTrigger ? Fmt.input(order.triggerPx, 8) : ""
                sizeText = Fmt.input(order.sz, 8)
            }
        }
        .presentationDetents([.medium])
    }
}
