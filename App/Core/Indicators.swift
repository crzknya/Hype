import Foundation
import SwiftUI

enum IndicatorKind: String, Codable, CaseIterable, Identifiable {
    case ema, sma, bollinger, vwap, rsi, macd, stochastic, volumeProfile, highLow
    case realizedVol, ewmaVol, garchVol, atr, zscore, momentum, kalman
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
        case .highLow: return L("High / Low (visible range)")
        case .realizedVol: return L("Realized volatility")
        case .ewmaVol: return L("EWMA volatility")
        case .garchVol: return L("GARCH(1,1) volatility")
        case .atr: return "ATR"
        case .zscore: return L("Z-score")
        case .momentum: return L("Momentum (vol-scaled)")
        case .kalman: return L("Kalman filter")
        }
    }

    /// Drawn in its own pane under the price chart.
    var isPane: Bool {
        switch self {
        case .rsi, .macd, .stochastic, .realizedVol, .ewmaVol, .garchVol, .atr, .zscore, .momentum: return true
        default: return false
        }
    }
}

/// Groups for the "Add indicator" menu.
enum IndicatorGroup: String, CaseIterable, Identifiable {
    case trend, oscillators, volatility, volume
    var id: String { rawValue }
    var title: String {
        switch self {
        case .trend: return L("Trend & overlays")
        case .oscillators: return L("Oscillators")
        case .volatility: return L("Volatility")
        case .volume: return L("Volume & levels")
        }
    }
    var icon: String {
        switch self {
        case .trend: return "chart.line.uptrend.xyaxis"
        case .oscillators: return "waveform.path.ecg"
        case .volatility: return "arrow.up.and.down"
        case .volume: return "chart.bar"
        }
    }
    var kinds: [IndicatorKind] {
        switch self {
        case .trend: return [.ema, .sma, .bollinger, .vwap, .kalman]
        case .oscillators: return [.rsi, .macd, .stochastic, .zscore, .momentum]
        case .volatility: return [.realizedVol, .ewmaVol, .garchVol, .atr]
        case .volume: return [.volumeProfile, .highLow]
        }
    }
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
        case .highLow: return IndicatorConfig(kind: kind, p1: 0, p2: 1, color: color)
        case .realizedVol: return IndicatorConfig(kind: kind, p1: 20, color: color)
        case .ewmaVol: return IndicatorConfig(kind: kind, p1: 94, color: color)            // λ = 0.94 (RiskMetrics)
        case .garchVol: return IndicatorConfig(kind: kind, p1: 10, p2: 85, color: color)   // α = 0.10, β = 0.85
        case .atr: return IndicatorConfig(kind: kind, p1: 14, color: color)
        case .zscore: return IndicatorConfig(kind: kind, p1: 20, upper: 2, lower: -2, color: color)
        case .momentum: return IndicatorConfig(kind: kind, p1: 20, upper: 1, lower: -1, color: color)
        case .kalman: return IndicatorConfig(kind: kind, p1: 10, color: color)
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
        case .highLow: return L("High / Low")
        case .realizedVol: return L("Vol {0}", p1)
        case .ewmaVol: return "EWMA \(Fmt.input(Double(p1) / 100, 2))"
        case .garchVol: return "GARCH \(Fmt.input(Double(p1) / 100, 2)), \(Fmt.input(Double(p2) / 100, 2))"
        case .atr: return "ATR \(p1)"
        case .zscore: return "Z \(p1)"
        case .momentum: return "TSMOM \(p1)"
        case .kalman: return "Kalman \(p1)"
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

    // MARK: Volatility, z-score, momentum, Kalman

    /// Bars per year for annualizing (crypto trades 24/7).
    static func barsPerYear(_ interval: CandleInterval) -> Double { 365 * 86_400 / max(interval.seconds, 1) }

    static func logReturns(_ x: [Double]) -> [Double?] {
        var r = [Double?](repeating: nil, count: x.count)
        for i in 1..<max(1, x.count) where x[i] > 0 && x[i - 1] > 0 { r[i] = Foundation.log(x[i] / x[i - 1]) }
        return r
    }

    /// Rolling sample standard deviation of log returns, annualized, in %.
    static func realizedVol(_ x: [Double], _ n: Int, annualize: Double) -> [Double?] {
        let r = logReturns(x)
        var out = [Double?](repeating: nil, count: x.count)
        guard n > 1, x.count > n else { return out }
        for i in n..<x.count {
            var s = 0.0, s2 = 0.0, k = 0.0
            for j in (i - n + 1)...i { if let v = r[j] { s += v; s2 += v * v; k += 1 } }
            guard k > 1 else { continue }
            let mean = s / k, variance = max(0, (s2 - k * mean * mean) / (k - 1))
            out[i] = variance.squareRoot() * annualize.squareRoot() * 100
        }
        return out
    }

    /// RiskMetrics EWMA volatility: σ²ₜ = λσ²ₜ₋₁ + (1 − λ)r²ₜ₋₁, annualized, in %.
    static func ewmaVol(_ x: [Double], lambda: Double, annualize: Double) -> [Double?] {
        let r = logReturns(x)
        var out = [Double?](repeating: nil, count: x.count)
        guard x.count > 21 else { return out }
        // Seed with the variance of the first 20 returns.
        let seed = r[1...20].compactMap { $0 }
        var v = seed.reduce(0) { $0 + $1 * $1 } / Double(max(seed.count, 1))
        for i in 21..<x.count {
            if let prev = r[i - 1] { v = lambda * v + (1 - lambda) * prev * prev }
            out[i] = v.squareRoot() * annualize.squareRoot() * 100
        }
        return out
    }

    /// GARCH(1,1) conditional volatility with given α, β; ω is set by variance targeting (long-run variance =
    /// sample variance of the returns). Annualized, in %.
    static func garchVol(_ x: [Double], alpha: Double, beta: Double, annualize: Double) -> [Double?] {
        let r = logReturns(x)
        let all = r.compactMap { $0 }
        var out = [Double?](repeating: nil, count: x.count)
        guard all.count > 30, alpha + beta < 1 else { return out }
        let mean = all.reduce(0, +) / Double(all.count)
        let longRun = all.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(all.count - 1)
        let omega = longRun * (1 - alpha - beta)
        var v = longRun
        for i in 2..<x.count {
            if let prev = r[i - 1] { v = omega + alpha * prev * prev + beta * v }
            out[i] = v.squareRoot() * annualize.squareRoot() * 100
        }
        return out
    }

    /// Wilder's Average True Range.
    static func atr(_ c: [Candle], _ n: Int) -> [Double?] {
        var out = [Double?](repeating: nil, count: c.count)
        guard n > 0, c.count > n else { return out }
        var tr = [Double](repeating: 0, count: c.count)
        tr[0] = c[0].h - c[0].l
        for i in 1..<c.count {
            tr[i] = max(c[i].h - c[i].l, abs(c[i].h - c[i - 1].c), abs(c[i].l - c[i - 1].c))
        }
        var a = tr[1...n].reduce(0, +) / Double(n)
        out[n] = a
        if c.count > n + 1 {
            for i in (n + 1)..<c.count {
                a = (a * Double(n - 1) + tr[i]) / Double(n)
                out[i] = a
            }
        }
        return out
    }

    /// (price − rolling mean) / rolling standard deviation.
    static func zscore(_ x: [Double], _ n: Int) -> [Double?] {
        var out = [Double?](repeating: nil, count: x.count)
        guard n > 1, x.count >= n else { return out }
        for i in (n - 1)..<x.count {
            var s = 0.0, s2 = 0.0
            for j in (i - n + 1)...i { s += x[j]; s2 += x[j] * x[j] }
            let mean = s / Double(n), sd = max(0, (s2 - Double(n) * mean * mean) / Double(n - 1)).squareRoot()
            out[i] = sd > 0 ? (x[i] - mean) / sd : 0
        }
        return out
    }

    /// Time-series momentum scaled by volatility: the n-bar log return divided by its expected size
    /// (per-bar volatility × √n). Around ±1 is a typical move, beyond ±2 a strong trend.
    static func tsMomentum(_ x: [Double], _ n: Int) -> [Double?] {
        let r = logReturns(x)
        var out = [Double?](repeating: nil, count: x.count)
        guard n > 1, x.count > n else { return out }
        for i in n..<x.count {
            var s = 0.0, s2 = 0.0, k = 0.0
            for j in (i - n + 1)...i { if let v = r[j] { s += v; s2 += v * v; k += 1 } }
            guard k > 1 else { continue }
            let mean = s / k, sd = max(0, (s2 - k * mean * mean) / (k - 1)).squareRoot()
            out[i] = sd > 0 ? s / (sd * k.squareRoot()) : 0
        }
        return out
    }

    /// One-dimensional Kalman filter (local level model): the estimate follows the price with a lag set by
    /// `lag` — process noise Q = R / lag², measurement noise R = variance of price changes.
    static func kalman(_ x: [Double], lag: Int) -> [Double?] {
        guard x.count > 2 else { return x.map { _ in nil } }
        var diffs = 0.0
        for i in 1..<x.count { diffs += (x[i] - x[i - 1]) * (x[i] - x[i - 1]) }
        let R = max(diffs / Double(x.count - 1), 1e-18)
        let Q = R / Double(max(lag, 1) * max(lag, 1))
        var est = x[0], p = R
        var out = [Double?](repeating: nil, count: x.count)
        out[0] = est
        for i in 1..<x.count {
            p += Q                       // predict
            let k = p / (p + R)          // update
            est += k * (x[i] - est)
            p *= (1 - k)
            out[i] = est
        }
        return out
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
    /// Marks of the highest high and lowest low among the candles on screen (with % from the last price).
    var highLow: (color: Color, showPercent: Bool)?

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
            case .highLow:
                r.highLow = (color, cfg.p2 != 0)
            case .realizedVol:
                r.panes.append(ChartPane(title: cfg.label + " %", titleColor: color,
                                         lines: [ChartSeries(values: TA.realizedVol(close, cfg.p1, annualize: TA.barsPerYear(interval)), color: color)]))
            case .ewmaVol:
                r.panes.append(ChartPane(title: cfg.label + " %", titleColor: color,
                                         lines: [ChartSeries(values: TA.ewmaVol(close, lambda: Double(cfg.p1) / 100, annualize: TA.barsPerYear(interval)), color: color)]))
            case .garchVol:
                r.panes.append(ChartPane(title: cfg.label + " %", titleColor: color,
                                         lines: [ChartSeries(values: TA.garchVol(close, alpha: Double(cfg.p1) / 100, beta: Double(cfg.p2) / 100,
                                                                                 annualize: TA.barsPerYear(interval)), color: color)]))
            case .atr:
                r.panes.append(ChartPane(title: cfg.label, titleColor: color,
                                         lines: [ChartSeries(values: TA.atr(candles, cfg.p1), color: color)]))
            case .zscore:
                r.panes.append(ChartPane(title: cfg.label, titleColor: color,
                                         lines: [ChartSeries(values: TA.zscore(close, cfg.p1), color: color)],
                                         levels: [cfg.lower, 0, cfg.upper]))
            case .momentum:
                r.panes.append(ChartPane(title: cfg.label, titleColor: color,
                                         lines: [ChartSeries(values: TA.tsMomentum(close, cfg.p1), color: color)],
                                         histogram: TA.tsMomentum(close, cfg.p1), levels: [cfg.lower, 0, cfg.upper]))
            case .kalman:
                r.overlays.append(ChartSeries(values: TA.kalman(close, lag: cfg.p1), color: color, width: 1.5))
                r.legend.append((cfg.label, color))
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
