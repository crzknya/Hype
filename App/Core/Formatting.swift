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
    /// Parses user input with either decimal separator. "1,5" / "1.5" → 1.5; grouped thousands
    /// ("60,000", "1,234.5", "1.234,5", "60 000") are understood. A lone comma followed by exactly three
    /// digits ("1,500") is ambiguous (1.5 or 1500) and is rejected rather than guessed.
    static func parse(_ s: String) -> Double? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for sp in [" ", "\u{00a0}", "\u{202f}", "'", "’", "_"] { t = t.replacingOccurrences(of: sp, with: "") }
        guard !t.isEmpty else { return nil }
        let dots = t.filter { $0 == "." }.count, commas = t.filter { $0 == "," }.count
        if dots > 0 && commas > 0 {
            // The last separator is the decimal one, the other groups thousands.
            guard let ld = t.lastIndex(of: "."), let lc = t.lastIndex(of: ",") else { return nil }
            if lc > ld { t = t.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".") }
            else { t = t.replacingOccurrences(of: ",", with: "") }
        } else if commas > 1 || dots > 1 {
            // Several identical separators can only group thousands: "1,234,567" / "1.234.567".
            let sep: Character = commas > 1 ? "," : "."
            let groups = t.split(separator: sep, omittingEmptySubsequences: false)
            guard groups.dropFirst().allSatisfy({ $0.count == 3 }) else { return nil }
            t = groups.joined()
        } else if commas == 1 {
            let parts = t.split(separator: ",", omittingEmptySubsequences: false)
            let intPart = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "-+"))
            if parts.count == 2, parts[1].count == 3, !intPart.isEmpty, intPart != "0" { return nil }   // "1,500": ambiguous
            t = t.replacingOccurrences(of: ",", with: ".")
        }
        guard let v = Double(t), v.isFinite else { return nil }
        return v
    }

    /// True when the text would be rejected only because of an ambiguous separator ("1,500").
    static func isAmbiguous(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard parse(t) == nil, t.filter({ $0 == "," }).count == 1, !t.contains(".") else { return false }
        return Double(t.replacingOccurrences(of: ",", with: ".")) != nil
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

/// Visual themes. Classic is the original Hyperliquid-like look; Neon is a purple/cyan
/// glassy style (inspired by Straddle).
enum AppTheme: String, CaseIterable, Identifiable, Codable {
    case classic, neon
    var id: String { rawValue }
    var title: String { self == .classic ? L("Classic") : L("Neon") }

    /// Read by the color palette below; set from AppModel.theme.
    static var current: AppTheme = AppTheme(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? .classic

    var cardRadius: CGFloat { self == .neon ? 18 : 12 }
}

extension Color {
    private static var neon: Bool { AppTheme.current == .neon }

    static var hlGreen: Color { neon ? Color(red: 0.20, green: 0.90, blue: 0.68) : Color(red: 0.16, green: 0.83, blue: 0.62) }
    static var hlRed: Color { neon ? Color(red: 1.0, green: 0.35, blue: 0.48) : Color(red: 0.94, green: 0.29, blue: 0.36) }
    static var hlAccent: Color { neon ? Color(red: 0.62, green: 0.30, blue: 1.0) : Color(red: 0.34, green: 0.92, blue: 0.80) }
    /// Secondary accent (cyan in Neon).
    static var hlAccent2: Color { neon ? Color(red: 0.14, green: 0.87, blue: 0.96) : Color(red: 0.34, green: 0.92, blue: 0.80) }
    static var hlBg: Color { neon ? Color(red: 0.025, green: 0.025, blue: 0.045) : Color(red: 0.04, green: 0.08, blue: 0.09) }
    static var hlCard: Color { neon ? Color(red: 0.075, green: 0.07, blue: 0.11) : Color(red: 0.08, green: 0.13, blue: 0.14) }
    static var hlCard2: Color { neon ? Color(red: 0.11, green: 0.10, blue: 0.15) : Color(red: 0.11, green: 0.17, blue: 0.18) }
    static var hlMuted: Color { neon ? Color.white.opacity(0.62) : Color(white: 0.55) }

    static func pnl(_ x: Double) -> Color { x > 0 ? .hlGreen : x < 0 ? .hlRed : .primary }
}

extension LinearGradient {
    /// Accent gradient (purple → cyan in Neon, flat accent in Classic).
    static var hlAccent: LinearGradient {
        LinearGradient(colors: [.hlAccent, .hlAccent2], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Screen background: flat in Classic; dark with soft purple/teal glows in Neon.
struct ThemedBackground: View {
    var body: some View {
        ZStack {
            Color.hlBg
            if AppTheme.current == .neon {
                GeometryReader { g in
                    Circle()
                        .fill(Color.hlAccent.opacity(0.22))
                        .frame(width: g.size.width * 0.9)
                        .blur(radius: 90)
                        .offset(x: g.size.width * 0.35, y: -g.size.width * 0.35)
                    Circle()
                        .fill(Color.hlAccent2.opacity(0.10))
                        .frame(width: g.size.width * 0.8)
                        .blur(radius: 100)
                        .offset(x: -g.size.width * 0.3, y: g.size.height * 0.75)
                }
            }
        }
        .ignoresSafeArea()
    }
}

extension View {
    func themedBackground() -> some View { background(ThemedBackground()) }
}
