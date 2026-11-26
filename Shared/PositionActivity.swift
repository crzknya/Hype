import Foundation
import ActivityKit

/// Live Activity (lock screen + Dynamic Island) with the open positions' PnL and liquidation distance.
/// Shared by the app (starts / updates it) and the widget extension (draws it).
struct PositionActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var items: [Item]
        var totalPnl: Double
        var updatedAt: Date
    }

    public struct Item: Codable, Hashable {
        var coin: String
        var isLong: Bool
        var leverage: Int
        var pnl: Double
        /// Return on margin, fraction.
        var roe: Double
        var mark: Double
        var liq: Double?
        /// Distance from the mark price to liquidation, fraction (0.05 = 5 %).
        var liqDistance: Double?
    }

    var accountName: String
}

/// Small formatters usable in both targets.
enum ActivityFormat {
    static func usd(_ v: Double, signed: Bool = true) -> String {
        let a = abs(v)
        let body: String
        if a >= 1_000_000 { body = String(format: "%.2fM", a / 1_000_000) }
        else if a >= 10_000 { body = String(format: "%.1fK", a / 1_000) }
        else { body = String(format: "%.2f", a) }
        let sign = v < 0 ? "−" : (signed ? "+" : "")
        return "\(sign)$\(body)"
    }

    static func pct(_ v: Double) -> String {
        String(format: "%@%.2f%%", v < 0 ? "−" : "+", abs(v) * 100)
    }

    static func price(_ v: Double) -> String {
        let a = abs(v)
        let dec = a >= 10_000 ? 0 : a >= 100 ? 2 : a >= 1 ? 4 : 6
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = dec
        f.maximumFractionDigits = dec
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }
}
