import SwiftUI

struct PriceLine: Identifiable {
    let id = UUID()
    let price: Double
    let color: Color
    let label: String
}

struct CandleChart: View {
    let candles: [Candle]
    let lines: [PriceLine]
    var layers = ChartLayers()
    var decimals: Int? = nil
    var showVolume = true
    var logScale = false
    var intervalSeconds: Double = 3600

    @State private var visible = 70
    @State private var offset = 0          // candles hidden on the right
    @State private var dragStartOffset: Int?
    @State private var zoomStart: Int?
    @State private var crosshair: CGPoint?
    /// Manual vertical zoom of the price scale (1 = auto). >1 compresses, <1 stretches.
    @State private var yScale: Double = 1
    @State private var yScaleStart: Double?

    private let axisW: CGFloat = 58
    private let timeH: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                // Redraw every second for the candle-close countdown.
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    Canvas { ctx, sz in draw(ctx: &ctx, size: sz, now: timeline.date) }
                }
                // No cross-fade between redraws (it made the countdown text look doubled).
                .transaction { $0.animation = nil }
                if let info = crosshairInfo(size: size) {
                    Text(info)
                        .font(.system(size: 10, design: .monospaced))
                        .padding(4)
                        .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4))
                        .padding(4)
                }
                priceAxisControl(size: size)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { v in
                        guard crosshair == nil else { return }
                        if dragStartOffset == nil { dragStartOffset = offset }
                        let cw = (size.width - axisW) / CGFloat(visible)
                        let delta = Int((v.translation.width / max(cw, 1)).rounded())
                        offset = clampOffset((dragStartOffset ?? 0) + delta)
                    }
                    .onEnded { _ in dragStartOffset = nil }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { v in
                        if zoomStart == nil { zoomStart = visible }
                        visible = min(300, max(15, Int(Double(zoomStart ?? 70) / v.magnification)))
                        offset = clampOffset(offset)
                    }
                    .onEnded { _ in zoomStart = nil }
            )
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.25)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .onChanged { v in
                        if case .second(true, let drag?) = v { crosshair = drag.location }
                    }
                    .onEnded { _ in crosshair = nil }
            )
        }
    }

    /// TradingView-style price axis: drag up/down to stretch/compress, double-tap for auto scale.
    private func priceAxisControl(size: CGSize) -> some View {
        let mainH = layout(size).mainH
        return Color.clear
            .frame(width: axisW, height: max(0, mainH))
            .contentShape(Rectangle())
            .offset(x: size.width - axisW)
            .highPriorityGesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { v in
                        if yScaleStart == nil { yScaleStart = yScale }
                        // Drag down compresses (wider range), drag up stretches.
                        yScale = min(20, max(0.05, (yScaleStart ?? 1) * exp(Double(v.translation.height) / 160)))
                    }
                    .onEnded { _ in yScaleStart = nil }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { yScale = 1 })
            .accessibilityLabel(L("Price scale"))
    }

    private func clampOffset(_ o: Int) -> Int { max(0, min(o, max(0, candles.count - 10))) }

    private var range: Range<Int> {
        let end = max(0, candles.count - offset)
        let start = max(0, end - visible)
        return start..<end
    }

    private struct Layout {
        var plotW: CGFloat
        var mainH: CGFloat
        var volTop: CGFloat
        var volH: CGFloat
        var paneTops: [CGFloat]
        var paneH: CGFloat
    }

    private func layout(_ size: CGSize) -> Layout {
        let avail = size.height - timeH
        let paneCount = CGFloat(layers.panes.count)
        let paneH = paneCount > 0 ? min(avail * 0.2, avail * 0.45 / paneCount) : 0
        let volH = showVolume ? avail * 0.12 : 0
        let mainH = avail - volH - paneH * paneCount
        var tops: [CGFloat] = []
        for i in 0..<layers.panes.count { tops.append(mainH + volH + CGFloat(i) * paneH) }
        return Layout(plotW: size.width - axisW, mainH: mainH, volTop: mainH, volH: volH, paneTops: tops, paneH: paneH)
    }

    private func draw(ctx: inout GraphicsContext, size: CGSize, now: Date) {
        let r = range
        guard !r.isEmpty else { return }
        let L0 = layout(size)
        let plotW = L0.plotW
        let s = candles[r]
        let cw = plotW / CGFloat(visible)
        let leftPad = CGFloat(visible - s.count) * cw
        let dec = decimals ?? Fmt.autoDecimals(s.last?.c ?? 1)
        func x(_ i: Int) -> CGFloat { leftPad + CGFloat(i - r.lowerBound) * cw + cw / 2 }

        // Price range: candles + Bollinger bands.
        var lo = s.map(\.l).min() ?? 0
        var hi = s.map(\.h).max() ?? 1
        for b in layers.bands {
            for i in r {
                if let u = b.up[i] { hi = max(hi, u) }
                if let l = b.low[i] { lo = min(lo, l) }
            }
        }
        if hi <= lo { hi = lo * 1.01 + 1e-9; lo = lo * 0.99 }
        let log = logScale && lo > 0
        if yScale != 1 {
            if log {
                let c = (Foundation.log(hi) + Foundation.log(lo)) / 2, half = (Foundation.log(hi) - Foundation.log(lo)) / 2 * yScale
                lo = Foundation.exp(c - half); hi = Foundation.exp(c + half)
            } else {
                let c = (hi + lo) / 2, half = (hi - lo) / 2 * yScale
                lo = c - half; hi = c + half
            }
        }
        if log {
            let span = Foundation.log(hi / lo)
            lo = lo * Foundation.exp(-span * 0.06); hi = hi * Foundation.exp(span * 0.06)
        } else {
            let pad = (hi - lo) * 0.06
            lo -= pad; hi += pad
        }
        let mainH = L0.mainH
        let logLo = Foundation.log(max(lo, 1e-12)), logHi = Foundation.log(max(hi, 1e-12))
        func y(_ p: Double) -> CGFloat {
            if log { return CGFloat((logHi - Foundation.log(max(p, 1e-12))) / (logHi - logLo)) * mainH }
            return CGFloat((hi - p) / (hi - lo)) * mainH
        }
        /// Inverse of y(): price at a fraction 0 (top) … 1 (bottom) of the main pane.
        func price(atFraction f: Double) -> Double {
            if log { return Foundation.exp(logHi - f * (logHi - logLo)) }
            return hi - f * (hi - lo)
        }

        // Axis rows taken by the last-price tag and the countdown under it.
        var reservedY: [CGFloat] = []
        if let last = s.last, offset == 0 {
            let ly = y(last.c)
            reservedY = [ly, ly + 16 <= mainH - 7 ? ly + 16 : ly - 16]
        }

        // Grid + price axis
        let gridColor = Color.white.opacity(0.06)
        for k in 0...4 {
            let p = price(atFraction: 1 - Double(k) / 4)
            let yy = y(p)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: yy)); path.addLine(to: CGPoint(x: plotW, y: yy))
            ctx.stroke(path, with: .color(gridColor), lineWidth: 1)
            let labelY = min(max(yy, 6), mainH - 6)
            if !reservedY.contains(where: { abs($0 - labelY) < 13 }) {
                ctx.draw(Text(Fmt.price(p, decimals: dec)).font(.system(size: 9, design: .monospaced)).foregroundColor(.hlMuted),
                         at: CGPoint(x: plotW + 4, y: labelY), anchor: .leading)
            }
        }
        if yScale != 1 {
            ctx.draw(Text(L("Double-tap: auto")).font(.system(size: 8)).foregroundColor(.hlMuted),
                     at: CGPoint(x: plotW + axisW / 2, y: mainH - 4), anchor: .bottom)
        }

        // Main pane (clipped)
        var main = ctx
        main.clip(to: Path(CGRect(x: 0, y: 0, width: plotW, height: mainH)))

        // Bollinger fill
        for b in layers.bands {
            var path = Path()
            var started = false
            for i in r { if let u = b.up[i] { let p = CGPoint(x: x(i), y: y(u)); if started { path.addLine(to: p) } else { path.move(to: p); started = true } } }
            for i in r.reversed() { if let l = b.low[i] { path.addLine(to: CGPoint(x: x(i), y: y(l))) } }
            if started { path.closeSubpath(); main.fill(path, with: .color(b.color.opacity(0.07))) }
        }

        // Volume profile (visible range), drawn behind the candles from the right edge.
        if let spec = layers.volumeProfile, let vp = VolumeProfile.compute(s, rows: spec.rows, valueArea: spec.valueArea) {
            drawVolumeProfile(&main, vp, spec: spec, plotW: plotW, y: y)
        }

        // Candles
        for i in r {
            let c = candles[i]
            let color = c.c >= c.o ? Color.hlGreen : Color.hlRed
            var wick = Path()
            wick.move(to: CGPoint(x: x(i), y: y(c.h)))
            wick.addLine(to: CGPoint(x: x(i), y: y(c.l)))
            main.stroke(wick, with: .color(color), lineWidth: 1)
            let top = y(max(c.o, c.c)), bot = y(min(c.o, c.c))
            main.fill(Path(CGRect(x: x(i) - cw * 0.35, y: top, width: max(1, cw * 0.7), height: max(1, bot - top))), with: .color(color))
        }

        // Indicator overlays
        for series in layers.overlays {
            strokeSeries(&main, series, r: r, x: x, y: y)
        }

        // Price lines (entry, liquidation, orders, alerts)
        for l in lines where l.price > lo && l.price < hi {
            let yy = y(l.price)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: yy)); path.addLine(to: CGPoint(x: plotW, y: yy))
            main.stroke(path, with: .color(l.color.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            main.draw(Text(l.label).font(.system(size: 9, weight: .semibold)).foregroundColor(l.color),
                      at: CGPoint(x: plotW - 4, y: yy - 7), anchor: .trailing)
        }

        // Last price tag
        if let last = s.last, offset == 0 {
            let yy = y(last.c)
            let color = last.c >= last.o ? Color.hlGreen : Color.hlRed
            var path = Path()
            path.move(to: CGPoint(x: 0, y: yy)); path.addLine(to: CGPoint(x: plotW, y: yy))
            main.stroke(path, with: .color(color.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            if yy > 0 && yy < mainH {
                ctx.fill(Path(roundedRect: CGRect(x: plotW + 1, y: yy - 8, width: axisW - 2, height: 16), cornerRadius: 3), with: .color(color))
                ctx.draw(Text(Fmt.price(last.c, decimals: dec)).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(.black),
                         at: CGPoint(x: plotW + 4, y: yy), anchor: .leading)
                // Time left until the current candle closes.
                let remaining = Int(last.t / 1000 + intervalSeconds - now.timeIntervalSince1970)
                if remaining > 0 {
                    let text = remaining >= 3600 ? Fmt.countdown(remaining) : String(format: "%02d:%02d", remaining / 60, remaining % 60)
                    // Below the price tag, or above it near the bottom edge.
                    let ty = yy + 16 <= mainH - 7 ? yy + 16 : yy - 16
                    // Opaque so nothing on the axis shows through.
                    let box = Path(roundedRect: CGRect(x: plotW + 1, y: ty - 7, width: axisW - 2, height: 14), cornerRadius: 3)
                    ctx.fill(box, with: .color(.hlBg))
                    ctx.fill(box, with: .color(color.opacity(0.3)))
                    ctx.draw(Text(text).font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundColor(.white),
                             at: CGPoint(x: plotW + 4, y: ty), anchor: .leading)
                }
            }
        }

        // Legend
        var lx: CGFloat = 4
        for (name, color) in layers.legend {
            let t = ctx.resolve(Text(name).font(.system(size: 9, weight: .semibold)).foregroundColor(color))
            let w = t.measure(in: CGSize(width: 300, height: 20)).width
            if lx + w > plotW - 4 { break }
            ctx.draw(t, at: CGPoint(x: lx, y: 8), anchor: .leading)
            lx += w + 8
        }

        // Volume
        if showVolume && L0.volH > 0 {
            let maxV = s.map(\.v).max() ?? 1
            for i in r {
                let c = candles[i]
                let h = maxV > 0 ? CGFloat(c.v / maxV) * (L0.volH - 2) : 0
                let rect = CGRect(x: x(i) - cw * 0.35, y: L0.volTop + L0.volH - h, width: max(1, cw * 0.7), height: h)
                ctx.fill(Path(rect), with: .color((c.c >= c.o ? Color.hlGreen : Color.hlRed).opacity(0.3)))
            }
        }

        // Indicator panes
        for (pi, pane) in layers.panes.enumerated() {
            drawPane(&ctx, pane, top: L0.paneTops[pi], height: L0.paneH, plotW: plotW, r: r, x: x)
        }

        // Time axis
        let fmt = DateFormatter()
        let span = (s.last?.t ?? 0) - (s.first?.t ?? 0)
        fmt.dateFormat = span > 3 * 86_400_000 ? "dd.MM" : "HH:mm"
        let step = max(1, s.count / 4)
        for i in r where (i - r.lowerBound) % step == step / 2 {
            ctx.draw(Text(fmt.string(from: Date(timeIntervalSince1970: candles[i].t / 1000))).font(.system(size: 9)).foregroundColor(.hlMuted),
                     at: CGPoint(x: x(i), y: size.height - timeH / 2))
        }

        // Crosshair
        if let p = crosshair, p.x < plotW, p.y < size.height - timeH {
            var path = Path()
            path.move(to: CGPoint(x: p.x, y: 0)); path.addLine(to: CGPoint(x: p.x, y: size.height - timeH))
            path.move(to: CGPoint(x: 0, y: p.y)); path.addLine(to: CGPoint(x: plotW, y: p.y))
            ctx.stroke(path, with: .color(.white.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            if p.y < mainH {
                let crossPrice = price(atFraction: Double(p.y / mainH))
                ctx.fill(Path(roundedRect: CGRect(x: plotW + 1, y: p.y - 8, width: axisW - 2, height: 16), cornerRadius: 3), with: .color(.white))
                ctx.draw(Text(Fmt.price(crossPrice, decimals: dec)).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(.black),
                         at: CGPoint(x: plotW + 4, y: p.y), anchor: .leading)
            }
        }
    }

    private func drawVolumeProfile(_ ctx: inout GraphicsContext, _ vp: VolumeProfile, spec: VolumeProfileSpec,
                                   plotW: CGFloat, y: (Double) -> CGFloat) {
        let total = vp.total
        let maxV = total.max() ?? 0
        guard maxV > 0 else { return }
        let maxW = plotW * CGFloat(spec.widthFraction)
        for b in 0..<total.count where total[b] > 0 {
            let top = y(vp.lo + Double(b + 1) * vp.step)
            let bottom = y(vp.lo + Double(b) * vp.step)
            let h = max(1, bottom - top - 1)
            let inVA = b >= vp.vaLow && b <= vp.vaHigh
            let alpha: Double = inVA ? 0.38 : 0.16
            let wBuy = maxW * CGFloat(vp.buy[b] / maxV)
            let wSell = maxW * CGFloat(vp.sell[b] / maxV)
            // Sell part at the far right, buy part to its left.
            ctx.fill(Path(CGRect(x: plotW - wSell, y: top, width: wSell, height: h)), with: .color(Color.hlRed.opacity(alpha)))
            ctx.fill(Path(CGRect(x: plotW - wSell - wBuy, y: top, width: wBuy, height: h)), with: .color(Color.hlGreen.opacity(alpha)))
        }
        // POC and value-area boundaries
        let pocY = y(vp.lo + (Double(vp.poc) + 0.5) * vp.step)
        var poc = Path()
        poc.move(to: CGPoint(x: 0, y: pocY)); poc.addLine(to: CGPoint(x: plotW, y: pocY))
        ctx.stroke(poc, with: .color(spec.color), lineWidth: 1.2)
        let labelX = max(4, plotW - maxW - 4)
        ctx.draw(Text("POC").font(.system(size: 8, weight: .bold)).foregroundColor(spec.color),
                 at: CGPoint(x: labelX, y: pocY - 6), anchor: .trailing)
        for (price, label) in [(vp.lo + Double(vp.vaHigh + 1) * vp.step, "VAH"), (vp.lo + Double(vp.vaLow) * vp.step, "VAL")] {
            let yy = y(price)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: yy)); path.addLine(to: CGPoint(x: plotW, y: yy))
            ctx.stroke(path, with: .color(spec.color.opacity(0.6)), style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
            ctx.draw(Text(label).font(.system(size: 8, weight: .semibold)).foregroundColor(spec.color.opacity(0.8)),
                     at: CGPoint(x: labelX, y: yy - 6), anchor: .trailing)
        }
    }

    private func strokeSeries(_ ctx: inout GraphicsContext, _ series: ChartSeries, r: Range<Int>,
                              x: (Int) -> CGFloat, y: (Double) -> CGFloat) {
        var path = Path()
        var started = false
        for i in r {
            guard i < series.values.count, let v = series.values[i] else { started = false; continue }
            let p = CGPoint(x: x(i), y: y(v))
            if started { path.addLine(to: p) } else { path.move(to: p); started = true }
        }
        let style = series.dashed ? StrokeStyle(lineWidth: series.width, dash: [4, 3]) : StrokeStyle(lineWidth: series.width, lineJoin: .round)
        ctx.stroke(path, with: .color(series.color), style: style)
    }

    private func drawPane(_ ctx: inout GraphicsContext, _ pane: ChartPane, top: CGFloat, height: CGFloat,
                          plotW: CGFloat, r: Range<Int>, x: (Int) -> CGFloat) {
        // Separator
        var sep = Path()
        sep.move(to: CGPoint(x: 0, y: top)); sep.addLine(to: CGPoint(x: plotW + axisW, y: top))
        ctx.stroke(sep, with: .color(.white.opacity(0.12)), lineWidth: 1)

        var lo: Double, hi: Double
        if let fr = pane.fixedRange {
            lo = fr.0; hi = fr.1
        } else {
            var m = 0.0
            for line in pane.lines { for i in r where i < line.values.count { if let v = line.values[i] { m = max(m, abs(v)) } } }
            if let h = pane.histogram { for i in r where i < h.count { if let v = h[i] { m = max(m, abs(v)) } } }
            if m == 0 { m = 1 }
            lo = -m * 1.1; hi = m * 1.1
        }
        let inner = height - 4
        func y(_ v: Double) -> CGFloat { top + 2 + CGFloat((hi - v) / (hi - lo)) * inner }

        var pctx = ctx
        pctx.clip(to: Path(CGRect(x: 0, y: top, width: plotW, height: height)))

        for lv in pane.levels {
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y(lv))); path.addLine(to: CGPoint(x: plotW, y: y(lv)))
            pctx.stroke(path, with: .color(.white.opacity(0.18)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            ctx.draw(Text(Fmt.input(lv, 2)).font(.system(size: 8, design: .monospaced)).foregroundColor(.hlMuted),
                     at: CGPoint(x: plotW + 4, y: y(lv)), anchor: .leading)
        }

        if let h = pane.histogram {
            let cw = plotW / CGFloat(visible)
            let zero = y(0)
            for i in r where i < h.count {
                guard let v = h[i] else { continue }
                let yy = y(v)
                let rect = CGRect(x: x(i) - cw * 0.35, y: min(yy, zero), width: max(1, cw * 0.7), height: max(1, abs(zero - yy)))
                pctx.fill(Path(rect), with: .color((v >= 0 ? Color.hlGreen : Color.hlRed).opacity(0.55)))
            }
        }
        for line in pane.lines { strokeSeries(&pctx, line, r: r, x: x, y: y) }

        // Title with the latest value
        var title = pane.title
        if let first = pane.lines.first, let v = lastValue(first.values, before: r.upperBound) {
            title += "  " + Fmt.num(v, abs(v) >= 100 ? 1 : (abs(v) >= 1 ? 2 : 4))
        }
        ctx.draw(Text(title).font(.system(size: 9, weight: .semibold)).foregroundColor(pane.titleColor),
                 at: CGPoint(x: 4, y: top + 8), anchor: .leading)
    }

    private func lastValue(_ values: [Double?], before end: Int) -> Double? {
        var i = min(end, values.count) - 1
        while i >= 0 {
            if let v = values[i] { return v }
            i -= 1
        }
        return nil
    }

    private func crosshairInfo(size: CGSize) -> String? {
        guard let p = crosshair else { return nil }
        let r = range
        guard !r.isEmpty else { return nil }
        let plotW = size.width - axisW
        let cw = plotW / CGFloat(visible)
        let leftPad = CGFloat(visible - r.count) * cw
        let idx = r.lowerBound + Int((p.x - leftPad) / cw)
        guard r.contains(idx) else { return nil }
        let c = candles[idx]
        let d = decimals ?? Fmt.autoDecimals(c.c)
        let ch = c.o > 0 ? c.c / c.o - 1 : 0
        return "\(Fmt.dateTime(Date(timeIntervalSince1970: c.t / 1000)))  O \(Fmt.price(c.o, decimals: d)) H \(Fmt.price(c.h, decimals: d)) L \(Fmt.price(c.l, decimals: d)) C \(Fmt.price(c.c, decimals: d)) \(Fmt.pct(ch))  V \(Fmt.compact(c.v))"
    }
}
