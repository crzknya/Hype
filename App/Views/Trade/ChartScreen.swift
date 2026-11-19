import SwiftUI

/// Candle chart bound to the app model (selected market, interval, indicators).
struct PriceChartView: View {
    @Environment(AppModel.self) private var model
    let market: Market

    var body: some View {
        ZStack {
            CandleChart(candles: model.candles, lines: model.chartLines(market),
                        layers: ChartLayers.build(model.candles, configs: model.indicators, interval: model.interval),
                        decimals: nil, showVolume: model.showVolume)
                .id("\(market.id)-\(model.interval.rawValue)")
            if model.candlesLoading && model.candles.isEmpty { ProgressView() }
        }
    }
}

/// Interval picker with indicator and full-screen buttons.
struct ChartToolbar: View {
    @Environment(AppModel.self) private var model
    var onFullScreen: (() -> Void)? = nil
    var onIndicators: () -> Void

    /// User-chosen intervals plus the active one (if it is hidden).
    private var shownIntervals: [CandleInterval] {
        var list = model.visibleIntervals
        if !list.contains(model.interval) {
            list.append(model.interval)
            list.sort { $0.seconds < $1.seconds }
        }
        return list
    }

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 2) {
                ForEach(shownIntervals) { iv in
                    Button { model.interval = iv } label: {
                        Text(iv.rawValue)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(model.interval == iv ? Color.hlAccent.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(model.interval == iv ? Color.hlAccent : Color.hlMuted)
                    }
                    .buttonStyle(.plain)
                }
                Menu {
                    Section(L("Timeframe")) {
                        ForEach(CandleInterval.allCases) { iv in
                            Button {
                                model.interval = iv
                            } label: {
                                if model.interval == iv { Label(iv.rawValue, systemImage: "checkmark") } else { Text(iv.rawValue) }
                            }
                        }
                    }
                    Menu(L("Show in toolbar")) {
                        ForEach(CandleInterval.allCases) { iv in
                            Button {
                                model.toggleIntervalVisibility(iv)
                            } label: {
                                if model.visibleIntervals.contains(iv) { Label(iv.rawValue, systemImage: "checkmark") } else { Text(iv.rawValue) }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 26)
                        .foregroundStyle(Color.hlMuted)
                }
            }
            .padding(.leading, 10)
            Button(action: onIndicators) {
                Image(systemName: "function").font(.system(size: 14, weight: .semibold))
                    .frame(width: 32, height: 28)
                    .background(Color.hlCard2, in: RoundedRectangle(cornerRadius: 6))
            }
            if let onFullScreen {
                Button(action: onFullScreen) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 13, weight: .semibold))
                        .frame(width: 32, height: 28)
                        .background(Color.hlCard2, in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(.trailing, 10)
        .foregroundStyle(Color.hlAccent)
    }
}

struct ChartScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let market: Market
    @State private var showIndicators = false

    var body: some View {
        let px = model.mid(market.id)
        let change = market.prevDayPx > 0 && px > 0 ? px / market.prevDayPx - 1 : market.change24h
        NavigationStack {
            VStack(spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(Fmt.price(px)).font(.system(size: 22, weight: .bold, design: .monospaced)).foregroundStyle(Color.pnl(change))
                    Text(Fmt.pct(change)).font(.subheadline.monospaced()).foregroundStyle(Color.pnl(change))
                    Spacer()
                }
                .padding(.horizontal, 12)
                ChartToolbar(onIndicators: { showIndicators = true })
                PriceChartView(market: market)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                Text(L("Pinch to zoom · drag to scroll · long-press for crosshair"))
                    .font(.caption2).foregroundStyle(Color.hlMuted)
                    .padding(.bottom, 4)
            }
            .background(Color.hlBg)
            .navigationTitle(market.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Close")) { dismiss() } }
            }
            .sheet(isPresented: $showIndicators) { IndicatorsSheet() }
        }
    }
}

struct IndicatorsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List {
                Section {
                    Toggle(L("Volume"), isOn: $model.showVolume)
                    ForEach($model.indicators) { $cfg in
                        NavigationLink {
                            IndicatorEditor(config: $cfg)
                        } label: {
                            HStack(spacing: 10) {
                                Circle().fill(IndicatorPalette.color(cfg.color)).frame(width: 10, height: 10)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(cfg.label)
                                    Text(cfg.kind.isPane ? L("Separate pane") : L("On price chart"))
                                        .font(.caption2).foregroundStyle(Color.hlMuted)
                                }
                                Spacer()
                                Toggle("", isOn: $cfg.visible).labelsHidden()
                            }
                        }
                    }
                    .onDelete { model.indicators.remove(atOffsets: $0) }
                    .onMove { model.indicators.move(fromOffsets: $0, toOffset: $1) }
                } footer: {
                    Text(L("Tap an indicator to change its settings. Swipe left to delete."))
                }
                Section {
                    Menu {
                        ForEach(IndicatorKind.allCases) { k in
                            Button(k.title) {
                                model.indicators.append(IndicatorConfig.make(k, color: model.indicators.count))
                            }
                        }
                    } label: {
                        Label(L("Add indicator"), systemImage: "plus.circle")
                    }
                    Button(L("Reset to defaults"), role: .destructive) {
                        model.indicators = IndicatorConfig.defaults
                        model.showVolume = true
                    }
                }
            }
            .navigationTitle(L("Indicators"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } }
                ToolbarItem(placement: .topBarLeading) { EditButton() }
            }
        }
    }
}

struct IndicatorEditor: View {
    @Binding var config: IndicatorConfig

    var body: some View {
        Form {
            Section {
                Toggle(L("Show"), isOn: $config.visible)
            }
            Section(L("Parameters")) {
                switch config.kind {
                case .ema, .sma:
                    Stepper(L("Period: {0}", config.p1), value: $config.p1, in: 1...500)
                    presets([9, 20, 21, 50, 100, 200]) { config.p1 = $0 }
                case .bollinger:
                    Stepper(L("Period: {0}", config.p1), value: $config.p1, in: 2...200)
                    Stepper(L("Std. deviation: {0}", Fmt.input(config.mult, 1)), value: $config.mult, in: 0.5...5, step: 0.1)
                case .vwap:
                    Text(L("VWAP resets every day (UTC) on intraday timeframes.")).font(.caption).foregroundStyle(Color.hlMuted)
                case .rsi:
                    Stepper(L("Period: {0}", config.p1), value: $config.p1, in: 2...100)
                    Stepper(L("Overbought: {0}", Int(config.upper)), value: $config.upper, in: 50...95, step: 1)
                    Stepper(L("Oversold: {0}", Int(config.lower)), value: $config.lower, in: 5...50, step: 1)
                case .macd:
                    Stepper(L("Fast: {0}", config.p1), value: $config.p1, in: 2...100)
                    Stepper(L("Slow: {0}", config.p2), value: $config.p2, in: 3...200)
                    Stepper(L("Signal: {0}", config.p3), value: $config.p3, in: 2...100)
                case .stochastic:
                    Stepper(L("%K period: {0}", config.p1), value: $config.p1, in: 2...100)
                    Stepper(L("%K smoothing: {0}", config.p2), value: $config.p2, in: 1...20)
                    Stepper(L("%D period: {0}", config.p3), value: $config.p3, in: 1...20)
                    Stepper(L("Overbought: {0}", Int(config.upper)), value: $config.upper, in: 50...95, step: 1)
                    Stepper(L("Oversold: {0}", Int(config.lower)), value: $config.lower, in: 5...50, step: 1)
                }
            }
            Section(L("Color")) {
                HStack(spacing: 10) {
                    ForEach(0..<IndicatorPalette.colors.count, id: \.self) { i in
                        Circle()
                            .fill(IndicatorPalette.color(i))
                            .frame(width: 28, height: 28)
                            .overlay(Circle().stroke(Color.white, lineWidth: config.color == i ? 2 : 0))
                            .onTapGesture { config.color = i }
                    }
                }
            }
        }
        .navigationTitle(config.label)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func presets(_ values: [Int], set: @escaping (Int) -> Void) -> some View {
        HStack {
            ForEach(values, id: \.self) { v in
                Button("\(v)") { set(v) }.buttonStyle(.bordered).controlSize(.small)
            }
        }
    }
}
