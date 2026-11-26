import Foundation

/// Prices (and perp open interest) of every market, sampled every 30 s for the last hour: the market scanner
/// computes 5 m / 15 m / 1 h moves from it (the API has no bulk short-window change). Kept on disk so a short
/// trip to the background doesn't empty it.
struct PriceSnapshot: Codable {
    let t: Date
    let px: [String: Double]
    let oi: [String: Double]
}

enum MoverWindow: String, CaseIterable, Identifiable {
    case m5 = "5m", m15 = "15m", h1 = "1h", h24 = "24h"
    var id: String { rawValue }
    var seconds: TimeInterval {
        switch self {
        case .m5: return 300
        case .m15: return 900
        case .h1: return 3600
        case .h24: return 86400
        }
    }
}

extension AppModel {
    static let priceHistoryLimit: TimeInterval = 65 * 60

    private static var priceHistoryURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("priceHistory.json")
    }

    static func loadPriceHistory() -> [PriceSnapshot] {
        guard let url = priceHistoryURL, let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([PriceSnapshot].self, from: data) else { return [] }
        let cutoff = Date().addingTimeInterval(-priceHistoryLimit)
        return list.filter { $0.t >= cutoff }
    }

    func savePriceHistory() {
        guard let url = Self.priceHistoryURL, let data = try? JSONEncoder().encode(priceHistory) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func recordPriceSnapshot() {
        guard !mids.isEmpty else { return }
        var oi: [String: Double] = [:]
        for m in perps + hip3 { if let live = marketById[m.id], live.openInterestUsd > 0 { oi[m.id] = live.openInterestUsd } }
        priceHistory.append(PriceSnapshot(t: Date(), px: mids, oi: oi))
        let cutoff = Date().addingTimeInterval(-Self.priceHistoryLimit)
        priceHistory.removeAll { $0.t < cutoff }
        priceHistoryVersion += 1
    }

    /// Snapshot taken closest to (and not after) `seconds` ago, if the history reaches that far.
    private func snapshot(ago seconds: TimeInterval) -> PriceSnapshot? {
        let target = Date().addingTimeInterval(-seconds)
        guard let s = priceHistory.last(where: { $0.t <= target }), target.timeIntervalSince(s.t) < 150 else { return nil }
        return s
    }

    /// Seconds until a window has data (0 = ready).
    func moverWaitSeconds(_ w: MoverWindow) -> TimeInterval {
        guard w != .h24 else { return 0 }
        guard let first = priceHistory.first else { return w.seconds }
        return max(0, w.seconds - Date().timeIntervalSince(first.t))
    }

    /// Price change over the window (24 h from the exchange; shorter windows from the local history).
    func priceChange(_ m: Market, _ w: MoverWindow) -> Double? {
        if w == .h24 { return m.change24h }
        let now = lastPrice(m.id)
        guard now > 0, let s = snapshot(ago: w.seconds), let old = s.px[m.id], old > 0 else { return nil }
        return now / old - 1
    }

    /// Open-interest change over the window (perps), from the local history.
    func oiChange(_ m: Market, _ w: MoverWindow) -> Double? {
        let w2 = w == .h24 ? MoverWindow.h1 : w
        guard let s = snapshot(ago: w2.seconds), let old = s.oi[m.id], old > 0 else { return nil }
        let now = marketById[m.id]?.openInterestUsd ?? m.openInterestUsd
        return now > 0 ? now / old - 1 : nil
    }
}
