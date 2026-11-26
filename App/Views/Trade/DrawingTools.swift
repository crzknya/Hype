import SwiftUI

/// Row of drawing tools under the timeframes (shown with the pencil button): cursor, ruler, lines, ray,
/// trend line, rectangle, Fibonacci; magnet mode, hide all, delete all.
struct DrawToolBar: View {
    @Environment(AppModel.self) private var model
    let coin: String
    @State private var confirmDelete = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(DrawTool.allCases) { tool in
                    Button {
                        model.drawTool = model.drawTool == tool && tool != .cursor ? .cursor : tool
                        if tool != .cursor { model.selectedDrawingId = nil }
                    } label: {
                        icon(tool)
                            .frame(width: 34, height: 28)
                            .foregroundStyle(model.drawTool == tool ? Color.hlAccent : Color.primary.opacity(0.8))
                            .background(model.drawTool == tool ? Color.hlAccent.opacity(0.2) : Color.hlCard2,
                                        in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tool.title)
                }
                Divider().frame(height: 20).padding(.horizontal, 2)
                Button { model.magnet = model.magnet.next } label: {
                    HStack(spacing: 2) {
                        Text("🧲").font(.system(size: 13)).opacity(model.magnet == .off ? 0.35 : 1)
                        if model.magnet == .strong { Text("+").font(.system(size: 11, weight: .bold)) }
                    }
                    .frame(width: 38, height: 28)
                    .background(model.magnet == .off ? Color.hlCard2 : Color.hlAccent.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.magnet.title)
                Button { model.drawingsHidden.toggle() } label: {
                    Image(systemName: model.drawingsHidden ? "eye.slash" : "eye")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 34, height: 28)
                        .foregroundStyle(model.drawingsHidden ? Color.hlAccent : Color.primary.opacity(0.8))
                        .background(Color.hlCard2, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.drawingsHidden ? L("Show drawings") : L("Hide drawings"))
                Button { confirmDelete = true } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 34, height: 28)
                        .foregroundStyle(Color.hlRed)
                        .background(Color.hlCard2, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(model.drawings(for: coin).isEmpty)
                .accessibilityLabel(L("Delete all drawings"))
            }
            .padding(.horizontal, 10)
        }
        .confirmationDialog(L("Delete all drawings on {0}?", model.displayName(coin)), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(L("Delete all"), role: .destructive) {
                model.setDrawings([], for: coin)
                model.selectedDrawingId = nil
            }
        }
    }

    @ViewBuilder
    private func icon(_ tool: DrawTool) -> some View {
        switch tool {
        case .cursor: Image(systemName: "cursorarrow").font(.system(size: 13, weight: .semibold))
        case .ruler: Image(systemName: "ruler").font(.system(size: 13, weight: .semibold))
        case .hline: Image(systemName: "minus").font(.system(size: 15, weight: .bold))
        case .hray: Image(systemName: "arrow.right").font(.system(size: 13, weight: .semibold))
        case .trend: Image(systemName: "line.diagonal").font(.system(size: 14, weight: .semibold))
        case .rect: Image(systemName: "rectangle").font(.system(size: 13, weight: .semibold))
        case .fib: Text("Fib").font(.system(size: 11, weight: .bold))
        }
    }
}

/// Over the chart: the active tool's hint, or quick actions for the selected drawing.
struct DrawingOverlay: View {
    @Environment(AppModel.self) private var model
    let coin: String
    @State private var editing: UUID?

    var body: some View {
        VStack {
            if let id = model.selectedDrawingId, let d = model.drawings(for: coin).first(where: { $0.id == id }) {
                HStack(spacing: 10) {
                    Menu {
                        ForEach(ChartDrawing.palette.indices, id: \.self) { i in
                            Button { var c = d; c.color = i; model.updateDrawing(c, coin: coin) } label: {
                                Label(colorName(i), systemImage: i == d.color ? "checkmark.circle.fill" : "circle.fill")
                            }
                        }
                    } label: {
                        Circle().fill(d.swiftColor).frame(width: 18, height: 18)
                            .overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: 1))
                    }
                    Button { editing = id } label: { Image(systemName: "gearshape") }
                    Button { var c = d; c.locked.toggle(); model.updateDrawing(c, coin: coin) } label: {
                        Image(systemName: d.locked ? "lock.fill" : "lock.open")
                    }
                    Button { model.deleteDrawing(id, coin: coin) } label: { Image(systemName: "trash") }
                        .foregroundStyle(Color.hlRed)
                    Button { model.selectedDrawingId = nil } label: { Image(systemName: "xmark") }
                        .foregroundStyle(Color.hlMuted)
                }
                .font(.system(size: 14, weight: .semibold))
                .buttonStyle(.plain)
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
            } else if model.drawTool != .cursor {
                Text(model.drawTool.hint)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .allowsHitTesting(false)
            }
            Spacer()
        }
        .padding(.top, 4)
        .sheet(item: Binding(get: { editing.map { EditingID(id: $0) } }, set: { editing = $0?.id })) { e in
            DrawingSettingsSheet(coin: coin, id: e.id)
        }
    }

    private struct EditingID: Identifiable { let id: UUID }

    private func colorName(_ i: Int) -> String {
        [L("Violet"), L("Blue"), L("Cyan"), L("Green"), L("Yellow"), L("Orange"), L("Red"), L("White")][i]
    }
}

/// All settings of one drawing: color, width, style, labels, extension, exact prices, alert.
struct DrawingSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let coin: String
    let id: UUID
    @State private var d: ChartDrawing?
    @State private var priceA = ""
    @State private var priceB = ""

    var body: some View {
        NavigationStack {
            Form {
                if let binding = Binding($d) {
                    content(binding)
                } else {
                    Text(L("This drawing no longer exists.")).foregroundStyle(Color.hlMuted)
                }
            }
            .navigationTitle(d?.kind.title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) { save(); dismiss() }.disabled(d == nil)
                }
            }
            .keyboardDoneToolbar()
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            d = model.drawings(for: coin).first { $0.id == id }
            if let d {
                priceA = Fmt.input(d.a.p, 8)
                priceB = Fmt.input(d.b.p, 8)
            }
        }
    }

    @ViewBuilder
    private func content(_ d: Binding<ChartDrawing>) -> some View {
        let kind = d.wrappedValue.kind
        Section(L("Style")) {
            HStack(spacing: 10) {
                ForEach(ChartDrawing.palette.indices, id: \.self) { i in
                    Circle().fill(ChartDrawing.palette[i]).frame(width: 26, height: 26)
                        .overlay(Circle().stroke(Color.primary, lineWidth: d.wrappedValue.color == i ? 2.5 : 0))
                        .onTapGesture { d.wrappedValue.color = i }
                }
            }
            .padding(.vertical, 4)
            Picker(L("Width"), selection: d.width) {
                Text("1").tag(1.0)
                Text("1.5").tag(1.5)
                Text("2").tag(2.0)
                Text("3").tag(3.0)
            }
            .pickerStyle(.segmented)
            Picker(L("Line"), selection: d.style) {
                ForEach(DrawLineStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            TextField(L("Label"), text: d.text)
        }
        Section(L("Position")) {
            NumField(title: kind.twoPoint ? L("Price 1") : L("Price"), text: $priceA)
            if kind.twoPoint { NumField(title: L("Price 2"), text: $priceB) }
            if kind == .trend {
                Toggle(L("Extend left"), isOn: d.extendLeft)
                Toggle(L("Extend right"), isOn: d.extendRight)
            }
            if kind == .fib { Toggle(L("Extend lines right"), isOn: d.extendRight) }
            if kind != .fib { Toggle(L("Price on the scale"), isOn: d.showPrice) }
            Toggle(L("Locked"), isOn: d.locked)
        }
        if kind == .hline || kind == .hray {
            Section {
                Button {
                    save()
                    guard let p = Fmt.parse(priceA), p > 0 else { return }
                    let last = model.lastPrice(coin)
                    model.alerts.append(PriceAlert(coin: coin, name: model.displayName(coin), price: p, above: p >= last))
                    model.show(.success, L("Alert set at {0}", Fmt.price(p)))
                } label: {
                    Label(L("Create a price alert at this level"), systemImage: "bell.badge")
                }
            }
        }
        Section {
            Button(L("Delete drawing"), role: .destructive) {
                model.deleteDrawing(id, coin: coin)
                dismiss()
            }
        }
    }

    private func save() {
        guard var d else { return }
        if let p = Fmt.parse(priceA), p > 0 {
            d.a.p = p
            if !d.kind.twoPoint { d.b.p = p }
        }
        if d.kind.twoPoint, let p = Fmt.parse(priceB), p > 0 { d.b.p = p }
        model.updateDrawing(d, coin: coin)
    }
}
