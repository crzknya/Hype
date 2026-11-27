import Foundation

/// Trading math from the quant formula sheet: execution cost, break-even, order-book signals and
/// performance statistics. Pure functions over app data.
enum QuantMath {
    // MARK: Execution (13.6 slippage, 13.7 square-root impact)

    struct FillEstimate {
        let avgPrice: Double
        let filled: Double          // size covered by the visible book
        let levels: Int
        let slippage: Double        // fraction vs. mid, always ≥ 0 (cost)
        let exhausted: Bool         // the visible book is not deep enough
    }

    /// Walks the visible book for a market order of `size` (coin units).
    static func estimateFill(book: OrderBook, isBuy: Bool, size: Double) -> FillEstimate? {
        let levels = isBuy ? book.asks : book.bids
        guard size > 0, let mid = book.mid, mid > 0, !levels.isEmpty else { return nil }
        var left = size, cost = 0.0, used = 0
        for l in levels where left > 0 {
            let take = min(left, l.sz)
            cost += take * l.px
            left -= take
            used += 1
        }
        let filled = size - left
        guard filled > 0 else { return nil }
        let avg = cost / filled
        let slip = isBuy ? avg / mid - 1 : 1 - avg / mid
        return FillEstimate(avgPrice: avg, filled: filled, levels: used, slippage: max(0, slip), exhausted: left > 1e-12)
    }

    /// Square-root market impact: ≈ σ_daily × √(order notional / daily volume) (Y ≈ 1).
    static func sqrtImpact(notional: Double, dailyVolume: Double, dailyVol: Double) -> Double? {
        guard notional > 0, dailyVolume > 0, dailyVol > 0 else { return nil }
        return dailyVol * (notional / dailyVolume).squareRoot()
    }

    /// Daily volatility (fraction) from candles of any interval: per-bar log-return σ × √(bars per day).
    static func dailyVol(_ candles: [Candle], interval: CandleInterval) -> Double? {
        let closes = candles.suffix(200).map(\.c)
        guard closes.count > 20 else { return nil }
        var r: [Double] = []
        for i in 1..<closes.count where closes[i] > 0 && closes[i - 1] > 0 { r.append(log(closes[i] / closes[i - 1])) }
        guard r.count > 10 else { return nil }
        let mean = r.reduce(0, +) / Double(r.count)
        let sd = (r.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(r.count - 1)).squareRoot()
        return sd * (86_400 / max(interval.seconds, 1)).squareRoot()
    }

    // MARK: Costs (17.1–17.3)

    /// Break-even price of an open position: entry ± (entry fee + exit fee + funding paid) / size.
    /// Fees at the taker rate (conservative when the entry was a maker fill).
    static func breakEven(_ p: Position, takerFee: Double) -> Double? {
        guard p.size > 0, p.entryPx > 0 else { return nil }
        let notional = p.size * p.entryPx
        let costs = notional * takerFee * 2 + p.fundingSinceOpen   // fundingSinceOpen > 0 = paid
        let perUnit = costs / p.size
        return p.isLong ? p.entryPx + perUnit : p.entryPx - perUnit
    }

    // MARK: Order book (13.1–13.3)

    /// Bid share of the resting size on the first `depth` levels each side (0.5 = balanced).
    static func imbalance(_ book: OrderBook, depth: Int = 10) -> Double? {
        let b = book.bids.prefix(depth).reduce(0) { $0 + $1.sz }
        let a = book.asks.prefix(depth).reduce(0) { $0 + $1.sz }
        return a + b > 0 ? b / (a + b) : nil
    }

    /// Size-weighted mid ("microprice"): leans toward the side with less size, where the price is likely to go.
    static func microprice(_ book: OrderBook) -> Double? {
        guard let bid = book.bids.first, let ask = book.asks.first, bid.sz + ask.sz > 0 else { return nil }
        return (bid.px * ask.sz + ask.px * bid.sz) / (bid.sz + ask.sz)
    }

    // MARK: Performance (10.1–10.5)

    struct Performance {
        let periods: Int
        let totalReturn: Double
        let annualReturn: Double
        let annualVol: Double
        let sharpe: Double?
        let sortino: Double?
        let maxDrawdown: Double
        let calmar: Double?
        let winRate: Double
    }

    /// Statistics of the account's returns between history points: rₜ = ΔPnLₜ / account valueₜ₋₁, so
    /// deposits and withdrawals don't count as performance.
    static func performance(accountValue: [(Date, Double)], pnl: [(Date, Double)]) -> Performance? {
        let n = min(accountValue.count, pnl.count)
        guard n > 3 else { return nil }
        var r: [Double] = []
        for i in 1..<n where accountValue[i - 1].1 > 0 {
            r.append((pnl[i].1 - pnl[i - 1].1) / accountValue[i - 1].1)
        }
        guard r.count > 2 else { return nil }
        let span = pnl[n - 1].0.timeIntervalSince(pnl[0].0)
        guard span > 0 else { return nil }
        let perYear = Double(r.count) / (span / (365 * 86_400))
        let mean = r.reduce(0, +) / Double(r.count)
        let sd = (r.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(r.count - 1)).squareRoot()
        let downside = (r.reduce(0) { $0 + min($1, 0) * min($1, 0) } / Double(r.count)).squareRoot()
        var equity = 1.0, peak = 1.0, maxDD = 0.0
        for x in r {
            equity *= (1 + x)
            peak = max(peak, equity)
            maxDD = max(maxDD, 1 - equity / peak)
        }
        let years = span / (365 * 86_400)
        let annual = equity > 0 ? pow(equity, 1 / max(years, 1e-6)) - 1 : -1
        return Performance(periods: r.count, totalReturn: equity - 1, annualReturn: annual,
                           annualVol: sd * perYear.squareRoot(),
                           sharpe: sd > 0 ? mean / sd * perYear.squareRoot() : nil,
                           sortino: downside > 0 ? mean / downside * perYear.squareRoot() : nil,
                           maxDrawdown: maxDD,
                           calmar: maxDD > 0 ? annual / maxDD : nil,
                           winRate: Double(r.filter { $0 > 0 }.count) / Double(r.count))
    }
}
