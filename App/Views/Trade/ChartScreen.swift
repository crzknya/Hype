import SwiftUI

/// Candle chart bound to the app model (selected market, interval, indicators).
struct PriceChartView: View {
    @Environment(AppModel.self) private var model
    let market: Market

    var body: some View {
        ZStack {
            CandleChart(candles: model.candles, lines: model.chartLines(market),
                        layers: ChartLayers.build(model.candles, configs: model.indicators, interval: model.interval),
                        decimals: nil, showVolume: model.showVolume,
                        logScale: model.logScale, intervalSeconds: model.interval.seconds,
                        onNeedHistory: { Task { await model.loadOlderCandles() } })
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
    @State private var showTimeframes = false

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
                Button { showTimeframes = true } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 26)
                        .foregroundStyle(Color.hlMuted)
                }
            }
            .padding(.leading, 10)
            Button { model.logScale.toggle() } label: {
                Text("LOG").font(.system(size: 10, weight: .bold))
                    .frame(width: 34, height: 28)
                    .foregroundStyle(model.logScale ? Color.hlAccent : Color.hlMuted)
                    .background(model.logScale ? Color.hlAccent.opacity(0.18) : Color.hlCard2, in: RoundedRectangle(cornerRadius: 6))
            }
            .accessibilityLabel(L("Logarithmic scale"))
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
        .sheet(isPresented: $showTimeframes) {
            TimeframeSheet()
                .presentationDetents([.height(430), .large])
                .presentationDragIndicator(.visible)
        }
    }
}

/// Timeframe picker: choose the active timeframe and which ones live in the toolbar.
struct TimeframeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 5)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Timeframe")).font(.headline)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(CandleInterval.allCases) { iv in
                    chip(iv.rawValue, selected: model.interval == iv, check: false) {
                        model.interval = iv
                        dismiss()
                    }
                }
            }

            HStack {
                Text(L("Show in toolbar")).font(.headline)
                Spacer()
                Button(L("Default")) { model.visibleIntervals = CandleInterval.quick }
                    .font(.caption.bold())
            }
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(CandleInterval.allCases) { iv in
                    chip(iv.rawValue, selected: model.visibleIntervals.contains(iv), check: true) {
                        model.toggleIntervalVisibility(iv)
                        Haptics.tap(enabled: model.haptics)
                    }
                }
            }
            Text(L("Tap to add or remove timeframes from the toolbar. At least one stays."))
                .font(.caption).foregroundStyle(Color.hlMuted)
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.hlBg.ignoresSafeArea())
    }

    private func chip(_ title: String, selected: Bool, check: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if check {
                    Image(systemName: selected ? "checkmark" : "plus")
                        .font(.system(size: 9, weight: .bold))
                }
                Text(title).font(.system(size: 14, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .foregroundStyle(selected ? Color.hlAccent : Color.hlMuted)
            .background(selected ? Color.hlAccent.opacity(0.18) : Color.hlCard2, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.hlAccent.opacity(0.6) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct ChartScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let market: Market
    @State private var showIndicators = false

    var body: some View {
        let px = model.lastPrice(market.id)
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
            .themedBackground()
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
    @State private var editMode: EditMode = .inactive
    @State private var editing: UUID?

    private var isEditing: Bool { editMode.isEditing }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List {
                Section {
                    Toggle(L("Volume"), isOn: $model.showVolume)
                }
                Section {
                    ForEach(model.indicators) { cfg in
                        IndicatorRow(config: binding(for: cfg.id), showToggle: !isEditing) { editing = cfg.id }
                    }
                    .onDelete { model.indicators.remove(atOffsets: $0) }
                    .onMove { model.indicators.move(fromOffsets: $0, toOffset: $1) }
                    if model.indicators.isEmpty {
                        Text(L("No indicators")).foregroundStyle(Color.hlMuted)
                    }
                } header: {
                    Text(L("Indicators"))
                } footer: {
                    Text(L("Tap an indicator to change its settings. Swipe left to delete."))
                }
                if !isEditing {
                    Section {
                        Menu {
                            ForEach(IndicatorKind.allCases) { k in
                                Button(k.title) {
                                    let cfg = IndicatorConfig.make(k, color: model.indicators.count)
                                    model.indicators.append(cfg)
                                    editing = cfg.id
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
            }
            .environment(\.editMode, $editMode)
            .navigationTitle(L("Indicators"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $editing) { id in
                IndicatorEditor(config: binding(for: id))
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(isEditing ? L("Finish") : L("Reorder")) {
                        withAnimation { editMode = isEditing ? .inactive : .active }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Close")) { dismiss() }
                }
            }
        }
    }
}

extension IndicatorsSheet {
    /// Binding looked up by id, so rows that SwiftUI re-renders right after a deletion
    /// never index past the end of the array (that crashed when deleting the last indicator).
    func binding(for id: UUID) -> Binding<IndicatorConfig> {
        Binding(
            get: { model.indicators.first { $0.id == id } ?? IndicatorConfig.make(.ema, color: 0) },
            set: { new in
                if let i = model.indicators.firstIndex(where: { $0.id == id }) { model.indicators[i] = new }
            })
    }
}

/// Indicator row: tapping the text opens the editor, the switch only toggles visibility.
private struct IndicatorRow: View {
    @Binding var config: IndicatorConfig
    let showToggle: Bool
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Circle().fill(IndicatorPalette.color(config.color)).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(config.label).foregroundStyle(config.visible ? .primary : Color.hlMuted)
                    Text(config.kind.isPane ? L("Separate pane") : L("On price chart"))
                        .font(.caption2).foregroundStyle(Color.hlMuted)
                }
                Spacer(minLength: 0)
                if showToggle {
                    Image(systemName: "slider.horizontal.3").font(.caption).foregroundStyle(Color.hlMuted)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { if showToggle { onOpen() } }
            if showToggle {
                Toggle("", isOn: $config.visible).labelsHidden()
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
                case .volumeProfile:
                    Stepper(L("Rows: {0}", config.p1), value: $config.p1, in: 10...200, step: 5)
                    Stepper(L("Value area: {0}%", Int(config.upper)), value: $config.upper, in: 50...95, step: 5)
                    Stepper(L("Width: {0}% of chart", config.p2), value: $config.p2, in: 10...60, step: 5)
                    Text(L("Volume by price for the candles on screen. POC is the level with the most volume; VAH/VAL bound the value area. Green: volume of rising candles, red: falling.")).font(.caption).foregroundStyle(Color.hlMuted)
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
                            .overlay(Circle().stroke(Color.hlInk, lineWidth: config.color == i ? 2 : 0))
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
