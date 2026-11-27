import SwiftUI
import HyperCore

struct PositionRow: View {
    @Environment(AppModel.self) private var model
    let position: Position
    @State private var sheet: PositionSheet?
    @State private var pending: PendingConfirm?

    enum PositionSheet: String, Identifiable {
        case close, tpsl, margin, trailing
        var id: String { rawValue }
    }

    var body: some View {
        let p = position
        let m = model.market(p.coin)
        let mark = model.mid(p.coin)
        let tpsl = model.openOrders.filter { $0.coin == p.coin && $0.isTrigger && $0.reduceOnly }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                // Tap the market name to open it on the trade screen.
                Button { model.select(p.coin) } label: {
                    HStack(spacing: 3) {
                        Text(model.displayName(p.coin)).font(.headline)
                        Image(systemName: "chevron.right").font(.caption2.bold()).foregroundStyle(Color.hlMuted)
                    }
                }
                .buttonStyle(.plain)
                SideBadge(isLong: p.isLong)
                Badge(text: "\(p.leverage)x \(p.leverageType == "isolated" ? "Iso" : "Cross")", color: .hlMuted)
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Fmt.signedUsd(p.unrealizedPnl)).font(.system(size: 15, weight: .bold, design: .monospaced))
                    Text(Fmt.pct(p.returnOnEquity)).font(.system(size: 11, design: .monospaced))
                }
                .foregroundStyle(Color.pnl(p.unrealizedPnl))
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Stat(title: L("Size"), value: "\(Fmt.num(p.size, m?.szDecimals ?? 4))")
                    Stat(title: L("Value"), value: Fmt.usd(p.positionValue))
                    Stat(title: L("Margin"), value: Fmt.usd(p.marginUsed))
                }
                GridRow {
                    Stat(title: L("Entry"), value: Fmt.price(p.entryPx))
                    Stat(title: L("Mark"), value: Fmt.price(mark))
                    Stat(title: L("Liquidation"), value: p.liquidationPx.map { Fmt.price($0) } ?? "—", color: .orange)
                }
                let taker = m.map { model.fees(for: $0).taker } ?? model.takerFee
                if let be = QuantMath.breakEven(p, takerFee: taker) {
                    GridRow {
                        // Price that covers both fees and the funding paid so far; distance from the mark.
                        Stat(title: L("Break-even"), value: Fmt.price(be))
                        Stat(title: L("To break-even"), value: mark > 0 ? Fmt.pct(be / mark - 1, 2) : "—",
                             color: (p.isLong ? mark >= be : mark <= be) ? .hlGreen : .hlMuted)
                        Stat(title: L("Close fee ≈"), value: Fmt.usd(p.size * mark * taker, 2))
                    }
                }
                GridRow {
                    Stat(title: L("Funding"), value: Fmt.signedUsd(-p.fundingSinceOpen), color: Color.pnl(-p.fundingSinceOpen))
                    Stat(title: "TP", value: tpsl.first { $0.orderType.hasPrefix("Take") }.map { Fmt.price($0.triggerPx) } ?? "—", color: .hlGreen)
                    Stat(title: "SL", value: tpsl.first { $0.orderType.hasPrefix("Stop") }.map { Fmt.price($0.triggerPx) } ?? "—", color: .hlRed)
                }
            }
            if model.canTrade {
                HStack(spacing: 6) {
                    actionButton(L("Close"), color: .hlRed) { confirmClose(1) }
                    actionButton("50%") { confirmClose(0.5) }
                    actionButton(L("Limit")) { sheet = .close }
                    actionButton("TP/SL") { sheet = .tpsl }
                    Menu {
                        Button(L("Close 25%")) { confirmClose(0.25) }
                        Button(L("Reverse position")) {
                            pending = PendingConfirm(
                                title: L("Reverse position"),
                                message: L("Market order for {0} {1}: closes the {2} and opens the opposite position of the same size.",
                                           Fmt.num(p.size * 2, m?.szDecimals ?? 4), model.displayName(p.coin), p.isLong ? L("Long") : L("Short")),
                                button: L("Reverse")) {
                                model.perform { try await model.reverse(p) }
                            }
                        }
                        Button(L("Trailing stop")) { sheet = .trailing }
                        Button(L("Chase close")) {
                            pending = PendingConfirm(
                                title: L("Chase close"),
                                message: L("Post-only order that rests at the top of the book and follows it until {0} {1} is closed. Runs while the app is open.",
                                           Fmt.num(p.size, m?.szDecimals ?? 4), model.displayName(p.coin)),
                                button: L("Start")) {
                                guard let m else { return }
                                model.perform {
                                    try await model.startChase(m, isBuy: !p.isLong, size: p.size, reduceOnly: true, maxDistance: 0)
                                    return L("Chase order placed")
                                }
                            }
                        }
                        if p.leverageType == "isolated" { Button(L("Adjust margin")) { sheet = .margin } }
                        Button(L("Open chart")) { model.select(p.coin) }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 34, height: 30)
                            .background(Color.hlCard2, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
        .padding(12)
        .themedCard()
        .confirmDialog($pending)
        .sheet(item: $sheet) { s in
            switch s {
            case .close: ClosePositionSheet(position: p)
            case .tpsl: TpslSheet(position: p)
            case .margin: MarginSheet(position: p)
            case .trailing: TrailingStopSheet(position: p)
            }
        }
    }

    private func confirmClose(_ fraction: Double) {
        let p = position
        let run = { model.perform { try await model.closePosition(p, fraction: fraction) } }
        guard model.confirmOrders else { run(); return }
        let dec = model.market(p.coin)?.szDecimals ?? 4
        pending = PendingConfirm(
            title: fraction >= 1 ? L("Close position") : L("Close {0}%", Int(fraction * 100)),
            message: L("Market close {0} {1} · PnL ≈ {2}", Fmt.num(p.size * fraction, dec), model.displayName(p.coin),
                       Fmt.signedUsd(p.unrealizedPnl * fraction)),
            button: L("Close at market"), action: run)
    }

    private func actionButton(_ title: String, color: Color = .primary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
                .frame(maxWidth: .infinity).frame(height: 30)
                .background(Color.hlCard2, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

struct OrderRow: View {
    @Environment(AppModel.self) private var model
    let order: OpenOrder
    @State private var editing = false
    @State private var busy = false

    var body: some View {
        let o = order
        let m = model.market(o.coin)
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(model.displayName(o.coin)).font(.subheadline.bold())
                    SideBadge(isLong: o.isBuy, spot: m?.isSpot ?? false)
                    Text(o.typeTitle).font(.caption).foregroundStyle(Color.hlMuted)
                    if o.reduceOnly { Badge(text: "RO", color: .hlMuted) }
                }
                HStack(spacing: 10) {
                    if o.isTrigger {
                        Text(L("Trigger {0}", o.triggerCondition.isEmpty ? Fmt.price(o.triggerPx) : o.triggerCondition))
                    }
                    if !o.orderType.contains("Market") { Text(L("Price {0}", Fmt.price(o.limitPx))) }
                }
                .font(.system(size: 11, design: .monospaced))
                HStack(spacing: 10) {
                    Text("\(Fmt.num(o.origSz - o.sz, m?.szDecimals ?? 4)) / \(o.sz == 0 ? L("position") : Fmt.num(o.origSz, m?.szDecimals ?? 4))")
                    Text(Fmt.dateTime(o.timestamp)).foregroundStyle(Color.hlMuted)
                }
                .font(.system(size: 11, design: .monospaced))
            }
            Spacer()
            if model.canTrade {
                Button { editing = true } label: { Image(systemName: "pencil") }
                    .buttonStyle(.bordered).controlSize(.small)
                Button {
                    busy = true
                    Task {
                        do { try await model.cancel(o); Haptics.success(enabled: model.haptics) }
                        catch { model.show(.error, error.localizedDescription) }
                        busy = false
                    }
                } label: {
                    if busy { ProgressView().controlSize(.small) } else { Image(systemName: "xmark") }
                }
                .buttonStyle(.bordered).controlSize(.small).tint(.hlRed)
            }
        }
        .padding(10)
        .themedCard()
        .sheet(isPresented: $editing) { ModifyOrderSheet(order: o) }
    }
}

struct FillRow: View {
    @Environment(AppModel.self) private var model
    let fill: Fill
    var body: some View {
        let m = model.market(fill.coin)
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(model.displayName(fill.coin)).font(.subheadline.bold())
                    Text(fill.dirTitle).font(.caption).foregroundStyle(fill.isBuy ? Color.hlGreen : Color.hlRed)
                }
                Text("\(Fmt.num(fill.sz, m?.szDecimals ?? 4)) @ \(Fmt.price(fill.px))").font(.system(size: 12, design: .monospaced))
                Text(Fmt.dateTime(fill.time)).font(.caption2).foregroundStyle(Color.hlMuted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                if fill.closedPnl != 0 {
                    Text(Fmt.signedUsd(fill.closedPnl)).font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.pnl(fill.closedPnl))
                }
                Text(L("Fee {0} {1}", Fmt.num(fill.fee, 4), fill.feeToken)).font(.caption2).foregroundStyle(Color.hlMuted)
                Text(Fmt.usd(fill.px * fill.sz)).font(.caption2.monospaced())
            }
        }
        .padding(10)
        .themedCard()
    }
}

/// Fills of one order (or of one moment, same market and direction) shown as a single card.
struct FillGroup: Identifiable {
    let fills: [Fill]
    var id: String { fills.first?.id ?? UUID().uuidString }
    var first: Fill { fills[0] }
    var size: Double { fills.reduce(0) { $0 + $1.sz } }
    var value: Double { fills.reduce(0) { $0 + $1.px * $1.sz } }
    var avgPx: Double { size > 0 ? value / size : first.px }
    var fee: Double { fills.reduce(0) { $0 + $1.fee } }
    var closedPnl: Double { fills.reduce(0) { $0 + $1.closedPnl } }

    /// Groups time-sorted fills of the same market and direction: same order id, same client id, or
    /// within two seconds of each other.
    static let window: TimeInterval = 60

    static func group(_ fills: [Fill]) -> [FillGroup] {
        var out: [[Fill]] = []
        var groupOfOrder: [String: Int] = [:]
        func orderKey(_ f: Fill) -> String? {
            if let c = f.cloid, !c.isEmpty { return "c:" + c }
            return f.oid != 0 ? "o:\(f.oid)" : nil
        }
        for f in fills {
            let key = orderKey(f)
            // Fills of the same order join its card whatever happened in between (other markets, minutes).
            if let key, let i = groupOfOrder[key] {
                out[i].append(f)
                continue
            }
            // Otherwise: the previous card, if same market and direction and less than a minute apart.
            if let last = out.last?.last, last.coin == f.coin, last.dir == f.dir,
               abs(last.time.timeIntervalSince(f.time)) < FillGroup.window {
                out[out.count - 1].append(f)
            } else {
                out.append([f])
            }
            if let key { groupOfOrder[key] = out.count - 1 }
        }
        return out.map(FillGroup.init)
    }
}

/// A grouped fill card; tap to show the individual fills.
struct FillGroupRow: View {
    @Environment(AppModel.self) private var model
    let group: FillGroup
    @State private var expanded = false

    var body: some View {
        if group.fills.count == 1 {
            FillRow(fill: group.first)
        } else {
            let f = group.first
            let dec = model.market(f.coin)?.szDecimals ?? 4
            VStack(alignment: .leading, spacing: 8) {
                Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                                Text(model.displayName(f.coin)).font(.subheadline.bold())
                                Text(f.dirTitle).font(.caption).foregroundStyle(f.isBuy ? Color.hlGreen : Color.hlRed)
                                Badge(text: L("{0} fills", group.fills.count), color: .hlMuted)
                            }
                            Text("\(Fmt.num(group.size, dec)) @ \(Fmt.price(group.avgPx))")
                                .font(.system(size: 12, design: .monospaced))
                            Text(Fmt.dateTime(f.time)).font(.caption2).foregroundStyle(Color.hlMuted)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            if group.closedPnl != 0 {
                                Text(Fmt.signedUsd(group.closedPnl)).font(.system(size: 13, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Color.pnl(group.closedPnl))
                            }
                            Text(L("Fee {0} {1}", Fmt.num(group.fee, 4), f.feeToken)).font(.caption2).foregroundStyle(Color.hlMuted)
                            Text(Fmt.usd(group.value)).font(.caption2.monospaced())
                        }
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption2.bold()).foregroundStyle(Color.hlMuted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if expanded {
                    Divider()
                    ForEach(group.fills) { x in
                        HStack {
                            Text("\(Fmt.num(x.sz, dec)) @ \(Fmt.price(x.px))").font(.system(size: 11, design: .monospaced))
                            Spacer()
                            if x.closedPnl != 0 {
                                Text(Fmt.signedUsd(x.closedPnl)).font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Color.pnl(x.closedPnl))
                            }
                            Text(L("Fee {0}", Fmt.num(x.fee, 4))).font(.caption2).foregroundStyle(Color.hlMuted)
                            Text(Fmt.usd(x.px * x.sz)).font(.caption2.monospaced()).frame(minWidth: 70, alignment: .trailing)
                        }
                    }
                }
            }
            .padding(10)
            .themedCard()
        }
    }
}

struct TwapRow: View {
    @Environment(AppModel.self) private var model
    let twap: TwapState
    @State private var pending: PendingConfirm?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(model.displayName(twap.coin)).font(.subheadline.bold())
                SideBadge(isLong: twap.isBuy)
                Text(L("TWAP {0} min", twap.minutes)).font(.caption).foregroundStyle(Color.hlMuted)
                Spacer()
                if model.canTrade {
                    Button(L("Stop")) {
                        pending = PendingConfirm(title: L("Stop TWAP"), message: model.displayName(twap.coin), button: L("Stop")) {
                            model.perform { try await model.cancelTwap(twap); return L("TWAP stopped") }
                        }
                    }
                        .buttonStyle(.bordered).controlSize(.small).tint(.hlRed)
                }
            }
            ProgressView(value: twap.progress).tint(twap.isBuy ? .hlGreen : .hlRed)
            HStack {
                Text("\(Fmt.num(twap.executedSz, 4)) / \(Fmt.num(twap.sz, 4))")
                Spacer()
                Text(L("Avg. price {0}", Fmt.price(twap.avgPx)))
                Spacer()
                Text(L("until {0}", Fmt.time(twap.endsAt)))
            }
            .font(.system(size: 11, design: .monospaced))
        }
        .padding(10)
        .themedCard()
        .confirmDialog($pending)
    }
}

/// Compact account section under the trade screen.
struct AccountPanel: View {
    @Environment(AppModel.self) private var model
    let coin: String
    /// Shows only this tab (0 positions, 1 orders, 2 trades) without the tab picker.
    var fixedTab: Int? = nil
    @State private var tab = 0
    @State private var onlyThisCoin = false
    @State private var pending: PendingConfirm?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if fixedTab == nil {
                UnderlineTabs(items: [
                    .init(id: 0, title: L("Positions"), count: model.positions.count),
                    .init(id: 1, title: L("Orders"), count: model.openOrders.count),
                    .init(id: 2, title: L("Trades")),
                ], selection: $tab)
            }
            HStack {
                Toggle(L("Only {0}", model.displayName(coin)), isOn: $onlyThisCoin).toggleStyle(CheckToggle()).font(.caption)
                Spacer()
                if current == 1 && !orders.isEmpty && model.canTrade {
                    Button(L("Cancel all")) {
                        let c: String? = onlyThisCoin ? coin : nil
                        pending = PendingConfirm(title: L("Cancel all orders"), message: L("Orders to cancel: {0}", orders.count),
                                                 button: L("Cancel all")) {
                            model.perform { try await model.cancelAll(coin: c) }
                        }
                    }
                        .font(.caption.bold()).foregroundStyle(Color.hlRed)
                }
                if current == 0 && !model.positions.isEmpty && model.canTrade && !onlyThisCoin {
                    Button(L("Close all")) {
                        pending = PendingConfirm(title: L("Close all positions"),
                                                 message: L("Market close of all positions: {0}", model.positions.count),
                                                 button: L("Close all")) {
                            model.perform { try await model.closeAll() }
                        }
                    }
                        .font(.caption.bold()).foregroundStyle(Color.hlRed)
                }
            }
            if model.account == nil {
                EmptyState(text: L("Connect an account in Settings to see positions and trade"), icon: "person.crop.circle.badge.plus")
            } else {
                switch current {
                case 0:
                    if positions.isEmpty { EmptyState(text: L("No open positions")) }
                    ForEach(positions) { PositionRow(position: $0) }
                case 1:
                    ChaseList(coin: onlyThisCoin ? coin : nil)
                    if orders.isEmpty { EmptyState(text: L("No open orders")) }
                    ForEach(orders) { OrderRow(order: $0) }
                default:
                    let f = fills
                    if f.isEmpty { EmptyState(text: L("No trades yet")) }
                    ForEach(FillGroup.group(Array(f.prefix(200))).prefix(30)) { FillGroupRow(group: $0) }
                }
            }
        }
        .confirmDialog($pending)
    }

    private var current: Int { fixedTab ?? tab }

    private var positions: [Position] { onlyThisCoin ? model.positions.filter { $0.coin == coin } : model.positions }
    private var orders: [OpenOrder] { onlyThisCoin ? model.orders(for: coin) : model.openOrders }
    private var fills: [Fill] { onlyThisCoin ? model.fills.filter { $0.coin == coin } : model.fills }
}

/// Active chase orders with a Stop button (the order then stays as a normal limit order).
struct ChaseList: View {
    @Environment(AppModel.self) private var model
    var coin: String?

    var body: some View {
        let list = model.activeChases.filter { coin == nil || $0.coin == coin }
        ForEach(list) { c in
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text(model.displayName(c.coin)).font(.subheadline.bold())
                        SideBadge(isLong: c.isBuy, spot: model.market(c.coin)?.isSpot ?? false)
                        Badge(text: L("Chase"), color: .hlAccent)
                        if c.reduceOnly { Badge(text: "RO", color: .hlMuted) }
                    }
                    Text(L("Price {0}", Fmt.price(c.price)) + " · " + Fmt.num(c.size, model.market(c.coin)?.szDecimals ?? 4))
                        .font(.system(size: 11, design: .monospaced))
                }
                Spacer()
                ProgressView().controlSize(.small)
                Button(L("Stop")) { model.stopChase(c.id) }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            .padding(10)
            .themedCard()
        }
    }
}
