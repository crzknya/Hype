import Foundation

public enum HLNum {
    /// Canonical wire string: plain decimal notation, no trailing zeros, no exponent.
    public static func wire(_ d: Decimal) -> String {
        var s = NSDecimalNumber(decimal: d).stringValue
        if s.contains("e") || s.contains("E") {
            // Should not happen with NSDecimalNumber, but guard anyway.
            s = String(format: "%.8f", NSDecimalNumber(decimal: d).doubleValue)
        }
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        if s == "-0" || s.isEmpty { s = "0" }
        return s
    }

    public static func wire(_ x: Double, maxDecimals: Int = 8) -> String {
        wire(round(x, places: maxDecimals))
    }

    public static func round(_ x: Double, places: Int, mode: NSDecimalNumber.RoundingMode = .plain) -> Decimal {
        var value = Decimal(x)
        var result = Decimal()
        NSDecimalRound(&result, &value, max(0, places), mode)
        return result
    }

    /// Max decimals allowed for prices: 6 (perp) or 8 (spot) minus szDecimals.
    public static func maxPriceDecimals(szDecimals: Int, isSpot: Bool) -> Int {
        max(0, (isSpot ? 8 : 6) - szDecimals)
    }

    /// Hyperliquid price rule: at most 5 significant figures (integers always allowed)
    /// and at most `maxPriceDecimals` decimals.
    public static func roundPrice(_ px: Double, szDecimals: Int, isSpot: Bool) -> Decimal {
        guard px.isFinite, px > 0 else { return 0 }
        let maxDec = maxPriceDecimals(szDecimals: szDecimals, isSpot: isSpot)
        let intDigits = Int(Foundation.floor(Foundation.log10(px))) + 1
        let sigDec = 5 - intDigits
        let dec = max(0, min(sigDec, maxDec))
        return round(px, places: dec)
    }

    public static func priceDecimals(_ px: Double, szDecimals: Int, isSpot: Bool) -> Int {
        guard px.isFinite, px > 0 else { return 2 }
        let maxDec = maxPriceDecimals(szDecimals: szDecimals, isSpot: isSpot)
        let intDigits = Int(Foundation.floor(Foundation.log10(px))) + 1
        return max(0, min(5 - intDigits, maxDec))
    }

    public static func roundSize(_ sz: Double, szDecimals: Int, mode: NSDecimalNumber.RoundingMode = .down) -> Decimal {
        guard sz.isFinite, sz > 0 else { return 0 }
        return round(sz, places: szDecimals, mode: mode)
    }

    /// Slippage-adjusted aggressive price for market orders (IOC limit).
    public static func marketPrice(mid: Double, isBuy: Bool, slippage: Double, szDecimals: Int, isSpot: Bool) -> Decimal {
        roundPrice(mid * (isBuy ? 1 + slippage : 1 - slippage), szDecimals: szDecimals, isSpot: isSpot)
    }
}
