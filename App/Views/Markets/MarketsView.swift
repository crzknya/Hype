import SwiftUI

struct MarketsView: View {
    @Environment(AppModel.self) private var model
    @State private var segment: Segment = .perps
    @State private var search = ""
    @State private var sort: SortKey = .volume
    @State private var descending = true

    enum Segment: String, CaseIterable, Identifiable {
        case favorites = "★", perps = "Перпы", spot = "Спот"
        var id: String { rawValue }
    }

    enum SortKey: String, CaseIterable, Identifiable {
        case volume = "Объём 24ч", change = "Изменение", funding = "Фандинг", oi = "Открытый интерес", name = "Название", price = "Цена"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $segment) {
                    ForEach(Segment.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                MarketList(markets: list, onSelect: { model.select($0.id) })
            }
            .background(Color.hlBg)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Поиск монеты")
            .navigationTitle("Рынки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 6) {
                        ConnectionDot(connected: model.wsConnected)
                        Text(model.network.title).font(.caption).foregroundStyle(Color.hlMuted)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Сортировка", selection: $sort) {
                            ForEach(SortKey.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Toggle("По убыванию", isOn: $descending)
                    } label: {
                        Image(systemName: "arrow.up.arrow.down.circle")
                    }
                }
            }
            .refreshable { await model.refreshMarkets() }
            .overlay {
                if !model.metaLoaded { ProgressView("Загрузка рынков…") }
            }
        }
    }

    private var list: [Market] {
        var base: [Market]
        switch segment {
        case .perps: base = model.perps.map { model.marketById[$0.id] ?? $0 }
        case .spot: base = model.spots.map { model.marketById[$0.id] ?? $0 }.filter { $0.dayNtlVlm > 0 || !search.isEmpty }
        case .favorites: base = model.favorites.compactMap { model.marketById[$0] }
        }
        let q = search.trimmingCharacters(in: .whitespaces).uppercased()
        if !q.isEmpty { base = base.filter { $0.name.uppercased().contains(q) || $0.id.uppercased().contains(q) } }
        let sorted: [Market]
        switch sort {
        case .volume: sorted = base.sorted { $0.dayNtlVlm < $1.dayNtlVlm }
        case .change: sorted = base.sorted { $0.change24h < $1.change24h }
        case .funding: sorted = base.sorted { $0.funding < $1.funding }
        case .oi: sorted = base.sorted { $0.openInterestUsd < $1.openInterestUsd }
        case .name: sorted = base.sorted { $0.name > $1.name }
        case .price: sorted = base.sorted { $0.markPx < $1.markPx }
        }
        return descending ? sorted.reversed() : sorted
    }
}

struct MarketList: View {
    @Environment(AppModel.self) private var model
    let markets: [Market]
    let onSelect: (Market) -> Void

    var body: some View {
        List {
            HStack {
                Text("Монета / Объём").frame(maxWidth: .infinity, alignment: .leading)
                Text("Цена").frame(width: 100, alignment: .trailing)
                Text("24ч").frame(width: 76, alignment: .trailing)
            }
            .font(.caption2)
            .foregroundStyle(Color.hlMuted)
            .listRowBackground(Color.hlBg)

            ForEach(markets) { m in
                MarketRow(market: m)
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(m) }
                    .listRowBackground(Color.hlBg)
                    .swipeActions(edge: .leading) {
                        Button { model.toggleFavorite(m.id) } label: {
                            Image(systemName: model.favorites.contains(m.id) ? "star.slash" : "star")
                        }
                        .tint(.yellow)
                    }
            }
            if markets.isEmpty && model.metaLoaded {
                EmptyState(text: "Ничего не найдено", icon: "magnifyingglass").listRowBackground(Color.hlBg)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

struct MarketRow: View {
    @Environment(AppModel.self) private var model
    let market: Market

    var body: some View {
        let px = model.mid(market.id)
        let change = market.prevDayPx > 0 && px > 0 ? px / market.prevDayPx - 1 : market.change24h
        HStack(spacing: 8) {
            Button { model.toggleFavorite(market.id) } label: {
                Image(systemName: model.favorites.contains(market.id) ? "star.fill" : "star")
                    .font(.caption)
                    .foregroundStyle(model.favorites.contains(market.id) ? .yellow : Color.hlMuted)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(market.name).font(.system(size: 15, weight: .semibold))
                    if !market.isSpot { Badge(text: "\(market.maxLeverage)x") }
                }
                HStack(spacing: 6) {
                    Text(Fmt.compactUsd(market.dayNtlVlm)).font(.caption2).foregroundStyle(Color.hlMuted)
                    if !market.isSpot {
                        Text("F " + Fmt.pct(market.funding, 4))
                            .font(.caption2).foregroundStyle(market.funding >= 0 ? Color.hlGreen.opacity(0.8) : Color.hlRed.opacity(0.8))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(Fmt.price(px))
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .lineLimit(1).minimumScaleFactor(0.6)
                .frame(width: 100, alignment: .trailing)
            ChangePill(value: change).frame(width: 76, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }
}

/// Sheet for picking the active market from the trade screen.
struct MarketPickerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var spot = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $spot) {
                    Text("Перпы").tag(false)
                    Text("Спот").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal).padding(.vertical, 8)
                MarketList(markets: list) { m in
                    model.select(m.id, openTrade: false)
                    dismiss()
                }
            }
            .background(Color.hlBg)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Поиск")
            .navigationTitle("Выбор рынка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
        }
    }

    var list: [Market] {
        let base = (spot ? model.spots : model.perps).map { model.marketById[$0.id] ?? $0 }
        let q = search.uppercased()
        let filtered = q.isEmpty ? base.filter { !spot || $0.dayNtlVlm > 0 } : base.filter { $0.name.uppercased().contains(q) }
        let favs = filtered.filter { model.favorites.contains($0.id) }.sorted { $0.dayNtlVlm > $1.dayNtlVlm }
        let rest = filtered.filter { !model.favorites.contains($0.id) }.sorted { $0.dayNtlVlm > $1.dayNtlVlm }
        return favs + rest
    }
}
