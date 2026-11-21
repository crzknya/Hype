import SwiftUI
import HyperCore

/// List of outcome markets: questions (several named outcomes) and standalone Yes/No markets.
struct OutcomesList: View {
    @Environment(AppModel.self) private var model
    let search: String

    var body: some View {
        let q = search.lowercased()
        let questions = model.outcomeQuestions.filter { q.isEmpty || model.questionTitle($0).lowercased().contains(q) }
        let standalone = model.standaloneOutcomes.filter { q.isEmpty || model.outcomeTitle($0).lowercased().contains(q) }
            .sorted { volume($0) > volume($1) }
        List {
            if model.outcomeSpecs.isEmpty {
                ProgressView(L("Loading outcome markets…")).task { await model.loadOutcomes() }
            }
            if !questions.isEmpty {
                Section(L("Questions")) {
                    ForEach(questions) { question in
                        NavigationLink { OutcomeQuestionView(question: question) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.questionTitle(question)).font(.subheadline.bold())
                                let top = question.named.compactMap { model.outcome($0) }
                                    .sorted { model.outcomePrice($0, 0) > model.outcomePrice($1, 0) }.prefix(3)
                                ForEach(Array(top)) { o in
                                    HStack {
                                        Text(model.outcomeTitle(o)).font(.caption).lineLimit(1)
                                        Spacer()
                                        Text(Fmt.pct(model.outcomePrice(o, 0), 0, signed: false)).font(.caption.monospaced())
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if !standalone.isEmpty {
                Section(L("Markets")) {
                    ForEach(standalone) { o in
                        NavigationLink { OutcomeDetailView(spec: o) } label: { OutcomeRow(spec: o) }
                    }
                }
            }
            Section {
                Text(L("Outcome tokens settle to 1 USDC if the outcome happens and 0 otherwise; the price is the market's probability. Using material non-public information is prohibited."))
                    .font(.caption2).foregroundStyle(Color.hlMuted)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await model.loadOutcomes() }
    }

    private func volume(_ o: OutcomeSpec) -> Double { model.market(o.coin(0))?.dayNtlVlm ?? 0 }
}

struct OutcomeRow: View {
    @Environment(AppModel.self) private var model
    let spec: OutcomeSpec

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.outcomeTitle(spec)).font(.subheadline.bold()).lineLimit(2)
                Text(L("Vol {0}", Fmt.compactUsd(model.market(spec.coin(0))?.dayNtlVlm ?? 0)))
                    .font(.caption2).foregroundStyle(Color.hlMuted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(Fmt.pct(model.outcomePrice(spec, 0), 1, signed: false)).font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.hlGreen)
                Text(model.outcomeSideName(spec, 0)).font(.caption2).foregroundStyle(Color.hlMuted)
            }
        }
    }
}

/// A question with several named outcomes; each outcome is its own Yes/No market.
struct OutcomeQuestionView: View {
    @Environment(AppModel.self) private var model
    let question: OutcomeQuestion

    var body: some View {
        let outcomes = (question.named + (question.fallback.map { [$0] } ?? [])).compactMap { model.outcome($0) }
            .sorted { model.outcomePrice($0, 0) > model.outcomePrice($1, 0) }
        List {
            Section {
                Text(model.questionDescription(question)).font(.caption).foregroundStyle(Color.hlMuted)
            }
            Section(L("Outcomes ({0})", outcomes.count)) {
                ForEach(outcomes) { o in
                    NavigationLink { OutcomeDetailView(spec: o) } label: {
                        HStack {
                            Text(model.outcomeTitle(o)).font(.subheadline)
                            if question.settled.contains(o.id) { Badge(text: L("Settled"), color: .hlMuted) }
                            Spacer()
                            Text(Fmt.pct(model.outcomePrice(o, 0), 1, signed: false)).font(.system(size: 14, weight: .semibold, design: .monospaced))
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .themedBackground()
        .navigationTitle(model.questionTitle(question))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A Yes/No outcome market: prices, holdings and buy/sell of either side.
struct OutcomeDetailView: View {
    @Environment(AppModel.self) private var model
    let spec: OutcomeSpec
    @State private var trade: Int?      // side to trade

    var body: some View {
        List {
            Section {
                Text(model.outcomeTitle(spec)).font(.headline)
                Text(model.outcomeDescription(spec)).font(.caption).foregroundStyle(Color.hlMuted)
            }
            Section(L("Prices")) {
                ForEach(0..<max(spec.sideSpecs.count, 2), id: \.self) { side in
                    let held = model.spotBalances.first { $0.coin == "+\(spec.id * 10 + side)" }
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.outcomeSideName(spec, side)).font(.subheadline.bold())
                            if let held, held.total > 0 {
                                Text(L("You hold {0} shares", Fmt.num(held.total, 2))).font(.caption2).foregroundStyle(Color.hlAccent)
                            }
                        }
                        Spacer()
                        Text(Fmt.pct(model.outcomePrice(spec, side), 1, signed: false)).font(.system(size: 15, weight: .bold, design: .monospaced))
                        Button(L("Trade")) { trade = side }
                            .buttonStyle(.borderedProminent).tint(side == 0 ? .hlGreen : .hlRed).controlSize(.small)
                            .disabled(!model.canTrade)
                    }
                }
            }
            Section {
                Text(L("Buy orders pay no fees. Estimates use midpoint prices, before fees and slippage."))
                    .font(.caption2).foregroundStyle(Color.hlMuted)
            }
        }
        .scrollContentBackground(.hidden)
        .themedBackground()
        .navigationTitle(L("Outcome"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: Binding(get: { trade.map { OutcomeTradeTarget(side: $0) } }, set: { trade = $0?.side })) { t in
            OutcomeTradeSheet(spec: spec, side: t.side)
        }
    }
}

struct OutcomeTradeTarget: Identifiable {
    let side: Int
    var id: Int { side }
}

struct OutcomeTradeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let spec: OutcomeSpec
    let side: Int
    @State private var isBuy = true
    @State private var limit = false
    @State private var amountText = ""
    @State private var priceText = ""
    @State private var busy = false

    var body: some View {
        let coin = spec.coin(side)
        let price = limit ? (Fmt.parse(priceText) ?? 0) : model.mid(coin)
        let held = model.spotAvailable("+\(spec.id * 10 + side)")
        let usdc = model.spotAvailable(spec.quoteToken.isEmpty ? "USDC" : spec.quoteToken)
        let amount = Fmt.parse(amountText) ?? 0
        let shares = isBuy ? (price > 0 ? amount / price : 0) : amount
        NavigationStack {
            Form {
                Section {
                    Picker("", selection: $isBuy) {
                        Text(L("Buy {0}", model.outcomeSideName(spec, side))).tag(true)
                        Text(L("Sell {0}", model.outcomeSideName(spec, side))).tag(false)
                    }
                    .pickerStyle(.segmented)
                    Picker(L("Type"), selection: $limit) {
                        Text(L("Market")).tag(false)
                        Text(L("Limit")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    if limit {
                        NumField(title: L("Price"), text: $priceText, placeholder: Fmt.num(model.mid(coin), 4))
                    }
                    NumField(title: isBuy ? "USDC" : L("Shares"), text: $amountText) {
                        Button("MAX") { amountText = Fmt.input(isBuy ? floor(usdc * 100) / 100 : floor(held), isBuy ? 2 : 0) }
                            .font(.caption.bold())
                    }
                    LabeledContent(L("Available"), value: isBuy ? Fmt.usd(usdc) : L("{0} shares", Fmt.num(held, 2)))
                }
                Section {
                    LabeledContent(L("Price"), value: Fmt.pct(price, 2, signed: false))
                    LabeledContent(L("Shares"), value: Fmt.num(floor(shares), 0))
                    if isBuy {
                        LabeledContent(L("Payout if it happens"), value: Fmt.usd(floor(shares)))
                    } else {
                        LabeledContent(L("You receive ≈"), value: Fmt.usd(floor(shares) * price))
                    }
                }
                Section {
                    PrimaryButton(title: isBuy ? L("Buy {0}", model.outcomeSideName(spec, side)) : L("Sell {0}", model.outcomeSideName(spec, side)),
                                  color: isBuy ? .hlGreen : .hlRed, busy: busy, disabled: floor(shares) < 1 || price <= 0 || price >= 1) {
                        place(shares: floor(shares))
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle(model.outcomeTitle(spec))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Close")) { dismiss() } } }
            .keyboardDoneToolbar()
        }
        .presentationDetents([.medium, .large])
    }

    private func place(shares: Double) {
        guard let m = model.market(spec.coin(side)) else { return }
        var d = OrderDraft(market: m, isBuy: isBuy, type: limit ? .limit : .market, size: shares)
        if limit { d.price = Fmt.parse(priceText) }
        busy = true
        Task {
            do {
                let msg = try await model.place(d)
                model.show(.success, msg)
                dismiss()
            } catch { model.show(.error, error.localizedDescription) }
            busy = false
        }
    }
}
