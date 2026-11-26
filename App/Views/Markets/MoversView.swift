import SwiftUI

/// Market scanner: biggest moves over 5 m / 15 m / 1 h / 24 h (price or open interest), gainers or losers,
/// with a minimum 24 h volume so illiquid markets don't fill the list.
struct MoversView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("moversWindow") private var windowRaw = MoverWindow.h1.rawValue
    @AppStorage("moversGainers") private var gainers = true
    @AppStorage("moversMetric") private var metric = 0          // 0 price, 1 open interest
    @AppStorage("moversScope") private var scope = 0            // 0 perps, 1 HIP-3, 2 spot, 3 all
    @AppStorage("moversMinVolume") private var minVolume = 1_000_000.0

    private var window: MoverWindow { MoverWindow(rawValue: windowRaw) ?? .h1 }

    var body: some View {
        _ = model.priceHistoryVersion   // refresh when a new snapshot arrives
        let rows = ranked
        let wait = metric == 1 ? model.moverWaitSeconds(window == .h24 ? .h1 : window) : model.moverWaitSeconds(window)
        return List {
            Section {
                Picker("", selection: $windowRaw) {
                    ForEach(MoverWindow.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                HStack {
                    Picker("", selection: $gainers) {
                        Text(L("Gainers")).tag(true)
                        Text(L("Losers")).tag(false)
                    }
                    .pickerStyle(.segmented)
                    Picker("", selection: $metric) {
                        Text(L("Price")).tag(0)
                        Text("OI").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 110)
                }
                HStack {
                    Menu {
                        Picker(L("Markets"), selection: $scope) {
                            Text(L("Perps")).tag(0)
                            Text("HIP-3").tag(1)
                            Text(L("Spot")).tag(2)
                            Text(L("All")).tag(3)
                        }
                    } label: {
                        Label(scopeTitle, systemImage: "line.3.horizontal.decrease.circle").font(.caption)
                    }
                    Spacer()
                    Menu {
                        Picker(L("Min. 24h volume"), selection: $minVolume) {
                            Text(L("Any")).tag(0.0)
                            Text("$100K").tag(100_000.0)
                            Text("$1M").tag(1_000_000.0)
                            Text("$10M").tag(10_000_000.0)
                            Text("$100M").tag(100_000_000.0)
                        }
                    } label: {
                        Label(minVolume > 0 ? L("Vol ≥ {0}", Fmt.compactUsd(minVolume)) : L("Any volume"), systemImage: "chart.bar")
                            .font(.caption)
                    }
                }
            }
            .listRowBackground(Color.hlCard)

            if wait > 0 {
                Section {
                    Label(L("Collecting prices: the {0} change is available in about {1} min. Keep the app open; the history survives short trips to the background.",
                            metric == 1 && window == .h24 ? "1h" : window.rawValue, Int(ceil(wait / 60))),
                          systemImage: "hourglass")
                        .font(.caption).foregroundStyle(Color.hlMuted)
                }
                .listRowBackground(Color.hlCard)
            }

            Section {
                ForEach(Array(rows.prefix(50).enumerated()), id: \.element.0.id) { i, row in
                    let (m, change) = row
                    Button { model.select(m.id) } label: {
                        HStack(spacing: 10) {
                            Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(Color.hlMuted).frame(width: 22, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.name).font(.subheadline.bold())
                                Text(metric == 1 ? L("OI {0}", Fmt.compactUsd(m.openInterestUsd)) : L("Vol {0}", Fmt.compactUsd(m.dayNtlVlm)))
                                    .font(.caption2).foregroundStyle(Color.hlMuted)
                            }
                            Spacer()
                            Text(Fmt.price(model.lastPrice(m.id))).font(.system(size: 13, design: .monospaced))
                            Text(Fmt.pct(change, 2))
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .foregroundStyle(change >= 0 ? Color.hlGreen : Color.hlRed)
                                .frame(width: 82, alignment: .trailing)
                        }
                    }
                    .buttonStyle(.plain)
                }
                if rows.isEmpty && wait == 0 {
                    EmptyState(text: L("Nothing found"), icon: "magnifyingglass")
                }
            }
            .listRowBackground(Color.hlBg)
        }
        .scrollContentBackground(.hidden)
        .themedBackground()
        .navigationTitle(L("Movers"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var scopeTitle: String {
        switch scope {
        case 1: return "HIP-3"
        case 2: return L("Spot")
        case 3: return L("All")
        default: return L("Perps")
        }
    }

    private var ranked: [(Market, Double)] {
        let base: [Market]
        switch scope {
        case 1: base = model.hip3
        case 2: base = model.spots
        case 3: base = model.perps + model.hip3 + model.spots
        default: base = model.perps
        }
        let list: [(Market, Double)] = base.compactMap { m0 in
            let m = model.marketById[m0.id] ?? m0
            guard m.dayNtlVlm >= minVolume else { return nil }
            let c = metric == 1 ? (m.isSpot ? nil : model.oiChange(m, window)) : model.priceChange(m, window)
            guard let c, c.isFinite else { return nil }
            return (m, c)
        }
        return list.sorted { gainers ? $0.1 > $1.1 : $0.1 < $1.1 }
    }
}
