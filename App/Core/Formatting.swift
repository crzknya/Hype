import Foundation
import SwiftUI

enum Fmt {
    private static var cache: [String: NumberFormatter] = [:]

    private static func formatter(_ minD: Int, _ maxD: Int, group: Bool) -> NumberFormatter {
        let key = "\(minD)-\(maxD)-\(group)"
        if let f = cache[key] { return f }
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = group
        f.groupingSeparator = ","
        f.decimalSeparator = "."
        f.minimumFractionDigits = minD
        f.maximumFractionDigits = maxD
        f.roundingMode = .halfEven
        cache[key] = f
        return f
    }

    static func num(_ x: Double, _ d: Int, group: Bool = true) -> String {
        guard x.isFinite else { return "—" }
        return formatter(d, d, group: group).string(from: NSNumber(value: x)) ?? "—"
    }

    /// Price with automatic precision (Hyperliquid style: 5 significant figures).
    static func price(_ x: Double, decimals: Int? = nil) -> String {
        guard x.isFinite, x != 0 else { return x == 0 ? "0" : "—" }
        let d = decimals ?? autoDecimals(x)
        return num(x, d)
    }

    static func autoDecimals(_ x: Double) -> Int {
        let a = abs(x)
        guard a > 0 else { return 2 }
        let intDigits = Int(floor(log10(a))) + 1
        return max(0, min(8, 5 - intDigits))
    }

    static func size(_ x: Double, _ szDecimals: Int) -> String { num(x, szDecimals) }

    static func usd(_ x: Double, _ d: Int = 2) -> String {
        guard x.isFinite else { return "—" }
        return (x < 0 ? "-$" : "$") + num(abs(x), d)
    }

    static func signedUsd(_ x: Double, _ d: Int = 2) -> String {
        guard x.isFinite else { return "—" }
        return (x > 0 ? "+$" : x < 0 ? "-$" : "$") + num(abs(x), d)
    }

    static func pct(_ x: Double, _ d: Int = 2, signed: Bool = true) -> String {
        guard x.isFinite else { return "—" }
        let s = num(x * 100, d)
        return (signed && x > 0 ? "+" : "") + s + "%"
    }

    static func compact(_ x: Double) -> String {
        let a = abs(x)
        let sign = x < 0 ? "-" : ""
        switch a {
        case 1e9...: return sign + num(a / 1e9, 2) + "B"
        case 1e6...: return sign + num(a / 1e6, 2) + "M"
        case 1e3...: return sign + num(a / 1e3, 1) + "K"
        default: return sign + num(a, 2)
        }
    }

    static func compactUsd(_ x: Double) -> String { (x < 0 ? "-$" : "$") + compact(abs(x)) }

    static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static let dateTimeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM HH:mm"
        return f
    }()

    static func time(_ d: Date) -> String { timeFmt.string(from: d) }
    static func dateTime(_ d: Date) -> String { dateTimeFmt.string(from: d) }

    static func countdown(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    /// Parses user input accepting both "," and "." decimal separators and spaces.
    static func parse(_ s: String) -> Double? {
        let t = s.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00a0}", with: "")
        guard !t.isEmpty else { return nil }
        return Double(t)
    }

    static func input(_ x: Double, _ d: Int) -> String {
        guard x.isFinite else { return "" }
        var s = num(x, d, group: false)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }
}

extension Color {
    static let hlGreen = Color(red: 0.16, green: 0.83, blue: 0.62)
    static let hlRed = Color(red: 0.94, green: 0.29, blue: 0.36)
    static let hlAccent = Color(red: 0.34, green: 0.92, blue: 0.80)
    static let hlBg = Color(red: 0.04, green: 0.08, blue: 0.09)
    static let hlCard = Color(red: 0.08, green: 0.13, blue: 0.14)
    static let hlCard2 = Color(red: 0.11, green: 0.17, blue: 0.18)
    static let hlMuted = Color(white: 0.55)

    static func pnl(_ x: Double) -> Color { x > 0 ? .hlGreen : x < 0 ? .hlRed : .primary }
}
