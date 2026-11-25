import SwiftUI

/// Values kept between draws (a reference, so drawing does not invalidate the view).
final class TPOViewportCache {
    var lo = 0.0, hi = 0.0
    var candlesKey = ""
    var settings = TPOSettings()
    var profiles: [TPOProfile] = []
    var rowsStep = 0.0
    var rows: [Double: TPORows] = [:]
    var totalWidth: CGFloat = 0
    /// Columns of the last draw (profile index, left x, width) for the crosshair readout.
    var columns: [(i: Int, x0: CGFloat, w: CGFloat)] = []
}

/// Market Profile (TPO) chart: one column per session, each 30-minute (configurable) period printing a
/// block or letter at every price row it traded through. POC, value area, initial balance, single prints,
/// open / close and naked POCs are drawn as set in the TPO settings. Gestures follow the candle chart:
/// sideways drag scrolls sessions, pinch widens the blocks, the price scale and "A" work the same way.
struct TPOChartView: View {
    @Environment(AppModel.self) private var model
    let market: Market
    var lines: [PriceLine] = []
    var verticalSwipeScrollsPage = false

    @State private var cellW: CGFloat = CGFloat(UserDefaults.standard.object(forKey: "tpoCellWidth") as? Double ?? 5)
    @State private var offsetX: CGFloat = 0
    @State private var autoScale = true
    @State private var manualLo = 0.0
    @State private var manualHi = 1.0
    @State private var crosshair: CGPoint?
    @State private var cache = TPOViewportCache()
    @State private var dragKind: DragKind?
    @State private var startOffset: CGFloat = 0
    @State private var startLo = 0.0
    @State private var startHi = 1.0
    @State private var pinchStartW: CGFloat?

    private enum DragKind { case chart, priceAxis }
    private let axisW: CGFloat = 58
    private let timeH: CGFloat = 16
    private let gap: CGFloat = 16
    private let minCell: CGFloat = 2
    private let maxCell: CGFloat = 18

    var body: some View {
        let ready = model.tpoCandlesKey == model.tpoKey
        let candles = ready ? model.tpoCandles : []
        let settings = model.tpoSettings
        let last = model.lastPrice(market.id)
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                Canvas { ctx, sz in
                    draw(&ctx, size: sz, candles: candles, s: settings, last: last)
                }
                if let info = crosshairInfo(size, s: settings) {
                    Text(info)
                        .font(.system(size: 10, design: .monospaced))
                        .padding(4)
                        .background(Color.hlCard.opacity(0.92), in: RoundedRectangle(cornerRadius: 4))
                        .padding(4)
                }
                ChartTouchSurface(handlers: handlers(size))
                    .frame(width: size.width, height: size.height)
                Button { autoScale = true } label: {
                    Text("A")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 18, height: 18)
                        .foregroundStyle(autoScale ? Color.hlOnAccent : Color.hlMuted)
                        .background(autoScale ? Color.hlAccent : Color.hlCard2, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .position(x: size.width - 12, y: max(10, size.height - timeH - 12))
                if candles.isEmpty && model.tpoLoading {
                    ProgressView().frame(width: size.width, height: size.height)
                }
            }
        }
        .task(id: model.tpoKey) {
            await model.loadTPO()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(model.energySaving ? 60 : 15))
                if Task.isCancelled { break }
                await model.refreshTPOTail()
            }
        }
        .onChange(of: cellW) { _, w in UserDefaults.standard.set(Double(w), forKey: "tpoCellWidth") }
    }

    // MARK: Gestures

    private func handlers(_ size: CGSize) -> ChartTouchHandlers {
        ChartTouchHandlers(
            panShouldBegin: { start, delta in
                // In a scrolling page with auto-scale on, vertical swipes (except on the price scale) scroll the page.
                guard verticalSwipeScrollsPage, autoScale, crosshair == nil else { return true }
                if start.x > size.width - axisW && start.y < size.height - timeH { return true }
                return abs(delta.x) >= abs(delta.y)
            },
            panChanged: { start, t in dragChanged(start: start, translation: t, size: size) },
            panEnded: { _ in dragKind = nil },
            pinchChanged: { _, scale in
                if pinchStartW == nil { pinchStartW = cellW }
                cellW = min(maxCell, max(minCell, (pinchStartW ?? cellW) * scale))
            },
            pinchEnded: { pinchStartW = nil },
            crosshair: { crosshair = $0 },
            doubleTap: { _ in
                autoScale = true
                offsetX = 0
            }
        )
    }

    private func dragChanged(start: CGPoint, translation t: CGSize, size: CGSize) {
        guard crosshair == nil else { return }
        let plotW = size.width - axisW, mainH = max(1, size.height - timeH)
        if dragKind == nil {
            dragKind = start.x > plotW && start.y < mainH ? .priceAxis : .chart
            startOffset = offsetX
            startLo = autoScale ? cache.lo : manualLo
            startHi = autoScale ? cache.hi : manualHi
        }
        switch dragKind {
        case .priceAxis:
            // Drag down compresses (wider range), up stretches — around the middle of the scale.
            autoScale = false
            let factor = exp(Double(t.height) / 150)
            let c = (startLo + startHi) / 2, half = max(1e-12, (startHi - startLo) / 2 * factor)
            manualLo = c - half
            manualHi = c + half
        case .chart:
            offsetX = min(max(0, cache.totalWidth - plotW * 0.3), max(0, startOffset + t.width))
            if !autoScale {
                let shift = Double(t.height / mainH) * (startHi - startLo)
                manualLo = startLo + shift
                manualHi = startHi + shift
            } else if !verticalSwipeScrollsPage, abs(t.height) > 10, abs(t.height) > abs(t.width) * 1.5 {
                // Full screen: a vertical drag takes the price range off auto-scale.
                autoScale = false
                manualLo = startLo
                manualHi = startHi
            }
        case .none:
            break
        }
    }

    // MARK: Drawing

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, candles: [Candle], s: TPOSettings, last: Double) {
        PerfMonitor.chartDraws += 1
        let plotW = size.width - axisW, mainH = size.height - timeH
        guard plotW > 20, mainH > 20, let lastC = candles.last, let firstC = candles.first else {
            cache.columns = []
            return
        }
        let key = "\(candles.count)|\(firstC.t)|\(lastC.t)|\(lastC.h)|\(lastC.l)|\(lastC.c)"
        if cache.candlesKey != key || cache.settings != s {
            cache.profiles = TPOProfile.build(candles, settings: s)
            cache.candlesKey = key
            cache.settings = s
            cache.rows = [:]
            cache.rowsStep = 0
        }
        let profiles = cache.profiles
        guard let newest = profiles.last else { return }

        func stepFor(_ lo: Double, _ hi: Double) -> Double {
            CandleChart.niceStep((hi - lo) / Double(mainH) * s.density.rowHeight)
        }
        func rows(_ i: Int, _ step: Double) -> TPORows {
            if cache.rowsStep != step { cache.rows = [:]; cache.rowsStep = step }
            if let r = cache.rows[profiles[i].start] { return r }
            let r = TPORows(profiles[i], step: step, valueArea: s.valueArea, ibPeriods: s.ibPeriods)
            cache.rows[profiles[i].start] = r
            return r
        }
        // Columns from the right edge (newest session) to the left.
        func layout(_ step: Double) -> [(i: Int, x0: CGFloat, w: CGFloat)] {
            var out: [(i: Int, x0: CGFloat, w: CGFloat)] = []
            var right = plotW - 10 + offsetX
            for i in stride(from: profiles.count - 1, through: 0, by: -1) {
                let w = CGFloat(max(1, rows(i, step).maxCount)) * cellW
                let x0 = right - w
                if x0 < plotW { out.append((i, x0, w)) }
                right = x0 - gap
                if right < 0 { break }
            }
            return out
        }

        var lo = autoScale ? cache.lo : manualLo, hi = autoScale ? cache.hi : manualHi
        if !(hi > lo) { lo = newest.low; hi = newest.high }
        if !(hi > lo) { hi = lo * 1.001 + 1e-9 }
        var step = stepFor(lo, hi)
        var cols = layout(step)
        if autoScale, !cols.isEmpty {
            let vis = cols.map { profiles[$0.i] }
            let l = vis.map(\.low).min() ?? lo, h = vis.map(\.high).max() ?? hi
            let pad = max((h - l) * 0.06, abs(h) * 1e-5)
            lo = l - pad
            hi = h + pad
            step = stepFor(lo, hi)
            cols = layout(step)
        }
        cache.lo = lo
        cache.hi = hi
        cache.columns = cols
        cache.totalWidth = profiles.indices.reduce(CGFloat(0)) { $0 + CGFloat(max(1, rows($1, step).maxCount)) * cellW + gap }

        func y(_ p: Double) -> CGFloat { CGFloat((hi - p) / (hi - lo)) * mainH }
        let rowH = CGFloat(step / (hi - lo)) * mainH
        let dec = market.priceDecimals(last > 0 ? last : newest.close)

        // Grid and price axis.
        let gridColor = Color.hlInk.opacity(AppTheme.current.isDark ? 0.06 : 0.08)
        let gStep = CandleChart.niceStep((hi - lo) / Double(max(2, mainH / 45)))
        let gDec = max(dec, min(gStep < 1 ? Int(ceil(-log10(gStep) - 1e-9)) : 0, 8))
        if gStep > 0, (hi - lo) / gStep < 60 {
            var p = (lo / gStep).rounded(.up) * gStep
            while p <= hi {
                let yy = y(p)
                var path = Path()
                path.move(to: CGPoint(x: 0, y: yy)); path.addLine(to: CGPoint(x: plotW, y: yy))
                ctx.stroke(path, with: .color(gridColor), lineWidth: 1)
                if yy > 6, yy < mainH - 6 {
                    ctx.draw(Text(Fmt.price(p, decimals: gDec)).font(.system(size: 9, design: .monospaced)).foregroundColor(.hlMuted),
                             at: CGPoint(x: plotW + 4, y: yy), anchor: .leading)
                }
                p += gStep
            }
        }

        var main = ctx
        main.clip(to: Path(CGRect(x: 0, y: 0, width: plotW, height: mainH)))
        let letters = s.display == .letters && cellW >= 7 && rowH >= 8
        let pocColor = Color.orange
        let ibColor = Color.hlGreen
        let spColor = Color.yellow

        var labelLeft = CGFloat.infinity
        for col in cols {
            let p = profiles[col.i]
            let r = rows(col.i, step)
            let x0 = col.x0
            let perSession = max(1, Int((p.end - p.start) / s.period.seconds))

            // Value-area band behind the blocks.
            if s.showValueArea {
                let top = y(Double(r.vaHigh + 1) * step), bottom = y(Double(r.vaLow) * step)
                main.fill(Path(CGRect(x: x0 - 2, y: top, width: col.w + 4, height: max(1, bottom - top))),
                          with: .color(Color.hlAccent.opacity(0.07)))
            }

            var resolved: [Int: GraphicsContext.ResolvedText] = [:]
            for (k, list) in r.cells.enumerated() where !list.isEmpty {
                let row = r.lowRow + k
                let top = y(Double(row + 1) * step), bottom = y(Double(row) * step)
                if bottom < 0 || top > mainH { continue }
                let inVA = row >= r.vaLow && row <= r.vaHigh
                for (n, idx) in list.enumerated() {
                    let x = x0 + CGFloat(n) * cellW
                    let color = cellColor(idx, inVA: inVA, perSession: perSession, s: s)
                    if letters {
                        let t: GraphicsContext.ResolvedText
                        if let c = resolved[idx] { t = c } else {
                            t = main.resolve(Text(TPOLetters.letter(idx))
                                .font(.system(size: min(11, rowH - 1), weight: .semibold, design: .monospaced))
                                .foregroundColor(color))
                            resolved[idx] = t
                        }
                        main.draw(t, at: CGPoint(x: x + cellW / 2, y: (top + bottom) / 2), anchor: .center)
                    } else {
                        let inset: CGFloat = cellW >= 4 ? 1 : 0
                        let rect = CGRect(x: x, y: top + (rowH >= 4 ? 0.5 : 0), width: max(1, cellW - inset),
                                          height: max(1, bottom - top - (rowH >= 4 ? 1 : 0)))
                        main.fill(Path(rect), with: .color(color))
                    }
                }
                if s.showSinglePrints && list.count == 1 {
                    main.fill(Path(CGRect(x: x0 - 5, y: top, width: 2, height: max(1, bottom - top))), with: .color(spColor.opacity(0.8)))
                }
            }

            if s.showIB {
                var path = Path()
                path.move(to: CGPoint(x: x0 - 9, y: y(r.ibHigh))); path.addLine(to: CGPoint(x: x0 - 9, y: y(r.ibLow)))
                main.stroke(path, with: .color(ibColor.opacity(0.9)), lineWidth: 2)
            }
            if s.showValueArea {
                for row in [r.vaHigh + 1, r.vaLow] {
                    var path = Path()
                    let yy = y(Double(row) * step)
                    path.move(to: CGPoint(x: x0 - 2, y: yy)); path.addLine(to: CGPoint(x: x0 + col.w + 2, y: yy))
                    main.stroke(path, with: .color(Color.hlAccent.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                }
            }
            if s.showPOC {
                let yy = y(r.pocPrice)
                var path = Path()
                path.move(to: CGPoint(x: x0 - 2, y: yy)); path.addLine(to: CGPoint(x: x0 + col.w + 2, y: yy))
                main.stroke(path, with: .color(pocColor), lineWidth: 1.5)
            }
            // Naked POC: never traded again in a later session — extended to the right edge.
            if s.nakedPOC, col.i < profiles.count - 1 {
                let poc = r.pocPrice
                let touched = profiles[(col.i + 1)...].contains { q in
                    q.low <= poc && q.high >= poc && q.periods.contains { $0.l <= poc && $0.h >= poc }
                }
                if !touched {
                    let yy = y(poc)
                    var path = Path()
                    path.move(to: CGPoint(x: x0 + col.w + 2, y: yy)); path.addLine(to: CGPoint(x: plotW, y: yy))
                    main.stroke(path, with: .color(pocColor.opacity(0.55)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            if s.showOpenClose {
                let yo = y(p.open), yc = y(p.close)
                var o = Path()
                o.move(to: CGPoint(x: x0 - 13, y: yo)); o.addLine(to: CGPoint(x: x0 - 1, y: yo))
                main.stroke(o, with: .color(Color.hlInk.opacity(0.8)), lineWidth: 1.5)
                var c = Path()
                c.move(to: CGPoint(x: x0 + col.w + 1, y: yc)); c.addLine(to: CGPoint(x: x0 + col.w + 9, y: yc))
                main.stroke(c, with: .color(Color.hlInk.opacity(0.8)), lineWidth: 1.5)
            }

            // Session label under the column (skipped where it would overlap the next one).
            let label = main.resolve(Text(sessionLabel(p)).font(.system(size: 9)).foregroundColor(.hlMuted))
            let lw = label.measure(in: CGSize(width: 200, height: 20)).width
            let lx = max(0, x0)
            if lx + lw < labelLeft - 6 && lx < plotW {
                ctx.draw(label, at: CGPoint(x: lx, y: mainH + 3), anchor: .topLeading)
                labelLeft = lx
            }
        }

        // Price lines (entry, liquidation, orders, alerts) with the label on the left.
        for l in lines where l.price > lo && l.price < hi {
            let yy = y(l.price)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: yy)); path.addLine(to: CGPoint(x: plotW, y: yy))
            main.stroke(path, with: .color(l.color.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            let text = main.resolve(Text(l.label).font(.system(size: 9, weight: .semibold)).foregroundColor(l.color))
            let sz = text.measure(in: CGSize(width: plotW, height: 20))
            let pill = CGRect(x: 4, y: yy - sz.height / 2 - 2, width: sz.width + 8, height: sz.height + 4)
            main.fill(Path(roundedRect: pill, cornerRadius: 3), with: .color(Color.hlBg.opacity(0.85)))
            main.stroke(Path(roundedRect: pill, cornerRadius: 3), with: .color(l.color.opacity(0.6)), lineWidth: 0.5)
            main.draw(text, at: CGPoint(x: pill.minX + 4, y: yy), anchor: .leading)
        }

        // Last price.
        if last > 0 {
            let yy = y(last)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: yy)); path.addLine(to: CGPoint(x: plotW, y: yy))
            main.stroke(path, with: .color(Color.hlAccent.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            if yy > 0 && yy < mainH {
                ctx.fill(Path(roundedRect: CGRect(x: plotW + 1, y: yy - 8, width: axisW - 2, height: 16), cornerRadius: 3),
                         with: .color(Color.hlAccent))
                ctx.draw(Text(Fmt.price(last, decimals: dec)).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(.hlOnAccent),
                         at: CGPoint(x: plotW + 4, y: yy), anchor: .leading)
            }
        }

        // Crosshair.
        if let c = crosshair, c.y >= 0, c.y <= mainH {
            var path = Path()
            path.move(to: CGPoint(x: 0, y: c.y)); path.addLine(to: CGPoint(x: plotW, y: c.y))
            ctx.stroke(path, with: .color(Color.hlInk.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            let price = hi - Double(c.y / mainH) * (hi - lo)
            ctx.fill(Path(roundedRect: CGRect(x: plotW + 1, y: c.y - 8, width: axisW - 2, height: 16), cornerRadius: 3),
                     with: .color(Color.hlInk.opacity(0.85)))
            ctx.draw(Text(Fmt.price(price, decimals: gDec)).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(.hlBg),
                     at: CGPoint(x: plotW + 4, y: c.y), anchor: .leading)
        }
    }

    private func cellColor(_ idx: Int, inVA: Bool, perSession: Int, s: TPOSettings) -> Color {
        switch s.coloring {
        case .time:
            // Purple at the start of the session through blue and green to yellow at its end.
            let f = Double(min(idx, perSession - 1)) / Double(max(1, perSession - 1))
            return Color(hue: 0.78 - 0.63 * f, saturation: 0.6, brightness: 0.95)
        case .single:
            return Color.hlAccent.opacity(0.85)
        case .valueArea:
            return inVA ? Color.hlAccent.opacity(0.9) : Color.hlMuted.opacity(0.45)
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return f
    }()

    private func sessionLabel(_ p: TPOProfile) -> String {
        let d = Self.dayFormatter.string(from: Date(timeIntervalSince1970: p.start))
        if let n = p.name { return "\(n) \(d)" }
        return d
    }

    private func crosshairInfo(_ size: CGSize, s: TPOSettings) -> String? {
        guard let c = crosshair else { return nil }
        let mainH = size.height - timeH
        guard cache.hi > cache.lo, c.y >= 0, c.y <= mainH else { return nil }
        let price = cache.hi - Double(c.y / mainH) * (cache.hi - cache.lo)
        var parts = [Fmt.price(price)]
        if let col = cache.columns.first(where: { c.x >= $0.x0 - gap / 2 && c.x <= $0.x0 + $0.w + gap / 2 }),
           col.i < cache.profiles.count, let r = cache.rows[cache.profiles[col.i].start] {
            let p = cache.profiles[col.i]
            let row = Int(floor(price / r.step))
            parts.append(sessionLabel(p))
            parts.append(L("TPO {0}", r.count(atRow: row)))
            if row == r.poc { parts.append("POC") }
            parts.append("VA \(Fmt.price(Double(r.vaLow) * r.step))–\(Fmt.price(Double(r.vaHigh + 1) * r.step))")
        }
        return parts.joined(separator: " · ")
    }
}

/// All TPO options: session, period, value area, initial balance, look and overlays.
struct TPOSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    Picker(L("Session"), selection: $model.tpoSettings.session) {
                        ForEach(TPOSettings.Session.allCases) { Text($0.title).tag($0) }
                    }
                    if model.tpoSettings.session == .day {
                        Picker(L("Session start (UTC)"), selection: $model.tpoSettings.dayStartHour) {
                            ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                        }
                    }
                    Picker(L("Period (one letter)"), selection: $model.tpoSettings.period) {
                        ForEach(TPOSettings.periods) { Text($0.rawValue).tag($0) }
                    }
                    Picker(L("History"), selection: $model.tpoSettings.historyDays) {
                        ForEach(TPOSettings.historyChoices, id: \.self) { Text(L("{0} days", $0)).tag($0) }
                    }
                    Stepper(L("Value area: {0}%", Int((model.tpoSettings.valueArea * 100).rounded())),
                            value: $model.tpoSettings.valueArea, in: 0.5...0.95, step: 0.05)
                    Stepper(L("Initial balance: {0} periods", model.tpoSettings.ibPeriods),
                            value: $model.tpoSettings.ibPeriods, in: 1...6)
                } header: {
                    Text(L("Profile"))
                }
                Section {
                    Picker(L("Style"), selection: $model.tpoSettings.display) {
                        ForEach(TPOSettings.Display.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker(L("Color"), selection: $model.tpoSettings.coloring) {
                        ForEach(TPOSettings.Coloring.allCases) { Text($0.title).tag($0) }
                    }
                    Picker(L("Row size"), selection: $model.tpoSettings.density) {
                        ForEach(TPOSettings.Density.allCases) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text(L("Display"))
                } footer: {
                    Text(L("Letters appear when the blocks are large enough: pinch to widen them, or choose a coarser row size."))
                }
                Section {
                    Toggle(L("Point of control (POC)"), isOn: $model.tpoSettings.showPOC)
                    Toggle(L("Value area (VAH / VAL)"), isOn: $model.tpoSettings.showValueArea)
                    Toggle(L("Initial balance (IB)"), isOn: $model.tpoSettings.showIB)
                    Toggle(L("Single prints"), isOn: $model.tpoSettings.showSinglePrints)
                    Toggle(L("Open and close"), isOn: $model.tpoSettings.showOpenClose)
                    Toggle(L("Naked POCs"), isOn: $model.tpoSettings.nakedPOC)
                } header: {
                    Text(L("Show"))
                } footer: {
                    Text(L("POC — orange line; value area — shaded band with dashed edges; initial balance — green bar on the left; single prints — yellow marks; open / close — white ticks left / right; naked POC — a POC not traded again, extended to the right."))
                }
                Section {
                    Button(L("Reset to defaults"), role: .destructive) { model.tpoSettings = TPOSettings() }
                }
            }
            .navigationTitle(L("TPO settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } } }
        }
    }
}
