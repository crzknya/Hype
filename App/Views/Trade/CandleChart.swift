import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

struct PriceLine: Identifiable {
    let id = UUID()
    let price: Double
    let color: Color
    let label: String
    /// Also a price tag on the scale (alerts).
    var onAxis = false
}

/// Values from the last draw, read by gestures (a reference so drawing does not invalidate the view).
final class ChartViewportCache {
    var lo = 0.0, hi = 1.0          // price range in scale units (log when log scale)
    var plotW: CGFloat = 300
    var mainH: CGFloat = 200
    var log = false
}

/// What the chart needs to show and edit drawings (nil = a chart without drawings).
struct ChartDrawingContext {
    var drawings: [ChartDrawing]
    var tool: DrawTool
    var selected: UUID?
    var magnet: MagnetMode
    var hidden: Bool
    /// Adds or updates a drawing.
    var commit: (ChartDrawing) -> Void
    var select: (UUID?) -> Void
    /// A one-shot tool finished: back to the cursor.
    var toolDone: () -> Void
    /// Picking a time on the chart (anchored VWAP start): a tap returns the candle time (ms).
    var pickTime: ((Double) -> Void)? = nil
}

/// Candle chart that behaves like TradingView:
/// - auto-scale (the "A" button) fits the visible candles; dragging the price axis or the chart vertically
///   switches it off and the price range then stays where you put it; double tap on the price axis or "A"
///   turns it back on;
/// - smooth horizontal scroll with inertia, pinch-zoom around the fingers, drag on the time axis zooms from
///   the right edge; while scrolled back in history new candles do not move the view; older candles are
///   loaded when you reach the left edge;
/// - round price levels and time labels on hour / day boundaries.
struct CandleChart: View {
    let candles: [Candle]
    let lines: [PriceLine]
    var layers = ChartLayers()
    var decimals: Int? = nil
    var showVolume = true
    var logScale = false
    var intervalSeconds: Double = 3600
    /// Close time (seconds) of a candle from its open time; calendar months are not fixed-length.
    var closeTime: ((Double) -> Double)? = nil
    /// Called when the view nears the oldest loaded candle.
    var onNeedHistory: (() -> Void)? = nil
    /// Bar width to start with (kept across markets and intervals, as TradingView) and its change callback.
    var initialSpacing: CGFloat? = nil
    var onSpacingChange: ((CGFloat) -> Void)? = nil
    /// Inside a scrolling page: with auto-scale on, a vertical swipe scrolls the page instead of the price range.
    var verticalSwipeScrollsPage = false
    /// Seconds between redraws for the candle-close countdown (longer in energy saving).
    var clockInterval: Double = 1
    /// Log-scale toggle shown next to "A" under the price scale (as TradingView's "log" / "auto").
    var onToggleLog: (() -> Void)? = nil
    /// Drawing tools: ruler, lines, rectangles, Fibonacci.
    var drawing: ChartDrawingContext? = nil
    /// Dashed line across the chart at the last price (the tag on the scale always stays).
    var showLastPriceLine = true

    static let defaultSpacing: CGFloat = 6
    static let defaultRightOffset: CGFloat = 4

    /// Pixels per bar and empty bars to the right of the last candle (negative = scrolled back in history).
    @State private var spacing: CGFloat = CandleChart.defaultSpacing
    @State private var rightOffset: CGFloat = CandleChart.defaultRightOffset
    @State private var autoScale = true
    @State private var manualLo = 0.0
    @State private var manualHi = 1.0
    @State private var cache = ChartViewportCache()
    // Gesture state
    @State private var dragKind: DragKind?
    @State private var startSpacing: CGFloat = 0
    @State private var startRight: CGFloat = 0
    @State private var startLo = 0.0
    @State private var startHi = 1.0
    @State private var verticalBase: CGFloat?
    /// Direction chosen by the first movement of a chart drag (TradingView-like axis lock).
    @State private var panAxis: PanAxis?
    @State private var pinchStart: (spacing: CGFloat, right: CGFloat, x: CGFloat)?
    @State private var momentum: Task<Void, Never>?
    @State private var crosshair: CGPoint?
    // Drawing state: a measurement, the drawing being created or moved, the first tapped point.
    @State private var ruler: (a: ChartPoint, b: ChartPoint)?
    @State private var draft: ChartDrawing?
    @State private var pendingA: ChartPoint?
    @State private var createStart: ChartPoint?
    @State private var editStart: ChartDrawing?
    @State private var editHandle = -1
    /// Ruler end being adjusted (0 = start, 1 = end) and where that handle was when the drag began.
    @State private var rulerHandle = 0
    @State private var rulerHandleStart: CGPoint = .zero

    private enum DragKind { case chart, priceAxis, timeAxis, create, edit, rulerEdit }
    private enum PanAxis { case horizontal, vertical, free }

    private let axisW: CGFloat = 58
    private let timeH: CGFloat = 14
    private let minSpacing: CGFloat = 1.5
    private let maxSpacing: CGFloat = 40

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let mainH = layout(size).mainH
            ZStack(alignment: .topLeading) {
                // Redraw every second (every few in energy saving) for the candle-close countdown.
                TimelineView(.periodic(from: .now, by: clockInterval)) { timeline in
                    Canvas { ctx, sz in draw(ctx: &ctx, size: sz, now: timeline.date) }
                }
                // No cross-fade between redraws (it made the countdown text look doubled).
                .transaction { $0.animation = nil }
                if let info = crosshairInfo(size: size) {
                    Text(info)
                        .font(.system(size: 10, design: .monospaced))
                        .padding(4)
                        .background(Color.hlCard.opacity(0.92), in: RoundedRectangle(cornerRadius: 4))
                        .padding(4)
                }
                // All touches go through one UIKit view: a SwiftUI drag inside the page's ScrollView would always
                // take vertical swipes from it, a UIKit pan can decline them.
                ChartTouchSurface(handlers: touchHandlers(size))
                    .frame(width: size.width, height: size.height)
                // Auto-scale toggle, as TradingView's "A" under the price scale.
                Button {
                    autoScale = true
                } label: {
                    Text("A")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 18, height: 18)
                        .foregroundStyle(autoScale ? Color.hlOnAccent : Color.hlMuted)
                        .background(autoScale ? Color.hlAccent : Color.hlCard2, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .position(x: size.width - 12, y: max(10, mainH - 12))
                if let onToggleLog {
                    Button(action: onToggleLog) {
                        Text("LOG")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 30, height: 18)
                            .foregroundStyle(logScale ? Color.hlOnAccent : Color.hlMuted)
                            .background(logScale ? Color.hlAccent : Color.hlCard2, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("Logarithmic scale"))
                    .position(x: size.width - 24 - 4 - 15, y: max(10, mainH - 12))
                }
            }
            .onChange(of: candles.last?.t) { old, new in
                // A new candle while scrolled back in history: keep the same candles on screen.
                guard let old, let new, new > old, rightOffset < 0 else { return }
                let added = max(1, Int(((new - old) / 1000 / max(intervalSeconds, 1)).rounded()))
                rightOffset -= CGFloat(added)
            }
            .onChange(of: logScale) { _, _ in autoScale = true }
            .onChange(of: drawing?.tool) { _, tool in
                pendingA = nil
                if tool != .ruler { ruler = nil }
            }
            .onAppear { if let s0 = initialSpacing { spacing = min(maxSpacing, max(minSpacing, s0)) } }
            .onChange(of: spacing) { _, s1 in onSpacingChange?(s1) }
        }
    }

    // MARK: Gestures

    private func touchHandlers(_ size: CGSize) -> ChartTouchHandlers {
        let mainH = layout(size).mainH
        return ChartTouchHandlers(
            panShouldBegin: { start, delta in shouldBeginPan(start: start, velocity: delta, size: size) },
            panChanged: { start, translation in dragChanged(start: start, translation: translation, size: size) },
            panEnded: { vx in dragEnded(velocityX: vx, size: size) },
            pinchChanged: { anchorX, scale in
                stopMomentum()
                let plotW = size.width - axisW
                if pinchStart == nil { pinchStart = (spacing, rightOffset, min(anchorX, plotW)) }
                guard let p = pinchStart else { return }
                let s2 = min(maxSpacing, max(minSpacing, p.spacing * scale))
                // Keep the bar under the fingers in place: last − i = (plotW − x) / spacing − rightOffset − 0.5.
                spacing = s2
                rightOffset = clampRight(p.right - (plotW - p.x) / p.spacing + (plotW - p.x) / s2, plotW: plotW)
                requestHistoryIfNeeded(plotW: plotW)
            },
            pinchEnded: { pinchStart = nil },
            crosshair: { crosshair = $0 },
            tap: { loc in handleTap(loc, size: size) },
            doubleTap: { loc in
                if loc.x > size.width - axisW && loc.y < mainH {
                    autoScale = true                              // double tap on the price axis
                } else {
                    stopMomentum()
                    autoScale = true
                    rightOffset = CandleChart.defaultRightOffset  // back to the latest candles
                }
            }
        )
    }

    /// A chart drag starts unless, inside a scrolling page with auto-scale on, it begins as a vertical swipe
    /// anywhere but the price scale: that one goes to the page. Drags on the price scale, with the crosshair
    /// or with auto-scale off always stay on the chart.
    private func shouldBeginPan(start: CGPoint, velocity: CGPoint, size: CGSize) -> Bool {
        // A drawing tool, or a drag on the selected drawing, keeps every direction on the chart.
        if let dc = drawing {
            if rulerHandleHit(start) != nil { return true }
            if dc.tool != .cursor { return true }
            if let h = hitTest(start), h.id == dc.selected { return true }
        }
        guard verticalSwipeScrollsPage, autoScale, crosshair == nil else { return true }
        let plotW = size.width - axisW
        let mainH = layout(size).mainH
        // Only the price scale keeps vertical drags (it changes the scale); everywhere else they scroll the page.
        if start.x > plotW && start.y < mainH { return true }
        return abs(velocity.x) >= abs(velocity.y)
    }

    private func dragChanged(start: CGPoint, translation: CGSize, size: CGSize) {
        guard crosshair == nil else { return }
        let plotW = size.width - axisW
        let mainH = max(1, layout(size).mainH)
        if dragKind == nil, let dc = drawing, start.x <= plotW, start.y <= mainH, beginDrawingDrag(dc, start: start) {
            stopMomentum()
        }
        if dragKind == nil {
            stopMomentum()
            let p = start
            dragKind = p.x > plotW && p.y < mainH ? .priceAxis : (p.y > size.height - timeH ? .timeAxis : .chart)
            startSpacing = spacing
            startRight = rightOffset
            startLo = autoScale ? cache.lo : manualLo
            startHi = autoScale ? cache.hi : manualHi
            verticalBase = nil
            // In a page, a chart drag with auto-scale on only began because it was sideways.
            if dragKind == .chart && autoScale && verticalSwipeScrollsPage { panAxis = .horizontal }
        }
        switch dragKind {
        case .create, .edit, .rulerEdit:
            drawingDragChanged(start: start, translation: translation)
        case .priceAxis:
            // Drag down compresses (wider range), up stretches — around the middle of the scale.
            autoScale = false
            let factor = exp(Double(translation.height) / 150)
            let c = (startLo + startHi) / 2, half = max(1e-12, (startHi - startLo) / 2 * factor)
            manualLo = c - half; manualHi = c + half
        case .timeAxis:
            // Drag right = fewer, wider bars; anchored to the right edge.
            spacing = min(maxSpacing, max(minSpacing, startSpacing * exp(translation.width / 150)))
            rightOffset = clampRight(startRight, plotW: plotW)
            requestHistoryIfNeeded(plotW: plotW)
        case .chart:
            // The first ~10 pt decide the direction: a sideways swipe only scrolls time (auto-scale
            // stays on and keeps fitting the visible candles); a clearly vertical drag moves the price
            // range and turns auto-scale off (full screen; in a page it scrolls the page instead).
            let dx = translation.width, dy = translation.height
            // Auto-scale already off: free panning in both directions at once.
            if panAxis == nil && !autoScale {
                panAxis = .free
                verticalBase = 0
            }
            if panAxis == nil, hypot(dx, dy) > 10 {
                panAxis = abs(dy) > abs(dx) * 1.5 ? .vertical : .horizontal
                if panAxis == .vertical {
                    verticalBase = dy
                    autoScale = false
                    manualLo = startLo; manualHi = startHi
                }
            }
            switch panAxis {
            case .horizontal:
                rightOffset = clampRight(startRight - dx / spacing, plotW: plotW)
                requestHistoryIfNeeded(plotW: plotW)
            case .vertical:
                let shift = Double((dy - (verticalBase ?? 0)) / mainH) * (startHi - startLo)
                manualLo = startLo + shift; manualHi = startHi + shift
            case .free:
                rightOffset = clampRight(startRight - dx / spacing, plotW: plotW)
                let shift = Double(dy / mainH) * (startHi - startLo)
                manualLo = startLo + shift; manualHi = startHi + shift
                requestHistoryIfNeeded(plotW: plotW)
            case .none:
                break
            }
        case .none:
            break
        }
    }

    private func dragEnded(velocityX: CGFloat, size: CGSize) {
        if dragKind == .create || dragKind == .edit || dragKind == .rulerEdit { drawingDragEnded() }
        if dragKind == .chart && (panAxis == .horizontal || panAxis == .free) {
            // Inertia: continue with the release speed and decelerate.
            startMomentum(velocity: velocityX, plotW: size.width - axisW)
        }
        dragKind = nil
        verticalBase = nil
        panAxis = nil
    }

    private func startMomentum(velocity: CGFloat, plotW: CGFloat) {
        stopMomentum()
        guard abs(velocity) > 60 else { return }
        momentum = Task { @MainActor in
            var vx = velocity
            while !Task.isCancelled && abs(vx) > 20 {
                let before = rightOffset
                rightOffset = clampRight(rightOffset - vx / 60 / spacing, plotW: plotW)
                if rightOffset == before { break }
                requestHistoryIfNeeded(plotW: plotW)
                vx *= 0.93
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func stopMomentum() {
        momentum?.cancel()
        momentum = nil
    }

    /// Up to a third of the width as empty space on the right; at least 3 candles on screen on the left.
    private func clampRight(_ r: CGFloat, plotW: CGFloat) -> CGFloat {
        let maxR = max(CandleChart.defaultRightOffset, plotW / spacing / 3)
        let minR = -CGFloat(max(0, candles.count - 3))
        return min(maxR, max(minR, r))
    }

    private func requestHistoryIfNeeded(plotW: CGFloat) {
        let firstVisible = CGFloat(candles.count - 1) + rightOffset + 0.5 - plotW / spacing
        if firstVisible < 60 { onNeedHistory?() }
    }

    // MARK: Layout

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

    /// Visible candle indices for the current scroll / zoom.
    /// x(i) = plotW − (last − i + rightOffset + 0.5) · spacing, so the right edge is at index
    /// last + rightOffset + 0.5 and the left edge `plotW / spacing` bars before it.
    private func visibleRange(plotW: CGFloat) -> Range<Int> {
        let last = candles.count - 1
        guard last >= 0 else { return 0..<0 }
        let rightEdge = CGFloat(last) + rightOffset + 0.5
        let hiIdx = min(last, Int(ceil(rightEdge)))
        let loIdx = max(0, Int(floor(rightEdge - plotW / spacing)) - 1)
        return loIdx <= hiIdx ? loIdx..<(hiIdx + 1) : 0..<0
    }

    /// Round step (1, 2, 2.5, 5 × 10^k) at least `raw`.
    static func niceStep(_ raw: Double) -> Double {
        guard raw > 0, raw.isFinite else { return 1 }
        let p = pow(10, floor(log10(raw)))
        let m = raw / p
        let n: Double = m <= 1 ? 1 : m <= 2 ? 2 : m <= 2.5 ? 2.5 : m <= 5 ? 5 : 10
        return n * p
    }

    private static let timeFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return f
    }()

    // MARK: Drawing

    private func draw(ctx: inout GraphicsContext, size: CGSize, now: Date) {
        PerfMonitor.chartDraws += 1
        let L0 = layout(size)
        let plotW = L0.plotW
        let r = visibleRange(plotW: plotW)
        guard !r.isEmpty else { return }
        let lastIdx = candles.count - 1
        let cw = spacing
        let s = candles[r]
        let dec = decimals ?? Fmt.autoDecimals(s.last?.c ?? 1)
        func x(_ i: Int) -> CGFloat { plotW - (CGFloat(lastIdx - i) + rightOffset + 0.5) * spacing }
        let log = logScale && (s.map(\.l).min() ?? 0) > 0
        func toScale(_ p: Double) -> Double { log ? Foundation.log(max(p, 1e-12)) : p }
        func fromScale(_ v: Double) -> Double { log ? Foundation.exp(v) : v }

        // Price range in scale units: auto (visible candles + bands, TradingView margins 10% / 8%) or manual.
        var loS: Double, hiS: Double
        if autoScale {
            var lo = Double.greatestFiniteMagnitude, hi = -Double.greatestFiniteMagnitude
            for i in r where x(i) > -cw && x(i) < plotW + cw {
                lo = min(lo, candles[i].l); hi = max(hi, candles[i].h)
            }
            for b in layers.bands {
                for i in r {
                    if i < b.up.count, let u = b.up[i] { hi = max(hi, u) }
                    if i < b.low.count, let l = b.low[i] { lo = min(lo, l) }
                }
            }
            if lo > hi { lo = s.map(\.l).min() ?? 0; hi = s.map(\.h).max() ?? 1 }
            loS = toScale(lo); hiS = toScale(hi)
            if hiS <= loS { let d = max(abs(hiS) * 0.01, 1e-9); loS -= d; hiS += d }
            let span = hiS - loS
            hiS += span * 0.10 / 0.82
            loS -= span * 0.08 / 0.82
        } else {
            loS = manualLo; hiS = manualHi
        }
        cache.lo = loS; cache.hi = hiS; cache.plotW = plotW; cache.mainH = L0.mainH; cache.log = log
        let mainH = L0.mainH
        func y(_ p: Double) -> CGFloat { CGFloat((hiS - toScale(p)) / (hiS - loS)) * mainH }
        let lo = fromScale(loS), hi = fromScale(hiS)
        /// Price at a fraction 0 (top) … 1 (bottom) of the main pane.
        func price(atFraction f: Double) -> Double { fromScale(hiS - f * (hiS - loS)) }

        // Axis rows taken by the last-price tag and the countdown under it.
        let lastVisible = r.contains(lastIdx)
        var reservedY: [CGFloat] = []
        if let last = candles.last, lastVisible {
            let ly = y(last.c)
            reservedY = [ly, ly + 16 <= mainH - 7 ? ly + 16 : ly - 16]
        }

        // Grid + price axis on round levels (about one every 45 pt).
        let gridColor = Color.hlInk.opacity(AppTheme.current.isDark ? 0.06 : 0.08)
        let step = CandleChart.niceStep((hi - lo) / Double(max(2, mainH / 45)))
        let stepDec = step < 1 ? Int(ceil(-log10(step) - 1e-9)) : 0
        let labelDec = max(dec, min(stepDec, 8))
        if step > 0, (hi - lo) / step < 60 {
            var p = (lo / step).rounded(.up) * step
            while p <= hi {
                let yy = y(p)
                var path = Path()
                path.move(to: CGPoint(x: 0, y: yy)); path.addLine(to: CGPoint(x: plotW, y: yy))
                ctx.stroke(path, with: .color(gridColor), lineWidth: 1)
                // Not under the LOG / A buttons at the bottom of the scale.
                if yy > 6, yy < mainH - 26, !reservedY.contains(where: { abs($0 - yy) < 13 }) {
                    ctx.draw(Text(Fmt.price(p, decimals: labelDec)).font(.system(size: 9, design: .monospaced)).foregroundColor(.hlMuted),
                             at: CGPoint(x: plotW + 4, y: yy), anchor: .leading)
                }
                p += step
            }
        }

        // Main pane (clipped)
        var main = ctx
        main.clip(to: Path(CGRect(x: 0, y: 0, width: plotW, height: mainH)))

        // Bollinger fill
        for b in layers.bands {
            var path = Path()
            var started = false
            for i in r { if i < b.up.count, let u = b.up[i] { let p = CGPoint(x: x(i), y: y(u)); if started { path.addLine(to: p) } else { path.move(to: p); started = true } } }
            for i in r.reversed() { if i < b.low.count, let l = b.low[i] { path.addLine(to: CGPoint(x: x(i), y: y(l))) } }
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

        // High / low of the visible range.
        if let hl = layers.highLow { drawHighLow(&main, hl, r: r, x: x, y: y, plotW: plotW, mainH: mainH, dec: dec) }

        // Drawings, the ruler and points being placed.
        drawDrawings(&main, axis: &ctx, plotW: plotW, mainH: mainH, dec: dec)

        // Price lines (entry, liquidation, orders, alerts)
        for l in lines where l.price > lo && l.price < hi {
            let yy = y(l.price)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: yy)); path.addLine(to: CGPoint(x: plotW, y: yy))
            main.stroke(path, with: .color(l.color.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            if l.onAxis, yy > 8, yy < mainH - 8 {
                ctx.fill(Path(roundedRect: CGRect(x: plotW + 1, y: yy - 8, width: axisW - 2, height: 16), cornerRadius: 3),
                         with: .color(l.color.opacity(0.9)))
                ctx.draw(Text(Fmt.price(l.price, decimals: dec)).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(.black),
                         at: CGPoint(x: plotW + 4, y: yy), anchor: .leading)
            }
            guard !l.label.isEmpty else { continue }
            // Label on the left, on a pill so it stays readable over the candles (the newest ones are on the right).
            let text = main.resolve(Text(l.label).font(.system(size: 9, weight: .semibold)).foregroundColor(l.color))
            let size = text.measure(in: CGSize(width: plotW, height: 20))
            let pill = CGRect(x: 4, y: yy - size.height / 2 - 2, width: size.width + 8, height: size.height + 4)
            main.fill(Path(roundedRect: pill, cornerRadius: 3), with: .color(Color.hlBg.opacity(0.85)))
            main.stroke(Path(roundedRect: pill, cornerRadius: 3), with: .color(l.color.opacity(0.6)), lineWidth: 0.5)
            main.draw(text, at: CGPoint(x: pill.minX + 4, y: yy), anchor: .leading)
        }

        // Last price tag (also while scrolled back, as TradingView keeps it on the scale)
        if let last = candles.last {
            let yy = y(last.c)
            let color = last.c >= last.o ? Color.hlGreen : Color.hlRed
            if showLastPriceLine {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: yy)); path.addLine(to: CGPoint(x: plotW, y: yy))
                main.stroke(path, with: .color(color.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
            if yy > 0 && yy < mainH {
                ctx.fill(Path(roundedRect: CGRect(x: plotW + 1, y: yy - 8, width: axisW - 2, height: 16), cornerRadius: 3), with: .color(color))
                ctx.draw(Text(Fmt.price(last.c, decimals: dec)).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(.hlOnAccent),
                         at: CGPoint(x: plotW + 4, y: yy), anchor: .leading)
                // Time left until the current candle closes.
                let close = closeTime?(last.t / 1000) ?? last.t / 1000 + intervalSeconds
                let remaining = Int(close - now.timeIntervalSince1970)
                if remaining > 0 && lastVisible {
                    let text = remaining >= 3600 ? Fmt.countdown(remaining) : String(format: "%02d:%02d", remaining / 60, remaining % 60)
                    // Below the price tag, or above it near the bottom edge.
                    let ty = yy + 16 <= mainH - 7 ? yy + 16 : yy - 16
                    // Opaque so nothing on the axis shows through.
                    let box = Path(roundedRect: CGRect(x: plotW + 1, y: ty - 7, width: axisW - 2, height: 14), cornerRadius: 3)
                    ctx.fill(box, with: .color(.hlBg))
                    ctx.fill(box, with: .color(color.opacity(0.3)))
                    ctx.draw(Text(text).font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundColor(.hlInk),
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
            var vctx = ctx
            vctx.clip(to: Path(CGRect(x: 0, y: L0.volTop, width: plotW, height: L0.volH)))
            let maxV = s.map(\.v).max() ?? 1
            for i in r {
                let c = candles[i]
                let h = maxV > 0 ? CGFloat(c.v / maxV) * (L0.volH - 2) : 0
                let rect = CGRect(x: x(i) - cw * 0.35, y: L0.volTop + L0.volH - h, width: max(1, cw * 0.7), height: h)
                vctx.fill(Path(rect), with: .color((c.c >= c.o ? Color.hlGreen : Color.hlRed).opacity(0.3)))
            }
        }

        // Indicator panes
        for (pi, pane) in layers.panes.enumerated() {
            drawPane(&ctx, pane, top: L0.paneTops[pi], height: L0.paneH, plotW: plotW, r: r, x: x)
        }

        // Time axis: labels on round boundaries (hours / days), at least ~70 pt apart, on the candle grid.
        let units: [Double] = [60, 300, 900, 1800, 3600, 7200, 14400, 21600, 43200, 86400, 172800, 604800, 2_592_000]
        let iv = max(intervalSeconds, 1)
        let unit = units.first { $0 >= iv && CGFloat($0 / iv) * spacing >= 70 } ?? max(iv, Double(Int(ceil(70 / spacing))) * iv)
        let barsPerLabel = max(1, Int((unit / iv).rounded()))
        var prevDay: Int?
        let cal = Calendar.current
        for i in r {
            let t = candles[i].t / 1000
            guard Int((t / iv).rounded()) % barsPerLabel == 0 else { continue }
            let xx = x(i)
            guard xx > 12, xx < plotW - 12 else { continue }
            let date = Date(timeIntervalSince1970: t)
            let day = cal.ordinality(of: .day, in: .era, for: date) ?? 0
            let showDay = unit >= 86400 || (prevDay != nil && prevDay != day) || cal.component(.hour, from: date) == 0 && cal.component(.minute, from: date) == 0
            prevDay = day
            let text = showDay ? CandleChart.dayFormatter.string(from: date) : CandleChart.timeFormatter.string(from: date)
            ctx.draw(Text(text).font(.system(size: 9, weight: showDay && unit < 86400 ? .semibold : .regular)).foregroundColor(.hlMuted),
                     at: CGPoint(x: xx, y: size.height - timeH / 2))
        }

        // Crosshair
        if let p = crosshair, p.x < plotW, p.y < size.height - timeH {
            var path = Path()
            path.move(to: CGPoint(x: p.x, y: 0)); path.addLine(to: CGPoint(x: p.x, y: size.height - timeH))
            path.move(to: CGPoint(x: 0, y: p.y)); path.addLine(to: CGPoint(x: plotW, y: p.y))
            ctx.stroke(path, with: .color(Color.hlInk.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            if p.y < mainH {
                let crossPrice = price(atFraction: Double(p.y / mainH))
                ctx.fill(Path(roundedRect: CGRect(x: plotW + 1, y: p.y - 8, width: axisW - 2, height: 16), cornerRadius: 3), with: .color(.hlInk))
                ctx.draw(Text(Fmt.price(crossPrice, decimals: labelDec)).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(.hlBg),
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

    /// Highest high and lowest low among the candles on screen: a short leader from the wick tip and the price
    /// (optionally the distance from the last price in %).
    private func drawHighLow(_ ctx: inout GraphicsContext, _ hl: (color: Color, showPercent: Bool), r: Range<Int>,
                             x: (Int) -> CGFloat, y: (Double) -> CGFloat, plotW: CGFloat, mainH: CGFloat, dec: Int) {
        var hi: Int?, lo: Int?
        for i in r where x(i) >= 0 && x(i) <= plotW {
            if hi == nil || candles[i].h > candles[hi!].h { hi = i }
            if lo == nil || candles[i].l < candles[lo!].l { lo = i }
        }
        guard let hi, let lo else { return }
        let last = candles.last?.c ?? 0
        for (i, isHigh) in [(hi, true), (lo, false)] {
            let price = isHigh ? candles[i].h : candles[i].l
            let px = x(i), py = y(price)
            var text = "\(isHigh ? "H" : "L") \(Fmt.price(price, decimals: dec))"
            if hl.showPercent, last > 0 { text += "  \(Fmt.pct(price / last - 1, 2))" }
            let resolved = ctx.resolve(Text(text).font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundColor(hl.color))
            let size = resolved.measure(in: CGSize(width: 300, height: 20))
            // Leader to the right of the candle, or to the left near the right edge.
            let toRight = px + 16 + size.width < plotW
            let lx = toRight ? px + 14 : px - 14
            let ly = isHigh ? max(size.height / 2 + 1, py - 6) : min(mainH - size.height / 2 - 1, py + 6)
            var lead = Path()
            lead.move(to: CGPoint(x: px, y: py)); lead.addLine(to: CGPoint(x: lx, y: ly))
            ctx.stroke(lead, with: .color(hl.color.opacity(0.8)), lineWidth: 1)
            ctx.fill(Path(ellipseIn: CGRect(x: px - 2, y: py - 2, width: 4, height: 4)), with: .color(hl.color))
            ctx.draw(resolved, at: CGPoint(x: toRight ? lx + 2 : lx - 2, y: ly), anchor: toRight ? .leading : .trailing)
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
        ctx.stroke(sep, with: .color(Color.hlInk.opacity(0.12)), lineWidth: 1)

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
            pctx.stroke(path, with: .color(Color.hlInk.opacity(0.18)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            ctx.draw(Text(Fmt.input(lv, 2)).font(.system(size: 8, design: .monospaced)).foregroundColor(.hlMuted),
                     at: CGPoint(x: plotW + 4, y: y(lv)), anchor: .leading)
        }

        if let h = pane.histogram {
            let cw = spacing
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
        guard let p = crosshair, !candles.isEmpty else { return nil }
        let plotW = size.width - axisW
        let lastIdx = candles.count - 1
        let idx = lastIdx - Int(((plotW - p.x) / spacing - rightOffset - 0.5).rounded())
        guard candles.indices.contains(idx) else { return nil }
        let c = candles[idx]
        let d = decimals ?? Fmt.autoDecimals(c.c)
        let ch = c.o > 0 ? c.c / c.o - 1 : 0
        return "\(Fmt.dateTime(Date(timeIntervalSince1970: c.t / 1000)))  O \(Fmt.price(c.o, decimals: d)) H \(Fmt.price(c.h, decimals: d)) L \(Fmt.price(c.l, decimals: d)) C \(Fmt.price(c.c, decimals: d)) \(Fmt.pct(ch))  V \(Fmt.compact(c.v))"
    }
}

struct ChartTouchHandlers {
    /// Start location and the first few points of movement; false lets the swipe go to the page.
    var panShouldBegin: (CGPoint, CGPoint) -> Bool
    /// Start location and translation.
    var panChanged: (CGPoint, CGSize) -> Void
    /// Horizontal release velocity, points per second.
    var panEnded: (CGFloat) -> Void
    /// Anchor x (where the fingers started) and the scale since the pinch began.
    var pinchChanged: (CGFloat, CGFloat) -> Void
    var pinchEnded: () -> Void
    /// Crosshair position after a long press; nil when released.
    var crosshair: (CGPoint?) -> Void
    /// Single tap (places or selects drawings); waits for a possible double tap.
    var tap: (CGPoint) -> Void = { _ in }
    var doubleTap: (CGPoint) -> Void
}

/// Transparent UIKit view carrying the chart's gestures (pan, pinch, long-press crosshair, double tap).
/// Plain UIKit inside the page's scroll view: the pan declines vertical swipes and the page scrolls instead.
struct ChartTouchSurface: UIViewRepresentable {
    var handlers: ChartTouchHandlers

    func makeUIView(context: Context) -> ChartTouchView {
        let v = ChartTouchView()
        v.handlers = handlers
        return v
    }

    func updateUIView(_ v: ChartTouchView, context: Context) {
        v.handlers = handlers
    }
}

final class ChartTouchView: UIView, UIGestureRecognizerDelegate {
    var handlers: ChartTouchHandlers?
    private let pan = ChartPanRecognizer()
    private let pinch = UIPinchGestureRecognizer()
    private let press = UILongPressGestureRecognizer()
    private let tap2 = UITapGestureRecognizer()
    private let tap1 = UITapGestureRecognizer()
    private var pinchAnchorX: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        pan.maximumNumberOfTouches = 1
        pan.decide = { [weak self] start, delta in self?.handlers?.panShouldBegin(start, delta) ?? true }
        pan.addTarget(self, action: #selector(onPan(_:)))
        pinch.addTarget(self, action: #selector(onPinch(_:)))
        press.minimumPressDuration = 0.25
        press.addTarget(self, action: #selector(onPress(_:)))
        tap2.numberOfTapsRequired = 2
        tap2.addTarget(self, action: #selector(onTap2(_:)))
        tap1.addTarget(self, action: #selector(onTap1(_:)))
        tap1.require(toFail: tap2)
        for g in [pan, pinch, press, tap2, tap1] as [UIGestureRecognizer] {
            g.delegate = self
            addGestureRecognizer(g)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func onPan(_ g: ChartPanRecognizer) {
        let t = g.translation(in: self)
        switch g.state {
        case .began, .changed: handlers?.panChanged(g.localStart, CGSize(width: t.x, height: t.y))
        case .ended: handlers?.panEnded(g.velocity(in: self).x)
        case .cancelled, .failed: handlers?.panEnded(0)
        default: break
        }
    }

    @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            pinchAnchorX = g.location(in: self).x
            handlers?.pinchChanged(pinchAnchorX, g.scale)
        case .changed: handlers?.pinchChanged(pinchAnchorX, g.scale)
        case .ended, .cancelled, .failed: handlers?.pinchEnded()
        default: break
        }
    }

    @objc private func onPress(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began, .changed: handlers?.crosshair(g.location(in: self))
        case .ended, .cancelled, .failed: handlers?.crosshair(nil)
        default: break
        }
    }

    @objc private func onTap1(_ g: UITapGestureRecognizer) {
        if g.state == .ended { handlers?.tap(g.location(in: self)) }
    }

    @objc private func onTap2(_ g: UITapGestureRecognizer) {
        if g.state == .ended { handlers?.doubleTap(g.location(in: self)) }
    }

    /// The chart's own gestures work together; never alongside the page's scrolling.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        other.view === self
    }

    /// The page's scroll waits until the chart pan has declined (a vertical swipe), so it never grabs a
    /// sideways drag or a drag with auto-scale off.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        g === pan && other.view is UIScrollView && other is UIPanGestureRecognizer
    }
}

/// Pan that looks at the first few points of movement and fails itself when the owner declines, so the
/// page's scroll view gets the swipe.
final class ChartPanRecognizer: UIPanGestureRecognizer {
    var decide: (CGPoint, CGPoint) -> Bool = { _, _ in true }
    /// Touch-down point in the view's coordinates.
    private(set) var localStart: CGPoint = .zero
    private var touchStart: CGPoint?
    private var decided = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if touchStart == nil, let p = touches.first?.location(in: view) {
            touchStart = p
            localStart = p
        }
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if !decided, state == .possible, let s = touchStart, let p = touches.first?.location(in: view) {
            let d = CGPoint(x: p.x - s.x, y: p.y - s.y)
            if hypot(d.x, d.y) >= 4 {
                decided = true
                if !decide(localStart, d) {
                    state = .failed
                    return
                }
            }
        }
        super.touchesMoved(touches, with: event)
    }

    override func reset() {
        super.reset()
        touchStart = nil
        decided = false
    }
}

// MARK: - Drawings

extension CandleChart {
    private var ivMs: Double { max(intervalSeconds, 1) * 1000 }

    /// Fractional candle index under an x coordinate (inverse of x(i)).
    fileprivate func fracIndex(atX x: CGFloat) -> Double {
        Double(CGFloat(candles.count - 1) + rightOffset + 0.5 - (cache.plotW - x) / spacing)
    }

    fileprivate func xOf(index fi: Double) -> CGFloat {
        cache.plotW - (CGFloat(Double(candles.count - 1) - fi) + rightOffset + 0.5) * spacing
    }

    /// Time (ms) at a fractional index; extrapolated with the interval beyond the loaded candles.
    fileprivate func time(atIndex fi: Double) -> Double {
        guard let first = candles.first, let last = candles.last else { return 0 }
        let n = candles.count
        if fi <= 0 { return first.t + fi * ivMs }
        if fi >= Double(n - 1) { return last.t + (fi - Double(n - 1)) * ivMs }
        let i = Int(floor(fi)), f = fi - Double(i)
        return candles[i].t + (candles[i + 1].t - candles[i].t) * f
    }

    fileprivate func index(ofTime t: Double) -> Double {
        guard let first = candles.first, let last = candles.last else { return 0 }
        let n = candles.count
        if t <= first.t { return (t - first.t) / ivMs }
        if t >= last.t { return Double(n - 1) + (t - last.t) / ivMs }
        var lo = 0, hi = n - 1
        while lo < hi {
            let m = (lo + hi + 1) / 2
            if candles[m].t <= t { lo = m } else { hi = m - 1 }
        }
        let span = candles[lo + 1].t - candles[lo].t
        return Double(lo) + (span > 0 ? (t - candles[lo].t) / span : 0)
    }

    fileprivate func yOf(price p: Double) -> CGFloat {
        let v = cache.log ? Foundation.log(max(p, 1e-12)) : p
        return CGFloat((cache.hi - v) / max(cache.hi - cache.lo, 1e-12)) * cache.mainH
    }

    fileprivate func price(atY y: CGFloat) -> Double {
        let v = cache.hi - Double(y / max(cache.mainH, 1)) * (cache.hi - cache.lo)
        return cache.log ? Foundation.exp(v) : v
    }

    fileprivate func screen(_ p: ChartPoint) -> CGPoint {
        CGPoint(x: xOf(index: index(ofTime: p.t)), y: yOf(price: p.p))
    }

    /// Chart point under a location: time snaps to the candle; with the magnet, the price snaps to the
    /// candle's open / high / low / close (weak: only when within 24 pt).
    fileprivate func chartPoint(at loc: CGPoint, magnet: MagnetMode) -> ChartPoint {
        let fi = fracIndex(atX: loc.x)
        let ri = Int(fi.rounded())
        var p = price(atY: loc.y)
        guard ri >= 0, ri < candles.count else { return ChartPoint(t: time(atIndex: fi.rounded()), p: p) }
        let c = candles[ri]
        if magnet != .off,
           let best = [c.o, c.h, c.l, c.c].min(by: { abs(yOf(price: $0) - loc.y) < abs(yOf(price: $1) - loc.y) }),
           magnet == .strong || abs(yOf(price: best) - loc.y) < 24 {
            p = best
        }
        return ChartPoint(t: c.t, p: p)
    }

    fileprivate func defaultColor(_ kind: DrawKind) -> Int {
        switch kind {
        case .hline, .hray, .rect: return 1
        case .trend: return 0
        case .fib: return 5
        }
    }

    // MARK: Hit testing

    /// Drawing under a point: `handle` 0 / 1 for the end points of the selected drawing, −1 for its body.
    fileprivate func hitTest(_ loc: CGPoint) -> (id: UUID, handle: Int)? {
        guard let dc = drawing, !dc.hidden else { return nil }
        let tol: CGFloat = 12
        for d in dc.drawings.reversed() {
            let A = screen(d.a), B = screen(d.b)
            if d.id == dc.selected {
                let handles = d.kind == .hline || d.kind == .hray ? [A] : [A, B]
                for (i, h) in handles.enumerated() where hypot(h.x - loc.x, h.y - loc.y) < 18 { return (d.id, i) }
            }
            var hit = false
            switch d.kind {
            case .hline:
                hit = abs(loc.y - A.y) < tol
            case .hray:
                hit = abs(loc.y - A.y) < tol && loc.x >= A.x - tol
            case .trend:
                hit = distance(loc, A, B, left: d.extendLeft, right: d.extendRight) < tol
            case .rect:
                hit = CGRect(x: min(A.x, B.x), y: min(A.y, B.y), width: abs(B.x - A.x), height: abs(B.y - A.y))
                    .insetBy(dx: -tol, dy: -tol).contains(loc)
            case .fib:
                let x1 = d.extendRight ? cache.plotW : max(A.x, B.x)
                hit = loc.x >= min(A.x, B.x) - tol && loc.x <= x1 + tol
                    && loc.y >= min(A.y, B.y) - tol && loc.y <= max(A.y, B.y) + tol
            }
            if hit { return (d.id, -1) }
        }
        return nil
    }

    private func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint, left: Bool, right: Bool) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2
        if !left { t = max(0, t) }
        if !right { t = min(1, t) }
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    // MARK: Gestures

    fileprivate func handleTap(_ loc: CGPoint, size: CGSize) {
        guard let dc = drawing else { return }
        let plotW = size.width - axisW, mainH = layout(size).mainH
        guard loc.x <= plotW, loc.y <= mainH, !candles.isEmpty else { return }
        let pt = chartPoint(at: loc, magnet: dc.magnet)
        if let pick = dc.pickTime { pick(pt.t); return }
        switch dc.tool {
        case .cursor:
            ruler = nil
            dc.select(hitTest(loc)?.id)
        case .ruler:
            // Tap, tap: measure between two points; a further tap clears the measurement.
            if ruler != nil {
                if rulerHandleHit(loc) == nil { ruler = nil; pendingA = nil }
            }
            else if let a = pendingA { ruler = (a, pt); pendingA = nil }
            else { pendingA = pt }
        case .hline, .hray:
            guard let kind = dc.tool.kind else { return }
            let d = ChartDrawing(kind: kind, a: pt, b: pt, color: defaultColor(kind))
            dc.commit(d); dc.select(d.id); dc.toolDone()
        case .trend, .rect, .fib:
            guard let kind = dc.tool.kind else { return }
            if let a = pendingA {
                let d = ChartDrawing(kind: kind, a: a, b: pt, color: defaultColor(kind))
                pendingA = nil
                dc.commit(d); dc.select(d.id); dc.toolDone()
            } else {
                pendingA = pt
            }
        }
    }

    /// Starts creating (a tool is active) or moving the selected drawing; false = an ordinary chart drag.
    fileprivate func beginDrawingDrag(_ dc: ChartDrawingContext, start: CGPoint) -> Bool {
        // A ruler end point under the finger: adjust it instead of measuring again.
        if let h = rulerHandleHit(start), let r = ruler {
            dragKind = .rulerEdit
            rulerHandle = h
            rulerHandleStart = screen(h == 0 ? r.a : r.b)
            return true
        }
        if dc.tool != .cursor {
            dragKind = .create
            pendingA = nil
            createStart = chartPoint(at: start, magnet: dc.magnet)
            if dc.tool == .ruler { ruler = nil }
            return true
        }
        if let h = hitTest(start), h.id == dc.selected,
           let d = dc.drawings.first(where: { $0.id == h.id }), !d.locked {
            dragKind = .edit
            editStart = d
            editHandle = h.handle
            draft = d
            return true
        }
        return false
    }

    fileprivate func drawingDragChanged(start: CGPoint, translation: CGSize) {
        guard let dc = drawing else { return }
        let cur = CGPoint(x: start.x + translation.width, y: start.y + translation.height)
        switch dragKind {
        case .create:
            guard let a = createStart else { return }
            let b = chartPoint(at: cur, magnet: dc.magnet)
            if dc.tool == .ruler {
                ruler = (a, b)
            } else if let kind = dc.tool.kind {
                // One-point tools follow the finger; two-point tools stretch from the start point.
                let id = draft?.id ?? UUID()
                var d = ChartDrawing(kind: kind, a: kind.twoPoint ? a : b, b: b, color: defaultColor(kind))
                d.id = id
                draft = d
            }
        case .rulerEdit:
            guard let r = ruler else { return }
            // Moves from where the handle was (not from the finger), so the point does not jump.
            let p = chartPoint(at: CGPoint(x: rulerHandleStart.x + translation.width, y: rulerHandleStart.y + translation.height),
                               magnet: dc.magnet)
            ruler = rulerHandle == 0 ? (p, r.b) : (r.a, p)
        case .edit:
            guard var d = editStart else { return }
            if editHandle >= 0 {
                let p = chartPoint(at: cur, magnet: dc.magnet)
                if d.kind == .hline || d.kind == .hray { d.a = p; d.b = p }
                else if editHandle == 0 { d.a = p } else { d.b = p }
            } else {
                // Whole drawing: both points move with the finger (no magnet).
                let A = screen(d.a), B = screen(d.b)
                d.a = chartPoint(at: CGPoint(x: A.x + translation.width, y: A.y + translation.height), magnet: .off)
                d.b = chartPoint(at: CGPoint(x: B.x + translation.width, y: B.y + translation.height), magnet: .off)
                if d.kind == .hline || d.kind == .hray { d.b = d.a }
            }
            draft = d
        default:
            break
        }
    }

    fileprivate func drawingDragEnded() {
        guard let dc = drawing else { return }
        if dragKind == .create, let d = draft {
            let A = screen(d.a), B = screen(d.b)
            if !d.kind.twoPoint || hypot(B.x - A.x, B.y - A.y) > 6 {
                dc.commit(d); dc.select(d.id); dc.toolDone()
            }
        } else if dragKind == .edit, let d = draft {
            dc.commit(d)
        }
        draft = nil
        editStart = nil
        createStart = nil
    }

    // MARK: Rendering

    fileprivate func drawDrawings(_ main: inout GraphicsContext, axis: inout GraphicsContext,
                                  plotW: CGFloat, mainH: CGFloat, dec: Int) {
        guard let dc = drawing else { return }
        var list = dc.hidden ? [] : dc.drawings.filter { $0.id != draft?.id }
        if let d = draft { list.append(d) }
        for d in list {
            render(d, selected: d.id == dc.selected || d.id == draft?.id, &main, axis: &axis, plotW: plotW, mainH: mainH, dec: dec)
        }
        if let a = pendingA {
            let p = screen(a)
            main.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)), with: .color(Color.hlAccent))
        }
        if let r = ruler { renderRuler(r.a, r.b, &main, dec: dec) }
    }

    private func render(_ d: ChartDrawing, selected: Bool, _ main: inout GraphicsContext, axis: inout GraphicsContext,
                        plotW: CGFloat, mainH: CGFloat, dec: Int) {
        let color = d.swiftColor
        let w = CGFloat(d.width)
        let style = StrokeStyle(lineWidth: w, lineCap: .round, dash: d.style.dash(w))
        let A = screen(d.a), B = screen(d.b)
        func label(_ text: String, at p: CGPoint, anchor: UnitPoint, size: CGFloat = 10) {
            guard !text.isEmpty else { return }
            main.draw(Text(text).font(.system(size: size, weight: .semibold)).foregroundColor(color), at: p, anchor: anchor)
        }
        /// Text placed along [x0, x1] by the drawing's label setting, just above y.
        func alignedLabel(_ text: String, x0: CGFloat, x1: CGFloat, y: CGFloat, size: CGFloat = 10) {
            let lo = max(4, min(x0, x1)), hi = min(plotW - 4, max(x0, x1))
            switch d.labelAlign {
            case .left: label(text, at: CGPoint(x: lo + 2, y: y), anchor: .bottomLeading, size: size)
            case .center: label(text, at: CGPoint(x: (lo + hi) / 2, y: y), anchor: .bottom, size: size)
            case .right: label(text, at: CGPoint(x: hi - 2, y: y), anchor: .bottomTrailing, size: size)
            }
        }
        func axisTag(_ price: Double) {
            let yy = yOf(price: price)
            guard yy > 0, yy < mainH else { return }
            axis.fill(Path(roundedRect: CGRect(x: plotW + 1, y: yy - 8, width: axisW - 2, height: 16), cornerRadius: 3), with: .color(color))
            axis.draw(Text(Fmt.price(price, decimals: dec)).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(.black),
                      at: CGPoint(x: plotW + 4, y: yy), anchor: .leading)
        }
        switch d.kind {
        case .hline, .hray:
            var path = Path()
            path.move(to: CGPoint(x: d.kind == .hline ? 0 : A.x, y: A.y)); path.addLine(to: CGPoint(x: plotW, y: A.y))
            main.stroke(path, with: .color(color), style: style)
            alignedLabel(d.text, x0: d.kind == .hline ? 0 : A.x + 4, x1: plotW, y: A.y - 3)
            if d.showPrice { axisTag(d.a.p) }
        case .trend:
            var p1 = A, p2 = B
            let dx = B.x - A.x, dy = B.y - A.y
            let len = max(hypot(dx, dy), 1)
            let far = 5000 / len
            if d.extendLeft { p1 = CGPoint(x: A.x - dx * far, y: A.y - dy * far) }
            if d.extendRight { p2 = CGPoint(x: B.x + dx * far, y: B.y + dy * far) }
            var path = Path()
            path.move(to: p1); path.addLine(to: p2)
            main.stroke(path, with: .color(color), style: style)
            // Along the segment: at its left end, middle or right end.
            let left = A.x <= B.x ? A : B, right = A.x <= B.x ? B : A
            switch d.labelAlign {
            case .left: label(d.text, at: CGPoint(x: left.x + 4, y: left.y - 4), anchor: .bottomLeading)
            case .center: label(d.text, at: CGPoint(x: (A.x + B.x) / 2, y: (A.y + B.y) / 2 - 4), anchor: .bottom)
            case .right: label(d.text, at: CGPoint(x: right.x - 4, y: right.y - 4), anchor: .bottomTrailing)
            }
            if d.showPrice && selected { axisTag(d.a.p); axisTag(d.b.p) }
        case .rect:
            let r = CGRect(x: min(A.x, B.x), y: min(A.y, B.y), width: abs(B.x - A.x), height: abs(B.y - A.y))
            main.fill(Path(r), with: .color(color.opacity(0.12)))
            main.stroke(Path(r), with: .color(color), style: style)
            alignedLabel(d.text, x0: r.minX, x1: r.maxX, y: r.minY - 3)
            if d.showPrice && selected { axisTag(d.a.p); axisTag(d.b.p) }
        case .fib:
            let x0 = min(A.x, B.x), x1 = d.extendRight ? plotW : max(A.x, B.x)
            let y382 = yOf(price: d.fibPrice(0.382)), y618 = yOf(price: d.fibPrice(0.618))
            main.fill(Path(CGRect(x: x0, y: min(y382, y618), width: max(1, x1 - x0), height: abs(y618 - y382))),
                      with: .color(color.opacity(0.08)))
            for lv in ChartDrawing.fibLevels {
                let p = d.fibPrice(lv)
                let yy = yOf(price: p)
                var path = Path()
                path.move(to: CGPoint(x: x0, y: yy)); path.addLine(to: CGPoint(x: x1, y: yy))
                let major = lv == 0 || lv == 1 || lv == 0.5 || lv == 0.618
                main.stroke(path, with: .color(color.opacity(major ? 1 : 0.6)), style: StrokeStyle(lineWidth: w, dash: d.style.dash(w)))
                alignedLabel("\(Fmt.num(lv, 3))  \(Fmt.price(p, decimals: dec))", x0: x0, x1: x1, y: yy - 2, size: 9)
            }
            var diag = Path()
            diag.move(to: A); diag.addLine(to: B)
            main.stroke(diag, with: .color(color.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            alignedLabel(d.text, x0: x0, x1: x1, y: min(A.y, B.y) - 14)
        }
        if selected {
            let handles = d.kind == .hline || d.kind == .hray ? [A] : [A, B]
            for h in handles {
                let r = CGRect(x: h.x - 5, y: h.y - 5, width: 10, height: 10)
                main.fill(Path(ellipseIn: r), with: .color(Color.hlBg))
                main.stroke(Path(ellipseIn: r), with: .color(color), lineWidth: 2)
            }
        }
    }

    /// TradingView-like measurement: shaded box, price change (absolute and %), bars and time span.
    private func renderRuler(_ a: ChartPoint, _ b: ChartPoint, _ main: inout GraphicsContext, dec: Int) {
        let A = screen(a), B = screen(b)
        let up = b.p >= a.p
        let color = up ? Color(red: 0.25, green: 0.55, blue: 1.0) : Color.hlRed
        let r = CGRect(x: min(A.x, B.x), y: min(A.y, B.y), width: abs(B.x - A.x), height: abs(B.y - A.y))
        main.fill(Path(r), with: .color(color.opacity(0.16)))
        var v = Path()
        v.move(to: CGPoint(x: r.midX, y: A.y)); v.addLine(to: CGPoint(x: r.midX, y: B.y))
        var h = Path()
        h.move(to: CGPoint(x: A.x, y: r.midY)); h.addLine(to: CGPoint(x: B.x, y: r.midY))
        main.stroke(v, with: .color(color), lineWidth: 1.2)
        main.stroke(h, with: .color(color), lineWidth: 1.2)
        // Arrow heads at the second point's side.
        var ah = Path()
        let dirY: CGFloat = B.y < A.y ? -1 : 1
        ah.move(to: CGPoint(x: r.midX - 4, y: B.y - dirY * 6)); ah.addLine(to: CGPoint(x: r.midX, y: B.y)); ah.addLine(to: CGPoint(x: r.midX + 4, y: B.y - dirY * 6))
        let dirX: CGFloat = B.x < A.x ? -1 : 1
        ah.move(to: CGPoint(x: B.x - dirX * 6, y: r.midY - 4)); ah.addLine(to: CGPoint(x: B.x, y: r.midY)); ah.addLine(to: CGPoint(x: B.x - dirX * 6, y: r.midY + 4))
        main.stroke(ah, with: .color(color), lineWidth: 1.2)

        let dp = b.p - a.p
        let pct = a.p != 0 ? dp / a.p : 0
        let bars = Int((index(ofTime: b.t) - index(ofTime: a.t)).rounded())
        let secs = Int(abs(b.t - a.t) / 1000)
        let line1 = "\(dp >= 0 ? "+" : "−")\(Fmt.price(abs(dp), decimals: dec)) (\(Fmt.pct(pct, 2)))"
        let line2 = L("{0} bars, {1}", bars, Self.span(secs))
        let text = main.resolve(Text(line1 + "\n" + line2).font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(.white))
        let sz = text.measure(in: CGSize(width: 300, height: 60))
        var box = CGRect(x: r.midX - sz.width / 2 - 6, y: (up ? r.minY - sz.height - 14 : r.maxY + 6), width: sz.width + 12, height: sz.height + 8)
        box.origin.x = min(max(2, box.origin.x), cache.plotW - box.width - 2)
        box.origin.y = min(max(2, box.origin.y), cache.mainH - box.height - 2)
        main.fill(Path(roundedRect: box, cornerRadius: 5), with: .color(color.opacity(0.92)))
        main.draw(text, at: CGPoint(x: box.midX, y: box.midY), anchor: .center)
        // Draggable end points (adjust the measurement precisely).
        for h in [A, B] {
            let r = CGRect(x: h.x - 7, y: h.y - 7, width: 14, height: 14)
            main.fill(Path(ellipseIn: r), with: .color(Color.hlBg))
            main.stroke(Path(ellipseIn: r), with: .color(color), lineWidth: 2.5)
            main.fill(Path(ellipseIn: r.insetBy(dx: 4.5, dy: 4.5)), with: .color(color))
        }
    }

    /// Ruler end point (0 / 1) within reach of a touch.
    fileprivate func rulerHandleHit(_ loc: CGPoint) -> Int? {
        guard let r = ruler else { return nil }
        let a = screen(r.a), b = screen(r.b)
        let da = hypot(a.x - loc.x, a.y - loc.y), db = hypot(b.x - loc.x, b.y - loc.y)
        guard min(da, db) < 26 else { return nil }
        return da <= db ? 0 : 1
    }

    private static func span(_ s: Int) -> String {
        let d = s / 86400, h = s % 86400 / 3600, m = s % 3600 / 60
        if d > 0 { return h > 0 ? "\(d)d \(h)h" : "\(d)d" }
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        return "\(m)m"
    }
}
