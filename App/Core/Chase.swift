import Foundation
import HyperCore

/// A chase order (as app.hyperliquid.xyz): a post-only limit that the app keeps repricing to the top of
/// the book (one tick inside the spread) until it fills. It runs only while the app is open; a stopped
/// chase stays on the book as a normal limit order.
struct ChaseOrder: Identifiable, Equatable {
    enum Status: Equatable { case working, finished, stopped }

    let id = UUID()
    let coin: String
    let isBuy: Bool
    let reduceOnly: Bool
    let cloid: String
    let startPx: Double
    /// Max distance from the start price as a fraction (0 = no limit; the web caps it at 5%).
    let maxDistance: Double
    var size: Double
    var price: Double
    var placedAt = Date()
    var status: Status = .working
}

extension AppModel {
    static let maxActiveChases = 5

    static func newCloid() -> String {
        var b = [UInt8](repeating: 0, count: 16)
        for i in b.indices { b[i] = UInt8.random(in: 0...255) }
        return Hex.encode(b)
    }

    var activeChases: [ChaseOrder] { chases.filter { $0.status == .working } }

    /// Best bid / ask: the live bbo for the selected market, a REST snapshot otherwise.
    func bestBidAsk(_ m: Market) async -> (bid: Double, ask: Double)? {
        if m.id == selectedCoin, let q = bbo, q.bid > 0, q.ask > 0 { return (q.bid, q.ask) }
        guard let j = try? await api.info(type: "l2Book", [("coin", .str(m.id))]) else { return nil }
        let bid = j["levels"][0][0]["px"].dbl, ask = j["levels"][1][0]["px"].dbl
        return bid > 0 && ask > 0 ? (bid, ask) : nil
    }

    /// One tick inside the spread on our side, never crossing; stays put while we are the best price.
    func chaseTarget(_ m: Market, isBuy: Bool, bid: Double, ask: Double, current: Double?) -> Double {
        let tick = pow(10, -Double(m.priceDecimals(isBuy ? bid : ask)))
        if isBuy {
            if let c = current, abs(c - bid) < tick / 2 { return bid }
            let p = bid + tick
            return p < ask - tick / 2 ? p : bid
        } else {
            if let c = current, abs(c - ask) < tick / 2 { return ask }
            let p = ask - tick
            return p > bid + tick / 2 ? p : ask
        }
    }

    private func chaseWire(_ m: Market, isBuy: Bool, px: Double, sz: Decimal, reduceOnly: Bool, cloid: String) -> OrderWire {
        OrderWire(asset: m.asset, isBuy: isBuy, limitPx: HLNum.wire(m.roundPrice(px)), sz: HLNum.wire(sz),
                  reduceOnly: reduceOnly, kind: .limit(tif: .alo), cloid: cloid)
    }

    func startChase(_ m: Market, isBuy: Bool, size: Double, reduceOnly: Bool, maxDistance: Double) async throws {
        if activeChases.contains(where: { $0.coin == m.id && $0.isBuy == isBuy }) {
            throw HLError(L("A chase order is already active for this market and direction."))
        }
        guard activeChases.count < Self.maxActiveChases else {
            throw HLError(L("Maximum number of active chase orders is {0}.", Self.maxActiveChases))
        }
        guard maxDistance <= 0.05 else { throw HLError(L("Max chase distance cannot exceed 5% of the current price.")) }
        guard let q = await bestBidAsk(m) else { throw HLError(L("No order book for {0}", m.name)) }
        let px = chaseTarget(m, isBuy: isBuy, bid: q.bid, ask: q.ask, current: nil)
        let sz = m.roundSize(size, mode: .plain)
        let cloid = Self.newCloid()
        _ = try await submit(HLAction.order([chaseWire(m, isBuy: isBuy, px: px, sz: sz, reduceOnly: reduceOnly, cloid: cloid)]))
        chases.append(ChaseOrder(coin: m.id, isBuy: isBuy, reduceOnly: reduceOnly, cloid: cloid, startPx: px,
                                 maxDistance: maxDistance, size: NSDecimalNumber(decimal: sz).doubleValue, price: px))
        Task { await refreshOrders() }
        runChases()
    }

    /// Stops repricing; the order stays on the book as a normal limit order.
    func stopChase(_ id: UUID) {
        guard let i = chases.firstIndex(where: { $0.id == id }) else { return }
        chases[i].status = .stopped
    }

    func runChases() {
        guard chaseTask == nil else { return }
        chaseTask = Task { [weak self] in
            while let self, !Task.isCancelled, !self.activeChases.isEmpty {
                await self.stepChases()
                try? await Task.sleep(for: .milliseconds(700))
            }
            self?.chaseTask = nil
        }
    }

    private func stepChases() async {
        if !accountStreamLive { await refreshOrders() }
        for c in activeChases {
            guard let m = market(c.coin) else { continue }
            let open = openOrders.first { $0.cloid?.lowercased() == c.cloid.lowercased() }
            guard let open else {
                // Gone from the book: filled (or cancelled by the user).
                if Date().timeIntervalSince(c.placedAt) > 4 { finishChase(c.id, L("Chase order finished: {0}", m.name)) }
                continue
            }
            guard let q = await bestBidAsk(m) else { continue }
            let target = chaseTarget(m, isBuy: c.isBuy, bid: q.bid, ask: q.ask, current: c.price)
            if c.maxDistance > 0, abs(target - c.startPx) / c.startPx > c.maxDistance {
                if let i = chases.firstIndex(where: { $0.id == c.id }) { chases[i].status = .stopped }
                show(.info, L("Chase on {0} reached the max distance; the order stays as a limit order.", m.name))
                continue
            }
            let newPx = NSDecimalNumber(decimal: m.roundPrice(target)).doubleValue
            guard abs(newPx - c.price) > 1e-12 else { continue }
            let w = chaseWire(m, isBuy: c.isBuy, px: newPx, sz: m.roundSize(open.sz, mode: .plain), reduceOnly: c.reduceOnly, cloid: c.cloid)
            do {
                _ = try await submit(HLAction.modify(cloid: c.cloid, order: w))
                if let i = chases.firstIndex(where: { $0.id == c.id }) {
                    chases[i].price = newPx
                    chases[i].size = open.sz
                    chases[i].placedAt = Date()
                }
            } catch {
                let msg = error.localizedDescription
                if msg.contains("filled") || msg.contains("canceled") || msg.contains("never placed") {
                    finishChase(c.id, L("Chase order finished: {0}", m.name))
                }
                // Post-only rejections (the book moved) are retried on the next step.
            }
        }
    }

    private func finishChase(_ id: UUID, _ message: String) {
        guard let i = chases.firstIndex(where: { $0.id == id }), chases[i].status == .working else { return }
        chases[i].status = .finished
        show(.success, message)
    }
}
