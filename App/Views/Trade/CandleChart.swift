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
    var decimals: Int? = nil

    @State private var visible = 70
    @State private var offset = 0          // candles hidden on the right
    @State private var dragStartOffset: Int?
    @State private var zoomStart: Int?
    @State private var crosshair: CGPoint?

    private let axisW: CGFloat = 58
    private let timeH: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                Canvas { ctx, sz in draw(ctx: &ctx, size: sz) }
                if let info = crosshairInfo(size: size) {
                    Text(info)
                        .font(.system(size: 10, design: .monospaced))
                        .padding(4)
                        .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                        .padding(4)
                }
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

    private func clampOffset(_ o: Int) -> Int { max(0, min(o, max(0, candles.count - 10))) }

    private var slice: ArraySlice<Candle> {
        let end = max(0, candles.count - offset)
        let start = max(0, end - visible)
        return candles[start..<end]
    }

    private func range(_ s: ArraySlice<Candle>) -> (Double, Double) {
        var lo = s.map(\.l).min() ?? 0, hi = s.map(\.h).max() ?? 1
        if hi <= lo { hi = lo * 1.01 + 1e-9; lo = lo * 0.99 }
        let pad = (hi - lo) * 0.06
        return (lo - pad, hi + pad)
    }

    private func draw(ctx: inout GraphicsContext, size: CGSize) {
        let s = slice
        guard !s.isEmpty else { return }
        let plotW = size.width - axisW
        let volH = (size.height - timeH) * 0.16
        let plotH = size.height - timeH - volH
        let (lo, hi) = range(s)
        let cw = plotW / CGFloat(visible)
        let leftPad = CGFloat(visible - s.count) * cw
        let dec = decimals ?? Fmt.autoDecimals(s.last?.c ?? 1)
        func y(_ p: Double) -> CGFloat { CGFloat((hi - p) / (hi - lo)) * plotH }
        func x(_ i: Int) -> CGFloat { leftPad + CGFloat(i) * cw + cw / 2 }

        // Grid + price axis
        let gridColor = Color.white.opacity(0.06)
        for k in 0...4 {
            let p = lo + (hi - lo) * Double(k) / 4
            let yy = y(p)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: yy)); path.addLine(to: CGPoint(x: plotW, y: yy))
            ctx.stroke(path, with: .color(gridColor), lineWidth: 1)
            ctx.draw(Text(Fmt.price(p, decimals: dec)).font(.system(size: 9, design: .monospaced)).foregroundColor(.hlMuted),
                     at: CGPoint(x: plotW + 4, y: min(max(yy, 6), plotH - 6)), anchor: .leading)
        }

        // Volume
        let maxV = s.map(\.v).max() ?? 1
        for (i, c) in s.enumerated() {
            let h = maxV > 0 ? CGFloat(c.v / maxV) * volH : 0
            let rect = CGRect(x: x(i) - cw * 0.35, y: plotH + volH - h, width: max(1, cw * 0.7), height: h)
            ctx.fill(Path(rect), with: .color((c.c >= c.o ? Color.hlGreen : Color.hlRed).opacity(0.3)))
        }

        // Candles
        for (i, c) in s.enumerated() {
            let up = c.c >= c.o
            let color = up ? Color.hlGreen : Color.hlRed
            var wick = Path()
            wick.move(to: CGPoint(x: x(i), y: y(c.h)))
            wick.addLine(to: CGPoint(x: x(i), y: y(c.l)))
            ctx.stroke(wick, with: .color(color), lineWidth: 1)
            let top = y(max(c.o, c.c)), bot = y(min(c.o, c.c))
            let rect = CGRect(x: x(i) - cw * 0.35, y: top, width: max(1, cw * 0.7), height: max(1, bot - top))
            ctx.fill(Path(rect), with: .color(color))
        }

        // Overlay lines (entry, liquidation, orders)
        for l in lines where l.price > lo && l.price < hi {
            let yy = y(l.price)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: yy)); path.addLine(to: CGPoint(x: plotW, y: yy))
            ctx.stroke(path, with: .color(l.color.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            ctx.draw(Text(l.label).font(.system(size: 9, weight: .semibold)).foregroundColor(l.color),
                     at: CGPoint(x: 4, y: yy - 7), anchor: .leading)
        }

        // Last price
        if let last = s.last, offset == 0 {
            let yy = y(last.c)
            let color = last.c >= last.o ? Color.hlGreen : Color.hlRed
            var path = Path()
            path.move(to: CGPoint(x: 0, y: yy)); path.addLine(to: CGPoint(x: plotW, y: yy))
            ctx.stroke(path, with: .color(color.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            let rect = CGRect(x: plotW + 1, y: yy - 8, width: axisW - 2, height: 16)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(color))
            ctx.draw(Text(Fmt.price(last.c, decimals: dec)).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(.black),
                     at: CGPoint(x: plotW + 4, y: yy), anchor: .leading)
        }

        // Time axis
        let fmt = DateFormatter()
        let span = (s.last?.t ?? 0) - (s.first?.t ?? 0)
        fmt.dateFormat = span > 3 * 86_400_000 ? "dd.MM" : "HH:mm"
        let step = max(1, s.count / 4)
        for (i, c) in s.enumerated() where i % step == step / 2 {
            ctx.draw(Text(fmt.string(from: Date(timeIntervalSince1970: c.t / 1000))).font(.system(size: 9)).foregroundColor(.hlMuted),
                     at: CGPoint(x: x(i), y: size.height - timeH / 2))
        }

        // Crosshair
        if let p = crosshair, p.x < plotW, p.y < plotH {
            var path = Path()
            path.move(to: CGPoint(x: p.x, y: 0)); path.addLine(to: CGPoint(x: p.x, y: plotH + volH))
            path.move(to: CGPoint(x: 0, y: p.y)); path.addLine(to: CGPoint(x: plotW, y: p.y))
            ctx.stroke(path, with: .color(.white.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            let price = hi - Double(p.y / plotH) * (hi - lo)
            let rect = CGRect(x: plotW + 1, y: p.y - 8, width: axisW - 2, height: 16)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(.white))
            ctx.draw(Text(Fmt.price(price, decimals: dec)).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(.black),
                     at: CGPoint(x: plotW + 4, y: p.y), anchor: .leading)
        }
    }

    private func crosshairInfo(size: CGSize) -> String? {
        guard let p = crosshair else { return nil }
        let s = slice
        guard !s.isEmpty else { return nil }
        let plotW = size.width - axisW
        let cw = plotW / CGFloat(visible)
        let leftPad = CGFloat(visible - s.count) * cw
        let idx = Int((p.x - leftPad) / cw)
        guard idx >= 0, idx < s.count else { return nil }
        let c = s[s.startIndex + idx]
        let d = decimals ?? Fmt.autoDecimals(c.c)
        let ch = c.o > 0 ? c.c / c.o - 1 : 0
        return "\(Fmt.dateTime(Date(timeIntervalSince1970: c.t / 1000)))  O \(Fmt.price(c.o, decimals: d)) H \(Fmt.price(c.h, decimals: d)) L \(Fmt.price(c.l, decimals: d)) C \(Fmt.price(c.c, decimals: d)) \(Fmt.pct(ch))"
    }
}
