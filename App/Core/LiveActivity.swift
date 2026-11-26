import Foundation
import ActivityKit
import HyperCore

/// Starts, updates and ends the positions Live Activity (Settings → Live Activity).
/// Updated every few seconds while the app runs; in the background iOS only lets the app refresh it
/// occasionally (background refresh), so the card shows when it was last updated.
@MainActor
enum LiveActivityController {
    private(set) static var lastUpdate = Date.distantPast
    private static var lastState: PositionActivityAttributes.ContentState?

    static var available: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    static func sync(_ model: AppModel, force: Bool = false) {
        guard model.liveActivityEnabled, available, model.account != nil else { endAll(); return }
        // Live mid prices (the all-markets stream keeps running in the background); the account stream does
        // not push on every price move, so PnL is recomputed from the price here.
        let state = makeState(positions: model.positions, mark: { model.mids[$0] ?? model.lastPrice($0) })
        guard !state.items.isEmpty else { endAll(); return }
        let name = model.account?.name ?? "Hype"
        apply(state, accountName: name, force: force)
    }

    static func apply(_ state: PositionActivityAttributes.ContentState, accountName: String, force: Bool) {
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(20 * 60))
        if let current = Activity<PositionActivityAttributes>.activities.first {
            // Enough for a live feel without spending the update budget: every 5 s, or on a new set of positions.
            let changedSet = lastState.map { Set($0.items.map(\.coin)) != Set(state.items.map(\.coin)) } ?? true
            guard force || changedSet || Date().timeIntervalSince(lastUpdate) >= 5 else { return }
            lastUpdate = Date()
            lastState = state
            Task { await current.update(content) }
        } else {
            lastUpdate = Date()
            lastState = state
            _ = try? Activity.request(attributes: PositionActivityAttributes(accountName: accountName), content: content, pushType: nil)
        }
    }

    static func endAll() {
        lastState = nil
        for a in Activity<PositionActivityAttributes>.activities {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }

    static func makeState(positions: [Position], mark: (String) -> Double) -> PositionActivityAttributes.ContentState {
        let sorted = positions.sorted { abs($0.positionValue) > abs($1.positionValue) }
        let items = sorted.prefix(3).map { p -> PositionActivityAttributes.Item in
            let m = mark(p.coin)
            let pnl = livePnl(p, m)
            let entryNotional = abs(p.szi) * p.entryPx
            let roe = entryNotional > 0 ? pnl * Double(max(p.leverage, 1)) / entryNotional : p.returnOnEquity
            var dist: Double?
            if let liq = p.liquidationPx, liq > 0, m > 0 { dist = abs(m - liq) / m }
            return PositionActivityAttributes.Item(coin: p.coin, isLong: p.isLong, leverage: p.leverage, pnl: pnl,
                                                   roe: roe, mark: m, liq: p.liquidationPx, liqDistance: dist)
        }
        return PositionActivityAttributes.ContentState(items: Array(items), totalPnl: positions.reduce(0) { $0 + livePnl($1, mark($1.coin)) },
                                                       updatedAt: Date())
    }

    /// Unrealized PnL at the given price (size × move from entry); the account's figure if there is no price.
    static func livePnl(_ p: Position, _ price: Double) -> Double {
        price > 0 && p.entryPx > 0 ? p.szi * (price - p.entryPx) : p.unrealizedPnl
    }

    /// Background refresh: positions of the active account straight from the API.
    static func refreshInBackground() async {
        let d = UserDefaults.standard
        guard d.object(forKey: "liveActivity") as? Bool ?? true, !Activity<PositionActivityAttributes>.activities.isEmpty,
              let data = d.data(forKey: "accounts"),
              let accounts = try? JSONDecoder().decode([Account].self, from: data),
              let acc = accounts.first(where: { $0.id.uuidString == d.string(forKey: "activeAccount") }) ?? accounts.first
        else { return }
        let net = HLNetwork(rawValue: d.string(forKey: "network") ?? "") ?? .mainnet
        let api = HLAPI(network: net)
        let user = (acc.vaultAddress?.isEmpty == false ? acc.vaultAddress! : acc.address).lowercased()
        guard let ch = try? await api.info(type: "clearinghouseState", [("user", .str(user))]),
              let mids = try? await api.info(type: "allMids") else { return }
        let positions = ch["assetPositions"].array.map(Position.init).filter { $0.szi != 0 }
        let state = makeState(positions: positions, mark: { mids[$0].double ?? 0 })
        if state.items.isEmpty { endAll() } else { apply(state, accountName: acc.name, force: true) }
    }
}
