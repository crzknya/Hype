import Foundation
import SwiftUI
import HyperCore

/// Market Profile (TPO) settings, all user-adjustable in the TPO settings sheet.
struct TPOSettings: Codable, Equatable {
    enum Display: String, Codable, CaseIterable, Identifiable {
        case blocks, letters
        var id: String { rawValue }
        var title: String { self == .blocks ? L("Blocks") : L("Letters") }
    }

    enum Coloring: String, Codable, CaseIterable, Identifiable {
        case time, single, valueArea
        var id: String { rawValue }
        var title: String {
            switch self {
            case .time: return L("By time")
            case .single: return L("Single color")
            case .valueArea: return L("Value area")
            }
        }
    }

    enum Session: String, Codable, CaseIterable, Identifiable {
        case candle, day, regions, week
        var id: String { rawValue }
        var title: String {
            switch self {
            case .candle: return L("Each candle")
            case .day: return L("Day")
            case .regions: return L("Asia / London / New York")
            case .week: return L("Week")
            }
        }
    }

    enum Density: String, Codable, CaseIterable, Identifiable {
        case fine, normal, coarse
        var id: String { rawValue }
        var title: String {
            switch self {
            case .fine: return L("Fine")
            case .normal: return L("Normal")
            case .coarse: return L("Coarse")
            }
        }
        /// Target row height in points; the price step is the round number closest to it.
        var rowHeight: Double {
            switch self {
            case .fine: return 5
            case .normal: return 8
            case .coarse: return 13
            }
        }
    }

    static let periods: [CandleInterval] = [.m1, .m3, .m5, .m15, .m30, .h1]
    static let candleLengths: [CandleInterval] = [.m15, .m30, .h1, .h2, .h4, .h8, .h12, .d1]
    static let historyChoices = [1, 2, 3, 7, 14, 30, 60]

    var display: Display = .blocks
    var coloring: Coloring = .time
    /// Default: every 30-minute candle as its own profile, one letter per minute.
    var session: Session = .candle
    /// Candle length when each candle is a profile.
    var candleLength: CandleInterval = .m30
    /// Start of the daily session, hour in UTC (0 = midnight UTC).
    var dayStartHour = 0
    var period: CandleInterval = .m1
    var valueArea = 0.70
    var ibPeriods = 2
    var density: Density = .normal
    var historyDays = 14
    var showPOC = true
    var showValueArea = true
    var showIB = false
    var showSinglePrints = true
    var showOpenClose = true
    var nakedPOC = true

    init() {}

    enum CodingKeys: String, CodingKey {
        case display, coloring, session, candleLength, dayStartHour, period, valueArea, ibPeriods, density, historyDays
        case showPOC, showValueArea, showIB, showSinglePrints, showOpenClose, nakedPOC
    }

    /// Tolerant decoding: settings added later fall back to their defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TPOSettings()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        display = v(.display, d.display)
        coloring = v(.coloring, d.coloring)
        session = v(.session, d.session)
        candleLength = v(.candleLength, d.candleLength)
        if !Self.candleLengths.contains(candleLength) { candleLength = .m30 }
        dayStartHour = min(23, max(0, v(.dayStartHour, d.dayStartHour)))
        period = v(.period, d.period)
        if !Self.periods.contains(period) { period = .m1 }
        valueArea = min(0.95, max(0.5, v(.valueArea, d.valueArea)))
        ibPeriods = min(6, max(1, v(.ibPeriods, d.ibPeriods)))
        density = v(.density, d.density)
        historyDays = v(.historyDays, d.historyDays)
        showPOC = v(.showPOC, d.showPOC)
        showValueArea = v(.showValueArea, d.showValueArea)
        showIB = v(.showIB, d.showIB)
        showSinglePrints = v(.showSinglePrints, d.showSinglePrints)
        showOpenClose = v(.showOpenClose, d.showOpenClose)
        nakedPOC = v(.nakedPOC, d.nakedPOC)
        // Settings saved before per-candle profiles existed: switch to them (what the mode is for).
        if (try? c.decodeIfPresent(CandleInterval.self, forKey: .candleLength)) == nil {
            session = .candle
            period = .m1
            showIB = false
        }
        fixPeriod()
    }

    /// Letter periods shorter than the session (a profile needs several letters).
    var periodChoices: [CandleInterval] {
        guard session == .candle else { return Self.periods }
        return Self.periods.filter { $0.seconds < candleLength.seconds }
    }

    /// Keeps the letter period below the candle length (e.g. after choosing shorter candles).
    mutating func fixPeriod() {
        if session == .candle, period.seconds >= candleLength.seconds {
            period = periodChoices.last ?? .m1
        }
    }

    static let storageKey = "tpoSettings"

    static func load() -> TPOSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let s = try? JSONDecoder().decode(TPOSettings.self, from: data) else { return TPOSettings() }
        return s
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.storageKey)
    }

    /// Days of candles to request: no more than the 5000 candles one request returns.
    var fetchDays: Int {
        let perDay = 86400 / Int(period.seconds)
        let wanted = session == .week ? max(historyDays, 14) : historyDays
        return max(1, min(wanted, 5000 / perDay - 1))
    }

    /// Session (start, end, short name) containing a time in seconds.
    func session(containing t: Double) -> (start: Double, end: Double, name: String?) {
        switch session {
        case .candle:
            let len = candleLength.seconds
            let start = floor(t / len) * len
            return (start, start + len, nil)
        case .day:
            let shift = Double(dayStartHour) * 3600
            let start = floor((t - shift) / 86400) * 86400 + shift
            return (start, start + 86400, nil)
        case .week:
            // 1970-01-01 was a Thursday: Monday-based weeks start 3 days later.
            let day = floor(t / 86400)
            let weekday = (Int(day) + 3) % 7
            let start = (day - Double(weekday)) * 86400
            return (start, start + 7 * 86400, nil)
        case .regions:
            let dayStart = floor(t / 86400) * 86400
            let s = t - dayStart
            if s < 8 * 3600 { return (dayStart, dayStart + 8 * 3600, L("Asia")) }
            if s < 13.5 * 3600 { return (dayStart + 8 * 3600, dayStart + 13.5 * 3600, L("London")) }
            return (dayStart + 13.5 * 3600, dayStart + 86400, L("New York"))
        }
    }
}

/// One TPO period (a letter): the price range of one period inside a session.
struct TPOPeriod {
    let index: Int
    let o: Double, h: Double, l: Double, c: Double
}

/// A session's periods; binned into rows on demand for the current price step.
struct TPOProfile: Identifiable {
    let start: Double
    let end: Double
    let name: String?
    var periods: [TPOPeriod]
    var high: Double
    var low: Double
    var id: Double { start }
    var open: Double { periods.first?.o ?? 0 }
    var close: Double { periods.last?.c ?? 0 }

    static func build(_ candles: [Candle], settings: TPOSettings) -> [TPOProfile] {
        var out: [TPOProfile] = []
        let len = settings.period.seconds
        for c in candles where c.h > 0 && c.l > 0 {
            let t = c.t / 1000
            let s = settings.session(containing: t)
            let idx = max(0, Int((t - s.start) / len))
            let p = TPOPeriod(index: idx, o: c.o, h: c.h, l: c.l, c: c.c)
            if let last = out.last, last.start == s.start {
                out[out.count - 1].periods.append(p)
                out[out.count - 1].high = max(last.high, c.h)
                out[out.count - 1].low = min(last.low, c.l)
            } else {
                out.append(TPOProfile(start: s.start, end: s.end, name: s.name, periods: [p], high: c.h, low: c.l))
            }
        }
        return out
    }
}

/// A profile binned at one price step: which periods printed in each row, POC, value area, IB.
struct TPORows {
    let step: Double
    let lowRow: Int
    let highRow: Int
    /// Period indices per row, index = row − lowRow.
    let cells: [[Int]]
    let poc: Int
    let vaLow: Int
    let vaHigh: Int
    let maxCount: Int
    let ibLow: Double
    let ibHigh: Double

    init(_ p: TPOProfile, step: Double, valueArea: Double, ibPeriods: Int) {
        self.step = step
        let lowRow = Int(floor(p.low / step)), highRow = max(lowRow, Int(floor(p.high / step)))
        self.lowRow = lowRow
        self.highRow = highRow
        var cells = [[Int]](repeating: [], count: highRow - lowRow + 1)
        var ibL = Double.infinity, ibH = -Double.infinity
        for per in p.periods {
            let a = max(lowRow, Int(floor(per.l / step))), b = min(highRow, Int(floor(per.h / step)))
            if a <= b { for r in a...b { cells[r - lowRow].append(per.index) } }
            if per.index < ibPeriods { ibL = min(ibL, per.l); ibH = max(ibH, per.h) }
        }
        self.cells = cells
        self.ibLow = ibL.isFinite ? ibL : p.low
        self.ibHigh = ibH.isFinite ? ibH : p.high

        // POC: the row with the most TPOs; ties go to the one nearest the middle of the range.
        let counts = cells.map(\.count)
        let mid = Double(counts.count - 1) / 2
        var poc = 0
        for i in counts.indices where counts[i] > counts[poc] || (counts[i] == counts[poc] && abs(Double(i) - mid) < abs(Double(poc) - mid)) {
            poc = i
        }
        self.maxCount = counts.max() ?? 0
        self.poc = poc + lowRow

        // Value area: grow from the POC towards the side with more TPOs until it holds `valueArea` of them.
        let total = counts.reduce(0, +)
        var lo = poc, hi = poc, inside = counts.isEmpty ? 0 : counts[poc]
        while Double(inside) < Double(total) * valueArea {
            let up = hi + 1 < counts.count ? counts[hi + 1] : -1
            let down = lo - 1 >= 0 ? counts[lo - 1] : -1
            if up < 0 && down < 0 { break }
            if up >= down { hi += 1; inside += up } else { lo -= 1; inside += down }
        }
        self.vaLow = lo + lowRow
        self.vaHigh = hi + lowRow
    }

    func count(atRow r: Int) -> Int {
        guard r >= lowRow, r <= highRow else { return 0 }
        return cells[r - lowRow].count
    }

    var pocPrice: Double { (Double(poc) + 0.5) * step }
}

enum TPOLetters {
    static let all = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    static func letter(_ i: Int) -> String { String(all[((i % all.count) + all.count) % all.count]) }
}

extension AppModel {
    var tpoKey: String { "\(selectedCoin)|\(tpoSettings.period.rawValue)|\(tpoSettings.fetchDays)" }

    /// Period candles for the TPO chart (its own feed: the candle chart keeps its interval).
    func loadTPO() async {
        let coin = selectedCoin, s = tpoSettings, key = tpoKey
        tpoLoading = true
        defer { tpoLoading = false }
        let end = Date().timeIntervalSince1970 * 1000
        let start = end - Double(s.fetchDays) * 86_400_000
        let req = MP.map([("coin", .str(coin)), ("interval", .str(s.period.rawValue)),
                          ("startTime", .int(Int64(start))), ("endTime", .int(Int64(end)))])
        guard let j = try? await api.info(type: "candleSnapshot", [("req", req)]), key == tpoKey else { return }
        tpoCandles = j.array.map(Candle.init).sorted { $0.t < $1.t }
        tpoCandlesKey = key
    }

    /// Refreshes the last few periods (the profile of the running session keeps growing).
    func refreshTPOTail() async {
        let coin = selectedCoin, s = tpoSettings, key = tpoKey
        guard tpoCandlesKey == key else { await loadTPO(); return }
        let end = Date().timeIntervalSince1970 * 1000
        let start = end - s.period.seconds * 1000 * 3
        let req = MP.map([("coin", .str(coin)), ("interval", .str(s.period.rawValue)),
                          ("startTime", .int(Int64(start))), ("endTime", .int(Int64(end)))])
        guard let j = try? await api.info(type: "candleSnapshot", [("req", req)]), key == tpoKey, tpoCandlesKey == key else { return }
        let fresh = j.array.map(Candle.init).sorted { $0.t < $1.t }
        guard let first = fresh.first else { return }
        tpoCandles = tpoCandles.filter { $0.t < first.t } + fresh
    }
}
