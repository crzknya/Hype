import SwiftUI
import HyperCore

struct PositionRow: View {
    @Environment(AppModel.self) private var model
    let position: Position
    @State private var sheet: PositionSheet?

    enum PositionSheet: String, Identifiable {
        case close, tpsl, margin
        var id: String { rawValue }
    }

    var body: some View {
        let p = position
        let m = model.market(p.coin)
        let mark = model.mid(p.coin)
        let tpsl = model.openOrders.filter { $0.coin == p.coin && $0.isTrigger && $0.reduceOnly }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(model.displayName(p.coin)).font(.headline)
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
                    Stat(title: "Размер", value: "\(Fmt.num(p.size, m?.szDecimals ?? 4))")
                    Stat(title: "Стоимость", value: Fmt.usd(p.positionValue))
                    Stat(title: "Маржа", value: Fmt.usd(p.marginUsed))
                }
                GridRow {
                    Stat(title: "Вход", value: Fmt.price(p.entryPx))
                    Stat(title: "Марк", value: Fmt.price(mark))
                    Stat(title: "Ликвидация", value: p.liquidationPx.map { Fmt.price($0) } ?? "—", color: .orange)
                }
                GridRow {
                    Stat(title: "Фандинг", value: Fmt.signedUsd(-p.fundingSinceOpen), color: Color.pnl(-p.fundingSinceOpen))
                    Stat(title: "TP", value: tpsl.first { $0.orderType.hasPrefix("Take") }.map { Fmt.price($0.triggerPx) } ?? "—", color: .hlGreen)
                    Stat(title: "SL", value: tpsl.first { $0.orderType.hasPrefix("Stop") }.map { Fmt.price($0.triggerPx) } ?? "—", color: .hlRed)
                }
            }
            if model.canTrade {
                HStack(spacing: 6) {
                    actionButton("Закрыть", color: .hlRed) { confirmClose(1) }
                    actionButton("50%") { confirmClose(0.5) }
                    actionButton("Лимит") { sheet = .close }
                    actionButton("TP/SL") { sheet = .tpsl }
                    Menu {
                        Button("Закрыть 25%") { confirmClose(0.25) }
                        Button("Развернуть позицию") {
                            model.perform { try await model.reverse(p) }
                        }
                        if p.leverageType == "isolated" { Button("Изменить маржу") { sheet = .margin } }
                        Button("Открыть график") { model.select(p.coin) }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 34, height: 30)
                            .background(Color.hlCard2, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
        .padding(12)
        .background(Color.hlCard, in: RoundedRectangle(cornerRadius: 12))
        .sheet(item: $sheet) { s in
            switch s {
            case .close: ClosePositionSheet(position: p)
            case .tpsl: TpslSheet(position: p)
            case .margin: MarginSheet(position: p)
            }
        }
    }

    private func confirmClose(_ fraction: Double) {
        model.perform { try await model.closePosition(position, fraction: fraction) }
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
                        Text("Триггер \(o.triggerCondition.isEmpty ? Fmt.price(o.triggerPx) : o.triggerCondition)")
                    }
                    if !o.orderType.contains("Market") { Text("Цена \(Fmt.price(o.limitPx))") }
                }
                .font(.system(size: 11, design: .monospaced))
                HStack(spacing: 10) {
                    Text("\(Fmt.num(o.origSz - o.sz, m?.szDecimals ?? 4)) / \(o.sz == 0 ? "позиция" : Fmt.num(o.origSz, m?.szDecimals ?? 4))")
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
        .background(Color.hlCard, in: RoundedRectangle(cornerRadius: 10))
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
                Text("Комиссия \(Fmt.num(fill.fee, 4)) \(fill.feeToken)").font(.caption2).foregroundStyle(Color.hlMuted)
                Text(Fmt.usd(fill.px * fill.sz)).font(.caption2.monospaced())
            }
        }
        .padding(10)
        .background(Color.hlCard, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct TwapRow: View {
    @Environment(AppModel.self) private var model
    let twap: TwapState
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(model.displayName(twap.coin)).font(.subheadline.bold())
                SideBadge(isLong: twap.isBuy)
                Text("TWAP \(twap.minutes) мин").font(.caption).foregroundStyle(Color.hlMuted)
                Spacer()
                if model.canTrade {
                    Button("Стоп") { model.perform { try await model.cancelTwap(twap); return "TWAP остановлен" } }
                        .buttonStyle(.bordered).controlSize(.small).tint(.hlRed)
                }
            }
            ProgressView(value: twap.progress).tint(twap.isBuy ? .hlGreen : .hlRed)
            HStack {
                Text("\(Fmt.num(twap.executedSz, 4)) / \(Fmt.num(twap.sz, 4))")
                Spacer()
                Text("Ср. цена \(Fmt.price(twap.avgPx))")
                Spacer()
                Text("до \(Fmt.time(twap.endsAt))")
            }
            .font(.system(size: 11, design: .monospaced))
        }
        .padding(10)
        .background(Color.hlCard, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Compact account section under the trade screen.
struct AccountPanel: View {
    @Environment(AppModel.self) private var model
    let coin: String
    @State private var tab = 0
    @State private var onlyThisCoin = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $tab) {
                Text("Позиции (\(model.positions.count))").tag(0)
                Text("Ордера (\(model.openOrders.count))").tag(1)
                Text("Сделки").tag(2)
            }
            .pickerStyle(.segmented)
            HStack {
                Toggle("Только \(model.displayName(coin))", isOn: $onlyThisCoin).toggleStyle(CheckToggle()).font(.caption)
                Spacer()
                if tab == 1 && !orders.isEmpty && model.canTrade {
                    Button("Отменить все") { model.perform { try await model.cancelAll(coin: onlyThisCoin ? coin : nil) } }
                        .font(.caption.bold()).foregroundStyle(Color.hlRed)
                }
                if tab == 0 && !model.positions.isEmpty && model.canTrade && !onlyThisCoin {
                    Button("Закрыть все") { model.perform { try await model.closeAll() } }
                        .font(.caption.bold()).foregroundStyle(Color.hlRed)
                }
            }
            if model.account == nil {
                EmptyState(text: "Подключите аккаунт в Настройках, чтобы видеть позиции и торговать", icon: "person.crop.circle.badge.plus")
            } else {
                switch tab {
                case 0:
                    if positions.isEmpty { EmptyState(text: "Нет открытых позиций") }
                    ForEach(positions) { PositionRow(position: $0) }
                case 1:
                    if orders.isEmpty { EmptyState(text: "Нет открытых ордеров") }
                    ForEach(orders) { OrderRow(order: $0) }
                default:
                    let f = fills
                    if f.isEmpty { EmptyState(text: "Сделок пока нет") }
                    ForEach(f.prefix(30)) { FillRow(fill: $0) }
                }
            }
        }
    }

    private var positions: [Position] { onlyThisCoin ? model.positions.filter { $0.coin == coin } : model.positions }
    private var orders: [OpenOrder] { onlyThisCoin ? model.orders(for: coin) : model.openOrders }
    private var fills: [Fill] { onlyThisCoin ? model.fills.filter { $0.coin == coin } : model.fills }
}
