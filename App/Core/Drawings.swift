import Foundation
import SwiftUI

/// A point on the chart: candle time (ms) and price. Anchored to time, not to a candle index, so drawings
/// stay in place when the interval changes.
struct ChartPoint: Codable, Equatable {
    var t: Double
    var p: Double
}

enum DrawKind: String, Codable, CaseIterable {
    case hline, hray, trend, rect, fib

    var title: String {
        switch self {
        case .hline: return L("Horizontal line")
        case .hray: return L("Horizontal ray")
        case .trend: return L("Trend line")
        case .rect: return L("Rectangle")
        case .fib: return L("Fib retracement")
        }
    }

    /// Needs two points (drag from the first to the second).
    var twoPoint: Bool { self == .trend || self == .rect || self == .fib }
}

/// Tools of the drawing panel; `cursor` selects and moves existing drawings.
enum DrawTool: String, CaseIterable, Identifiable {
    case cursor, ruler, hline, hray, trend, rect, fib
    var id: String { rawValue }

    var kind: DrawKind? { DrawKind(rawValue: rawValue) }
    var twoPoint: Bool { self == .ruler || (kind?.twoPoint ?? false) }

    var title: String {
        switch self {
        case .cursor: return L("Cursor")
        case .ruler: return L("Ruler")
        default: return kind?.title ?? ""
        }
    }

    /// Hint shown while the tool is active.
    var hint: String {
        switch self {
        case .cursor: return ""
        case .ruler: return L("Drag to measure")
        case .hline, .hray: return L("Tap to place")
        default: return L("Drag from the first point to the second, or tap both points")
        }
    }
}

/// Snapping of drawing points to candle prices (open / high / low / close).
enum MagnetMode: String, Codable, CaseIterable, Identifiable {
    case off, weak, strong
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return L("Magnet off")
        case .weak: return L("Weak magnet")
        case .strong: return L("Strong magnet")
        }
    }
    var next: MagnetMode {
        switch self {
        case .off: return .weak
        case .weak: return .strong
        case .strong: return .off
        }
    }
}

enum DrawLineStyle: String, Codable, CaseIterable, Identifiable {
    case solid, dashed, dotted
    var id: String { rawValue }
    var title: String {
        switch self {
        case .solid: return L("Solid")
        case .dashed: return L("Dashed")
        case .dotted: return L("Dotted")
        }
    }
    func dash(_ width: CGFloat) -> [CGFloat] {
        switch self {
        case .solid: return []
        case .dashed: return [6, 4]
        case .dotted: return [max(1, width), 3]
        }
    }
}

/// Where a drawing's text (and Fib level labels) sits along the line.
enum DrawLabelAlign: String, Codable, CaseIterable, Identifiable {
    case left, center, right
    var id: String { rawValue }
    var title: String {
        switch self {
        case .left: return L("Left")
        case .center: return L("Center")
        case .right: return L("Right")
        }
    }
}

struct ChartDrawing: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: DrawKind
    var a: ChartPoint
    var b: ChartPoint
    var color = 0
    var width = 1.5
    var style: DrawLineStyle = .solid
    var showPrice = true
    var text = ""
    var extendLeft = false
    var extendRight = false
    var locked = false
    /// Optional so drawings saved before this setting still decode.
    var labelAlignment: DrawLabelAlign?
    var labelAlign: DrawLabelAlign {
        get { labelAlignment ?? .left }
        set { labelAlignment = newValue }
    }

    static let palette: [Color] = [
        Color(red: 0.55, green: 0.48, blue: 1.0),    // violet
        Color(red: 0.25, green: 0.6, blue: 1.0),     // blue
        Color(red: 0.2, green: 0.85, blue: 0.85),    // cyan
        Color(red: 0.3, green: 0.85, blue: 0.5),     // green
        Color(red: 1.0, green: 0.85, blue: 0.25),    // yellow
        Color(red: 1.0, green: 0.6, blue: 0.2),      // orange
        Color(red: 1.0, green: 0.35, blue: 0.4),     // red
        Color(white: 0.9),                           // white
    ]
    var swiftColor: Color { Self.palette[min(max(color, 0), Self.palette.count - 1)] }

    static let fibLevels: [Double] = [0, 0.236, 0.382, 0.5, 0.618, 0.786, 1]

    /// Fib level price: 0 at the second point (the end of the move), 1 at the first.
    func fibPrice(_ level: Double) -> Double { b.p - (b.p - a.p) * level }
}

extension AppModel {
    func drawings(for coin: String) -> [ChartDrawing] { drawingsByCoin[coin] ?? [] }

    func setDrawings(_ list: [ChartDrawing], for coin: String) {
        drawingsByCoin[coin] = list.isEmpty ? nil : list
    }

    func updateDrawing(_ d: ChartDrawing, coin: String) {
        var list = drawings(for: coin)
        if let i = list.firstIndex(where: { $0.id == d.id }) { list[i] = d } else { list.append(d) }
        setDrawings(list, for: coin)
    }

    func deleteDrawing(_ id: UUID, coin: String) {
        setDrawings(drawings(for: coin).filter { $0.id != id }, for: coin)
        if selectedDrawingId == id { selectedDrawingId = nil }
    }

    static func loadDrawings() -> [String: [ChartDrawing]] {
        guard let data = UserDefaults.standard.data(forKey: "chartDrawings"),
              let d = try? JSONDecoder().decode([String: [ChartDrawing]].self, from: data) else { return [:] }
        return d
    }
}

/// Which price lines the chart shows (Indicators → Lines on chart).
struct ChartLineSettings: Codable, Equatable {
    var position = true
    var liquidation = true
    var orders = true
    var alerts = true
    var lastPrice = true
    var labels = true
    var alertPrices = true

    init() {}

    enum CodingKeys: String, CodingKey { case position, liquidation, orders, alerts, lastPrice, labels, alertPrices }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v(_ k: CodingKeys) -> Bool { (try? c.decodeIfPresent(Bool.self, forKey: k)) ?? true }
        position = v(.position); liquidation = v(.liquidation); orders = v(.orders); alerts = v(.alerts)
        lastPrice = v(.lastPrice); labels = v(.labels); alertPrices = v(.alertPrices)
    }

    static func load() -> ChartLineSettings {
        guard let data = UserDefaults.standard.data(forKey: "chartLineSettings"),
              let s = try? JSONDecoder().decode(ChartLineSettings.self, from: data) else { return ChartLineSettings() }
        return s
    }
}
