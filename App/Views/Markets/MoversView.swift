import SwiftUI

/// Market scanner: biggest 24 h gainers / losers (from the exchange's day-ago price), with a minimum 24 h volume
/// so illiquid markets don't fill the list.
struct MoversView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("moversGainers") private var gainers = true
    @AppStorage("moversScope") private var scope = 0            // 0 perps, 1 HIP-3, 2 spot, 3 all
    @AppStorage("moversMinVolume") private var minVolume = 1_000_000.0

    var body: some View {
        let rows = ranked
        List {
            Section {
                Picker("", selection: $gainers) {
                    Text(L("Gainers")).tag(true)
                    Text(L("Losers")).tag(false)
                }
                .pickerStyle(.segmented)
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

            Section {
                ForEach(Array(rows.prefix(50).enumerated()), id: \.element.id) { i, m in
                    Button { model.select(m.id) } label: {
                        HStack(spacing: 10) {
                            Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(Color.hlMuted).frame(width: 22, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.name).font(.subheadline.bold())
                                Text(L("Vol {0}", Fmt.compactUsd(m.dayNtlVlm))).font(.caption2).foregroundStyle(Color.hlMuted)
                            }
                            Spacer()
                            Text(Fmt.price(model.lastPrice(m.id))).font(.system(size: 13, design: .monospaced))
                            Text(Fmt.pct(change(m), 2))
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .foregroundStyle(change(m) >= 0 ? Color.hlGreen : Color.hlRed)
                                .frame(width: 82, alignment: .trailing)
                        }
                    }
                    .buttonStyle(.plain)
                }
                if rows.isEmpty && model.metaLoaded {
                    EmptyState(text: L("Nothing found"), icon: "magnifyingglass")
                }
            } header: {
                Text(L("24h change"))
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

    /// 24 h change at the live price (the day-ago price from the exchange vs. now).
    private func change(_ m: Market) -> Double {
        let px = model.lastPrice(m.id)
        return m.prevDayPx > 0 && px > 0 ? px / m.prevDayPx - 1 : m.change24h
    }

    private var ranked: [Market] {
        let base: [Market]
        switch scope {
        case 1: base = model.hip3
        case 2: base = model.spots
        case 3: base = model.perps + model.hip3 + model.spots
        default: base = model.perps
        }
        let list = base.map { model.marketById[$0.id] ?? $0 }.filter { $0.dayNtlVlm >= minVolume && $0.prevDayPx > 0 }
        return list.sorted { gainers ? change($0) > change($1) : change($0) < change($1) }
    }
}
