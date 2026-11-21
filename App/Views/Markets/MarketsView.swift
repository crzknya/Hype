import SwiftUI

struct MarketsView: View {
    @Environment(AppModel.self) private var model
    @State private var segment: Segment = .perps
    @State private var search = ""
    @State private var sort: SortKey = .volume
    @State private var descending = true
    @State private var category: String?

    enum Segment: String, CaseIterable, Identifiable {
        case favorites = "★", perps = "Perps", hip3 = "HIP-3", spot = "Spot"
        var id: String { rawValue }
    }

    enum SortKey: String, CaseIterable, Identifiable {
        case volume = "24h Volume", change = "Change", funding = "Funding", oi = "Open Interest", name = "Name", price = "Price"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $segment) {
                    ForEach(Segment.allCases) { Text(L($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                if segment == .hip3 && search.isEmpty && !availableCategories.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            categoryChip(nil, L("All"))
                            ForEach(availableCategories) { c in categoryChip(c.rawValue, c.title) }
                        }
                        .padding(.horizontal)
                    }
                    .padding(.bottom, 6)
                }

                MarketList(markets: list, onSelect: { model.select($0.id) })
            }
            .themedBackground()
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: L("Search coin"))
            .navigationTitle(L("Markets"))
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
                        Picker(L("Sort"), selection: $sort) {
                            ForEach(SortKey.allCases) { Text(L($0.rawValue)).tag($0) }
                        }
                        Toggle(L("Descending"), isOn: $descending)
                    } label: {
                        Image(systemName: "arrow.up.arrow.down.circle")
                    }
                }
            }
            .refreshable { await model.refreshMarkets() }
            .overlay {
                if !model.metaLoaded { ProgressView(L("Loading markets…")) }
            }
        }
    }

    private var availableCategories: [MarketCategory] {
        let present = Set(model.hip3.compactMap { model.categories[$0.id] })
        return MarketCategory.allCases.filter { present.contains($0.rawValue) }
    }

    private func categoryChip(_ value: String?, _ title: String) -> some View {
        Button { category = value } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(category == value ? Color.hlAccent.opacity(0.2) : Color.hlCard, in: Capsule())
                .foregroundStyle(category == value ? Color.hlAccent : .primary)
        }
        .buttonStyle(.plain)
    }

    private var list: [Market] {
        var base: [Market]
        let q = search.trimmingCharacters(in: .whitespaces).uppercased()
        if !q.isEmpty {
            // Search across all markets regardless of the selected segment.
            let all: [Market] = model.perps + model.hip3 + model.spots
            base = all.map { model.marketById[$0.id] ?? $0 }.filter { $0.name.uppercased().contains(q) || $0.id.uppercased().contains(q) }
        } else {
            switch segment {
            case .perps: base = model.perps.map { model.marketById[$0.id] ?? $0 }
            case .hip3:
                base = model.hip3.map { model.marketById[$0.id] ?? $0 }
                if let category { base = base.filter { model.categories[$0.id] == category } }
            case .spot: base = model.spots.map { model.marketById[$0.id] ?? $0 }.filter { $0.dayNtlVlm > 0 }
            case .favorites: base = model.favorites.compactMap { model.marketById[$0] }
            }
        }
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
                Text(L("Coin / Volume")).frame(maxWidth: .infinity, alignment: .leading)
                Text(L("Price")).frame(width: 100, alignment: .trailing)
                Text(L("24h")).frame(width: 76, alignment: .trailing)
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
                EmptyState(text: L("Nothing found"), icon: "magnifyingglass").listRowBackground(Color.hlBg)
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
                    if market.isHip3 { Badge(text: market.dex, color: .orange) }
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
    @State private var kind = 0   // 0 perps, 1 HIP-3, 2 spot

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $kind) {
                    Text(L("Perps")).tag(0)
                    Text("HIP-3").tag(1)
                    Text(L("Spot")).tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal).padding(.vertical, 8)
                MarketList(markets: list) { m in
                    model.select(m.id, openTrade: false)
                    dismiss()
                }
            }
            .themedBackground()
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: L("Search"))
            .navigationTitle(L("Select market"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Close")) { dismiss() } } }
        }
    }

    var list: [Market] {
        let q = search.uppercased()
        let source: [Market] = q.isEmpty ? [model.perps, model.hip3, model.spots][kind] : model.perps + model.hip3 + model.spots
        let base: [Market] = source.map { model.marketById[$0.id] ?? $0 }
        let filtered: [Market] = q.isEmpty ? base.filter { kind != 2 || $0.dayNtlVlm > 0 } : base.filter { $0.name.uppercased().contains(q) || $0.id.uppercased().contains(q) }
        let favs = filtered.filter { model.favorites.contains($0.id) }.sorted { $0.dayNtlVlm > $1.dayNtlVlm }
        let rest = filtered.filter { !model.favorites.contains($0.id) }.sorted { $0.dayNtlVlm > $1.dayNtlVlm }
        return favs + rest
    }
}
