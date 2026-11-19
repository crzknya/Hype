import SwiftUI

struct OrderBookPanel: View {
    @Environment(AppModel.self) private var model
    let market: Market
    @State private var showUsd = false
    private let rows = 10

    var body: some View {
        @Bindable var model = model
        let asks = Array(model.book.asks.prefix(rows))
        let bids = Array(model.book.bids.prefix(rows))
        let askCum = cumulative(asks)
        let bidCum = cumulative(bids)
        let maxCum = max(askCum.last ?? 0, bidCum.last ?? 0, 1e-12)
        let dec = decimals

        VStack(spacing: 1) {
            HStack {
                Menu {
                    Picker("Группировка", selection: $model.bookSigFigs) {
                        Text("Без группировки").tag(Int?.none)
                        Text("5 знаков").tag(Int?.some(5))
                        Text("4 знака").tag(Int?.some(4))
                        Text("3 знака").tag(Int?.some(3))
                        Text("2 знака").tag(Int?.some(2))
                    }
                } label: {
                    HStack(spacing: 2) {
                        Text("Цена")
                        Image(systemName: "line.3.horizontal.decrease").font(.system(size: 8))
                    }
                }
                Spacer()
                Button { showUsd.toggle() } label: { Text(showUsd ? "USD" : market.base) }
            }
            .font(.system(size: 10))
            .foregroundStyle(Color.hlMuted)
            .padding(.bottom, 2)

            ForEach(Array(asks.enumerated().reversed()), id: \.element.id) { i, l in
                row(l, cum: askCum[i], maxCum: maxCum, isBid: false, dec: dec)
            }
            HStack {
                Text(model.book.mid.map { Fmt.price($0, decimals: dec) } ?? "—")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                Spacer()
                if let s = model.book.spread, let mid = model.book.mid, mid > 0 {
                    Text(Fmt.pct(s / mid, 3, signed: false)).font(.system(size: 9)).foregroundStyle(Color.hlMuted)
                }
            }
            .padding(.vertical, 4)
            ForEach(Array(bids.enumerated()), id: \.element.id) { i, l in
                row(l, cum: bidCum[i], maxCum: maxCum, isBid: true, dec: dec)
            }
            if model.book.bids.isEmpty && model.book.asks.isEmpty {
                ProgressView().padding()
            }
        }
    }

    private var decimals: Int {
        let px = model.mid(market.id)
        return market.priceDecimals(px)
    }

    private func cumulative(_ levels: [BookLevel]) -> [Double] {
        var acc = 0.0
        return levels.map { acc += $0.sz; return acc }
    }

    private func row(_ l: BookLevel, cum: Double, maxCum: Double, isBid: Bool, dec: Int) -> some View {
        let color = isBid ? Color.hlGreen : Color.hlRed
        return GeometryReader { g in
            ZStack(alignment: .trailing) {
                Rectangle().fill(color.opacity(0.14)).frame(width: g.size.width * CGFloat(cum / maxCum))
                HStack {
                    Text(Fmt.price(l.px, decimals: dec)).foregroundStyle(color)
                    Spacer()
                    Text(showUsd ? Fmt.compact(l.sz * l.px) : Fmt.num(l.sz, min(market.szDecimals, 4)))
                }
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
        }
        .frame(height: 17)
        .contentShape(Rectangle())
        .onTapGesture {
            model.pendingPrice = l.px
            Haptics.tap(enabled: model.haptics)
        }
    }
}

struct TradesPanel: View {
    @Environment(AppModel.self) private var model
    let market: Market

    var body: some View {
        VStack(spacing: 1) {
            HStack {
                Text("Цена"); Spacer(); Text("Размер"); Text("Время").frame(width: 40, alignment: .trailing)
            }
            .font(.system(size: 9)).foregroundStyle(Color.hlMuted)
            ForEach(model.trades.prefix(22)) { t in
                HStack(spacing: 4) {
                    Text(Fmt.price(t.px)).foregroundStyle(t.isBuy ? Color.hlGreen : Color.hlRed)
                    Spacer()
                    Text(Fmt.compact(t.sz))
                    Text(Fmt.time(t.time).suffix(5)).foregroundStyle(Color.hlMuted).frame(width: 40, alignment: .trailing)
                }
                .font(.system(size: 10, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(height: 16)
            }
            if model.trades.isEmpty { ProgressView().padding() }
        }
    }
}
