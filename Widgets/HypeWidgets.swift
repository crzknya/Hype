import WidgetKit
import SwiftUI
import ActivityKit

@main
struct HypeWidgetsBundle: WidgetBundle {
    var body: some Widget {
        PositionsLiveActivity()
    }
}

private let green = Color(red: 0.36, green: 0.86, blue: 0.62)
private let red = Color(red: 0.96, green: 0.38, blue: 0.45)
private let accent = Color(red: 0.62, green: 0.5, blue: 1.0)
private func pnlColor(_ v: Double) -> Color { v >= 0 ? green : red }

struct PositionsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PositionActivityAttributes.self) { context in
            LockScreenPositions(state: context.state, account: context.attributes.accountName)
                .activityBackgroundTint(Color.black.opacity(0.82))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let s = context.state
            let first = s.items.first
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    if let f = first {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.coin).font(.headline)
                            Text("\(f.isLong ? "LONG" : "SHORT") \(f.leverage)x")
                                .font(.caption2.bold()).foregroundStyle(f.isLong ? green : red)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(ActivityFormat.usd(s.totalPnl)).font(.headline.monospacedDigit()).foregroundStyle(pnlColor(s.totalPnl))
                        if let f = first { Text(ActivityFormat.pct(f.roe)).font(.caption.monospacedDigit()).foregroundStyle(pnlColor(f.roe)) }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 4) {
                        ForEach(s.items.prefix(3), id: \.coin) { PositionLine(item: $0) }
                    }
                }
            } compactLeading: {
                Text(first?.coin ?? "Hype").font(.caption.bold()).foregroundStyle(accent)
            } compactTrailing: {
                Text(ActivityFormat.usd(s.totalPnl)).font(.caption.monospacedDigit()).foregroundStyle(pnlColor(s.totalPnl))
            } minimal: {
                Image(systemName: s.totalPnl >= 0 ? "arrow.up.right" : "arrow.down.right")
                    .foregroundStyle(pnlColor(s.totalPnl))
            }
        }
    }
}

private struct LockScreenPositions: View {
    let state: PositionActivityAttributes.ContentState
    let account: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Hype · \(account)").font(.caption.bold()).foregroundStyle(accent)
                Spacer()
                Text(ActivityFormat.usd(state.totalPnl)).font(.headline.monospacedDigit()).foregroundStyle(pnlColor(state.totalPnl))
            }
            ForEach(state.items.prefix(3), id: \.coin) { PositionLine(item: $0) }
            Text(state.updatedAt, style: .relative)
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
    }
}

private struct PositionLine: View {
    let item: PositionActivityAttributes.Item

    var body: some View {
        HStack(spacing: 6) {
            Text(item.coin).font(.subheadline.bold())
            Text("\(item.isLong ? "L" : "S") \(item.leverage)x").font(.caption2.bold())
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background((item.isLong ? green : red).opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(item.isLong ? green : red)
            Spacer(minLength: 4)
            if let d = item.liqDistance {
                // Distance to liquidation: orange under 10 %, red under 3 %.
                Label(String(format: "%.1f%%", d * 100), systemImage: "exclamationmark.triangle")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(d < 0.03 ? red : d < 0.1 ? .orange : .secondary)
            }
            Text(ActivityFormat.usd(item.pnl)).font(.subheadline.monospacedDigit()).foregroundStyle(pnlColor(item.pnl))
        }
        .lineLimit(1)
    }
}
