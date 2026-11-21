import Foundation
import SwiftUI

enum IndicatorKind: String, Codable, CaseIterable, Identifiable {
    case ema, sma, bollinger, vwap, rsi, macd, stochastic, volumeProfile
    var id: String { rawValue }

    var title: String {
        switch self {
        case .ema: return "EMA"
        case .sma: return "SMA"
        case .bollinger: return L("Bollinger Bands")
        case .vwap: return "VWAP"
        case .rsi: return "RSI"
        case .macd: return "MACD"
        case .stochastic: return L("Stochastic")
        case .volumeProfile: return L("Volume Profile")
        }
    }

    /// Drawn in its own pane under the price chart.
    var isPane: Bool { self == .rsi || self == .macd || self == .stochastic }
}

/// A user-configured indicator instance. Several instances of the same kind are allowed.
struct IndicatorConfig: Identifiable, Codable, Hashable {
    var id = UUID()
    var kind: IndicatorKind
    var p1: Int          // main period (EMA/SMA/BB/RSI length, MACD fast, Stoch %K)
    var p2: Int = 0      // MACD slow, Stoch %K smoothing
    var p3: Int = 0      // MACD signal, Stoch %D
    var mult: Double = 2 // Bollinger std-dev multiplier
    var upper: Double = 70   // RSI / Stoch overbought
    var lower: Double = 30   // RSI / Stoch oversold
    var color: Int = 0
    var visible = true

    static func make(_ kind: IndicatorKind, color: Int) -> IndicatorConfig {
        switch kind {
        case .ema: return IndicatorConfig(kind: kind, p1: 20, color: color)
        case .sma: return IndicatorConfig(kind: kind, p1: 50, color: color)
        case .bollinger: return IndicatorConfig(kind: kind, p1: 20, mult: 2, color: color)
        case .vwap: return IndicatorConfig(kind: kind, p1: 0, color: color)
        case .rsi: return IndicatorConfig(kind: kind, p1: 14, upper: 70, lower: 30, color: color)
        case .macd: return IndicatorConfig(kind: kind, p1: 12, p2: 26, p3: 9, color: color)
        case .stochastic: return IndicatorConfig(kind: kind, p1: 14, p2: 3, p3: 3, upper: 80, lower: 20, color: color)
        case .volumeProfile: return IndicatorConfig(kind: kind, p1: 40, p2: 30, upper: 70, color: color)
        }
    }

    static let defaults: [IndicatorConfig] = [
        IndicatorConfig(kind: .ema, p1: 20, color: 0),
        IndicatorConfig(kind: .ema, p1: 50, color: 1),
        IndicatorConfig(kind: .ema, p1: 200, color: 2, visible: false),
        IndicatorConfig(kind: .bollinger, p1: 20, mult: 2, color: 3, visible: false),
        IndicatorConfig(kind: .vwap, p1: 0, color: 4, visible: false),
        IndicatorConfig(kind: .rsi, p1: 14, color: 5, visible: false),
        IndicatorConfig(kind: .macd, p1: 12, p2: 26, p3: 9, color: 0, visible: false),
        IndicatorConfig(kind: .volumeProfile, p1: 40, p2: 30, upper: 70, color: 4, visible: false),
    ]

    var label: String {
        switch kind {
        case .ema, .sma, .rsi: return "\(kind.title) \(p1)"
        case .bollinger: return "BB \(p1), \(Fmt.input(mult, 1))"
        case .vwap: return "VWAP"
        case .macd: return "MACD \(p1), \(p2), \(p3)"
        case .stochastic: return "Stoch \(p1), \(p2), \(p3)"
        case .volumeProfile: return "VPVR \(p1)"
        }
    }
}

enum IndicatorPalette {
    static let colors: [Color] = [
        Color(red: 0.98, green: 0.80, blue: 0.25),   // yellow
        Color(red: 0.36, green: 0.62, blue: 1.00),   // blue
        Color(red: 0.86, green: 0.45, blue: 0.95),   // purple
        Color(red: 0.55, green: 0.85, blue: 0.95),   // cyan
        Color(red: 1.00, green: 0.55, blue: 0.25),   // orange
        Color(red: 0.95, green: 0.45, blue: 0.65),   // pink
        Color(red: 0.60, green: 0.90, blue: 0.45),   // lime
        Color.primary,                               // white (black in the light theme)
    ]
    static func color(_ i: Int) -> Color { colors[((i % colors.count) + colors.count) % colors.count] }
}

/// Technical analysis math. All outputs are aligned with the input (nil where not enough data).
enum TA {
    static func sma(_ x: [Double], _ n: Int) -> [Double?] {
        guard n > 0 else { return x.map { _ in nil } }
        var out = [Double?](repeating: nil, count: x.count)
        var sum = 0.0
        for i in 0..<x.count {
            sum += x[i]
            if i >= n { sum -= x[i - n] }
            if i >= n - 1 { out[i] = sum / Double(n) }
        }
        return out
    }

    static func ema(_ x: [Double], _ n: Int) -> [Double?] {
        guard n > 0, x.count >= n else { return x.map { _ in nil } }
        var out = [Double?](repeating: nil, count: x.count)
        let k = 2.0 / Double(n + 1)
        var prev = x[0..<n].reduce(0, +) / Double(n)
        out[n - 1] = prev
        for i in n..<x.count {
            prev = x[i] * k + prev * (1 - k)
            out[i] = prev
        }
        return out
    }

    /// EMA over a series that starts with nils.
    static func ema(_ x: [Double?], _ n: Int) -> [Double?] {
        guard let start = x.firstIndex(where: { $0 != nil }) else { return x }
        let vals: [Double] = x[start...].map { $0 ?? 0 }
        let e = ema(vals, n)
        return [Double?](repeating: nil, count: start) + e
    }

    static func bollinger(_ x: [Double], _ n: Int, _ k: Double) -> (mid: [Double?], up: [Double?], low: [Double?]) {
        let mid = sma(x, n)
        var up = [Double?](repeating: nil, count: x.count)
        var low = [Double?](repeating: nil, count: x.count)
        guard n > 1 else { return (mid, up, low) }
        for i in 0..<x.count {
            guard let m = mid[i] else { continue }
            var v = 0.0
            for j in (i - n + 1)...i { v += (x[j] - m) * (x[j] - m) }
            let sd = (v / Double(n)).squareRoot()
            up[i] = m + k * sd
            low[i] = m - k * sd
        }
        return (mid, up, low)
    }

    /// VWAP that resets every UTC day for intraday candles, cumulative otherwise.
    static func vwap(_ c: [Candle], intervalSeconds: Double) -> [Double?] {
        var out = [Double?](repeating: nil, count: c.count)
        var pv = 0.0, vol = 0.0
        var day = -1
        for (i, k) in c.enumerated() {
            let d = Int(k.t / 86_400_000)
            if intervalSeconds < 86_400 && d != day { pv = 0; vol = 0; day = d }
            let tp = (k.h + k.l + k.c) / 3
            pv += tp * k.v
            vol += k.v
            out[i] = vol > 0 ? pv / vol : tp
        }
        return out
    }

    /// Wilder's RSI.
    static func rsi(_ x: [Double], _ n: Int) -> [Double?] {
        var out = [Double?](repeating: nil, count: x.count)
        guard n > 0, x.count > n else { return out }
        var gain = 0.0, loss = 0.0
        for i in 1...n {
            let d = x[i] - x[i - 1]
            if d > 0 { gain += d } else { loss -= d }
        }
        gain /= Double(n); loss /= Double(n)
        out[n] = loss == 0 ? 100 : 100 - 100 / (1 + gain / loss)
        if x.count > n + 1 {
            for i in (n + 1)..<x.count {
                let d = x[i] - x[i - 1]
                gain = (gain * Double(n - 1) + max(d, 0)) / Double(n)
                loss = (loss * Double(n - 1) + max(-d, 0)) / Double(n)
                out[i] = loss == 0 ? 100 : 100 - 100 / (1 + gain / loss)
            }
        }
        return out
    }

    static func macd(_ x: [Double], _ fast: Int, _ slow: Int, _ signal: Int) -> (macd: [Double?], signal: [Double?], hist: [Double?]) {
        let f = ema(x, fast), s = ema(x, slow)
        let m: [Double?] = zip(f, s).map { a, b in
            guard let a, let b else { return nil }
            return a - b
        }
        let sig = ema(m, signal)
        let h: [Double?] = zip(m, sig).map { a, b in
            guard let a, let b else { return nil }
            return a - b
        }
        return (m, sig, h)
    }

    static func stochastic(_ c: [Candle], _ n: Int, _ smoothK: Int, _ d: Int) -> (k: [Double?], d: [Double?]) {
        var raw = [Double?](repeating: nil, count: c.count)
        if n > 0 && c.count >= n {
            for i in (n - 1)..<c.count {
                var hi = -Double.infinity, lo = Double.infinity
                for j in (i - n + 1)...i { hi = max(hi, c[j].h); lo = min(lo, c[j].l) }
                raw[i] = hi > lo ? (c[i].c - lo) / (hi - lo) * 100 : 50
            }
        }
        let k = smaOpt(raw, max(1, smoothK))
        return (k, smaOpt(k, max(1, d)))
    }

    static func smaOpt(_ x: [Double?], _ n: Int) -> [Double?] {
        guard let start = x.firstIndex(where: { $0 != nil }) else { return x }
        let vals: [Double] = x[start...].map { $0 ?? 0 }
        return [Double?](repeating: nil, count: start) + sma(vals, n)
    }
}

// MARK: - Chart model

struct ChartSeries {
    let values: [Double?]
    let color: Color
    var width: CGFloat = 1.2
    var dashed = false
}

struct ChartPane {
    let title: String
    let titleColor: Color
    var lines: [ChartSeries] = []
    var histogram: [Double?]? = nil
    var fixedRange: (Double, Double)? = nil
    var levels: [Double] = []
}

/// Visible-range volume profile settings.
struct VolumeProfileSpec {
    let rows: Int
    let valueArea: Double     // 0...1
    let widthFraction: Double // share of the plot width
    let color: Color
}

/// Computed profile for a price range.
struct VolumeProfile {
    let lo: Double
    let step: Double
    let buy: [Double]
    let sell: [Double]
    let poc: Int
    let vaLow: Int
    let vaHigh: Int
    var total: [Double] { zip(buy, sell).map { $0 + $1 } }

    /// Distributes each candle's volume uniformly over the price bins its range covers.
    static func compute(_ candles: ArraySlice<Candle>, rows: Int, valueArea: Double) -> VolumeProfile? {
        guard rows > 1, let lo = candles.map(\.l).min(), let hi = candles.map(\.h).max(), hi > lo else { return nil }
        let step = (hi - lo) / Double(rows)
        var buy = [Double](repeating: 0, count: rows)
        var sell = [Double](repeating: 0, count: rows)
        for c in candles where c.v > 0 {
            let span = max(c.h - c.l, step * 1e-6)
            let first = max(0, min(rows - 1, Int((c.l - lo) / step)))
            let last = max(0, min(rows - 1, Int((c.h - lo) / step)))
            let up = c.c >= c.o
            for b in first...last {
                let bLo = lo + Double(b) * step, bHi = bLo + step
                let overlap = c.h == c.l ? 1.0 / Double(last - first + 1) : max(0, min(bHi, c.h) - max(bLo, c.l)) / span
                let v = c.v * overlap
                if up { buy[b] += v } else { sell[b] += v }
            }
        }
        let total = zip(buy, sell).map { $0 + $1 }
        let sum = total.reduce(0, +)
        guard sum > 0, let poc = total.indices.max(by: { total[$0] < total[$1] }) else { return nil }
        // Value area: grow from the POC towards the larger neighbour until the target share is covered.
        var lowI = poc, highI = poc, acc = total[poc]
        while acc < sum * valueArea && (lowI > 0 || highI < rows - 1) {
            let down = lowI > 0 ? total[lowI - 1] : -1
            let upV = highI < rows - 1 ? total[highI + 1] : -1
            if upV >= down { highI += 1; acc += total[highI] } else { lowI -= 1; acc += total[lowI] }
        }
        return VolumeProfile(lo: lo, step: step, buy: buy, sell: sell, poc: poc, vaLow: lowI, vaHigh: highI)
    }
}

struct ChartLayers {
    var volumeProfile: VolumeProfileSpec?
    var overlays: [ChartSeries] = []
    var bands: [(up: [Double?], low: [Double?], color: Color)] = []
    var panes: [ChartPane] = []
    var legend: [(String, Color)] = []

    static func build(_ candles: [Candle], configs: [IndicatorConfig], interval: CandleInterval) -> ChartLayers {
        var r = ChartLayers()
        guard !candles.isEmpty else { return r }
        let close: [Double] = candles.map(\.c)
        for cfg in configs where cfg.visible {
            let color = IndicatorPalette.color(cfg.color)
            switch cfg.kind {
            case .ema:
                r.overlays.append(ChartSeries(values: TA.ema(close, cfg.p1), color: color))
                r.legend.append((cfg.label, color))
            case .sma:
                r.overlays.append(ChartSeries(values: TA.sma(close, cfg.p1), color: color))
                r.legend.append((cfg.label, color))
            case .bollinger:
                let bb = TA.bollinger(close, cfg.p1, cfg.mult)
                r.bands.append((bb.up, bb.low, color))
                r.overlays.append(ChartSeries(values: bb.mid, color: color.opacity(0.7), width: 1, dashed: true))
                r.overlays.append(ChartSeries(values: bb.up, color: color, width: 1))
                r.overlays.append(ChartSeries(values: bb.low, color: color, width: 1))
                r.legend.append((cfg.label, color))
            case .vwap:
                r.overlays.append(ChartSeries(values: TA.vwap(candles, intervalSeconds: interval.seconds), color: color, width: 1.4))
                r.legend.append((cfg.label, color))
            case .rsi:
                r.panes.append(ChartPane(title: cfg.label, titleColor: color,
                                         lines: [ChartSeries(values: TA.rsi(close, cfg.p1), color: color)],
                                         fixedRange: (0, 100), levels: [cfg.lower, cfg.upper]))
            case .macd:
                let m = TA.macd(close, cfg.p1, cfg.p2, cfg.p3)
                r.panes.append(ChartPane(title: cfg.label, titleColor: color,
                                         lines: [ChartSeries(values: m.macd, color: color),
                                                 ChartSeries(values: m.signal, color: IndicatorPalette.color(cfg.color + 4))],
                                         histogram: m.hist, levels: [0]))
            case .volumeProfile:
                r.volumeProfile = VolumeProfileSpec(rows: max(5, cfg.p1), valueArea: min(0.99, max(0.1, cfg.upper / 100)),
                                                    widthFraction: min(0.8, max(0.05, Double(cfg.p2) / 100)), color: color)
                r.legend.append((cfg.label, color))
            case .stochastic:
                let s = TA.stochastic(candles, cfg.p1, cfg.p2, cfg.p3)
                r.panes.append(ChartPane(title: cfg.label, titleColor: color,
                                         lines: [ChartSeries(values: s.k, color: color),
                                                 ChartSeries(values: s.d, color: IndicatorPalette.color(cfg.color + 4))],
                                         fixedRange: (0, 100), levels: [cfg.lower, cfg.upper]))
            }
        }
        return r
    }
}
