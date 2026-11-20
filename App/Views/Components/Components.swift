import SwiftUI
import HyperCore

extension AppModel {
    /// Runs an async operation with toast + haptic feedback.
    func perform(_ op: @escaping @MainActor () async throws -> String?) {
        Task { @MainActor in
            do {
                if let msg = try await op() { show(.success, msg) }
                Haptics.success(enabled: haptics)
            } catch {
                show(.error, error.localizedDescription)
                Haptics.error(enabled: haptics)
            }
        }
    }
}

struct ToastView: View {
    let toast: Toast
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            Text(toast.text).font(.subheadline).foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(color.opacity(0.5), lineWidth: 1))
        .shadow(radius: 10)
    }
    var icon: String {
        switch toast.kind {
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }
    var color: Color {
        switch toast.kind {
        case .success: return .hlGreen
        case .error: return .hlRed
        case .info: return .hlAccent
        }
    }
}

struct ChangePill: View {
    let value: Double
    var body: some View {
        Text(Fmt.pct(value))
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .frame(minWidth: 72)
            .padding(.vertical, 5)
            .background(value >= 0 ? Color.hlGreen.opacity(0.85) : Color.hlRed.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct Badge: View {
    let text: String
    var color: Color = .hlAccent
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
    }
}

struct SideBadge: View {
    let isLong: Bool
    var spot = false
    var body: some View {
        Badge(text: spot ? (isLong ? "BUY" : "SELL") : (isLong ? "LONG" : "SHORT"), color: isLong ? .hlGreen : .hlRed)
    }
}

struct Stat: View {
    let title: String
    let value: String
    var color: Color = .primary
    var align: HorizontalAlignment = .leading
    var body: some View {
        VStack(alignment: align, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(Color.hlMuted)
            Text(value).font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(AppTheme.current == .neon ? 16 : 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .themedCard()
    }
}

/// Numeric input with title and optional trailing accessory.
struct NumField<Trailing: View>: View {
    let title: String
    @Binding var text: String
    var placeholder: String = "0"
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.caption).foregroundStyle(Color.hlMuted).lineLimit(1).fixedSize()
            TextField(placeholder, text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 15, weight: .medium, design: .monospaced))
            trailing
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(Color.hlCard2, in: RoundedRectangle(cornerRadius: 8))
    }
}

extension NumField where Trailing == EmptyView {
    init(title: String, text: Binding<String>, placeholder: String = "0") {
        self.init(title: title, text: text, placeholder: placeholder) { EmptyView() }
    }
}

struct PrimaryButton: View {
    let title: String
    var color: Color = .hlAccent
    var busy = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if busy { ProgressView().tint(.black) } else {
                    Text(title).font(.system(size: 16, weight: .bold))
                        .foregroundStyle(AppTheme.current == .neon && color == .hlAccent ? .white : .black)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background {
                // Neon: the default accent button becomes a purple→cyan gradient.
                if AppTheme.current == .neon && color == .hlAccent {
                    RoundedRectangle(cornerRadius: 14).fill(LinearGradient.hlAccent).opacity(disabled ? 0.4 : 1)
                } else {
                    RoundedRectangle(cornerRadius: AppTheme.current == .neon ? 14 : 10).fill(color.opacity(disabled ? 0.4 : 1))
                }
            }
        }
        .disabled(disabled || busy)
    }
}

struct PercentButtons: View {
    let onSelect: (Double) -> Void
    var values: [Double] = [0.1, 0.25, 0.5, 0.75, 1]
    var body: some View {
        HStack(spacing: 4) {
            ForEach(values, id: \.self) { v in
                Button { onSelect(v) } label: {
                    Text(v == 1 ? "MAX" : "\(Int(v * 100))%")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.hlCard2, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct EmptyState: View {
    let text: String
    var icon = "tray"
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.title2).foregroundStyle(Color.hlMuted)
            Text(text).font(.subheadline).foregroundStyle(Color.hlMuted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

struct ConnectionDot: View {
    let connected: Bool
    var body: some View {
        Circle().fill(connected ? Color.hlGreen : Color.hlRed).frame(width: 7, height: 7)
    }
}

extension View {
    func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    func keyboardDoneToolbar() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(L("Done")) { hideKeyboard() }
            }
        }
    }
}


/// A pending destructive action waiting for user confirmation.
struct PendingConfirm: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let button: String
    let action: () -> Void
}

extension View {
    /// Shows a confirmation dialog while `item` is set.
    func confirmDialog(_ item: Binding<PendingConfirm?>) -> some View {
        confirmationDialog(item.wrappedValue?.title ?? "",
                           isPresented: Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } }),
                           titleVisibility: .visible, presenting: item.wrappedValue) { c in
            Button(c.button, role: .destructive) { c.action() }
            Button(L("Cancel"), role: .cancel) {}
        } message: { c in
            Text(c.message)
        }
    }
}


extension View {
    /// Card surface: flat in Classic; larger radius with a hairline border in Neon.
    func themedCard(_ fill: Color = .hlCard) -> some View {
        let r = AppTheme.current.cardRadius
        return self
            .background(fill, in: RoundedRectangle(cornerRadius: r, style: .continuous))
            .overlay {
                if AppTheme.current == .neon {
                    RoundedRectangle(cornerRadius: r, style: .continuous).stroke(Color.white.opacity(0.07), lineWidth: 1)
                }
            }
    }
}
