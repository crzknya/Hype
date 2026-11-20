import Foundation
import HyperCore

/// WebSocket client with subscription bookkeeping, keep-alive and auto-reconnect.
@MainActor
final class HLSocket {
    var onMessage: ((String, JSON) -> Void)?
    var onStatus: ((Bool) -> Void)?
    var onError: ((String) -> Void)?

    private var url: URL
    private var task: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private var subs: [String: MP] = [:]     // key -> subscription object
    private var pingTimer: Timer?
    private var reconnectDelay: TimeInterval = 1
    private var generation = 0
    private(set) var connected = false
    private var wantsConnection = false

    init(url: URL) { self.url = url }

    func setURL(_ u: URL) {
        url = u
        if wantsConnection { reconnect(immediately: true) }
    }

    func connect() {
        wantsConnection = true
        guard task == nil else { return }
        generation += 1
        let gen = generation
        let t = session.webSocketTask(with: url)
        t.maximumMessageSize = 16 * 1024 * 1024
        task = t
        t.resume()
        HLSocket.receiveLoop(t, gen: gen, inbox: inbox, l2: L2Assembler(), owner: WeakSocketRef(self))
        for (_, s) in subs { send(.map([("method", .str("subscribe")), ("subscription", s)])) }
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.send(.map([("method", .str("ping"))])) }
        }
    }

    func disconnect() {
        wantsConnection = false
        pingTimer?.invalidate()
        pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        setConnected(false)
    }

    private func reconnect(immediately: Bool = false) {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        setConnected(false)
        guard wantsConnection else { return }
        let delay = immediately ? 0 : reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 15)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.wantsConnection, self.task == nil else { return }
            self.connect()
        }
    }

    private func setConnected(_ v: Bool) {
        guard connected != v else { return }
        connected = v
        onStatus?(v)
    }

    static func key(_ s: MP) -> String { s.json() }

    func subscribe(_ s: MP) {
        let k = HLSocket.key(s)
        guard subs[k] == nil else { return }
        subs[k] = s
        send(.map([("method", .str("subscribe")), ("subscription", s)]))
    }

    func unsubscribe(_ s: MP) {
        let k = HLSocket.key(s)
        guard subs.removeValue(forKey: k) != nil else { return }
        send(.map([("method", .str("unsubscribe")), ("subscription", s)]))
    }

    func unsubscribeAll(where predicate: (MP) -> Bool) {
        for (_, s) in subs where predicate(s) { unsubscribe(s) }
    }

    private func send(_ m: MP) {
        guard let task else { return }
        task.send(.string(m.json())) { _ in }
    }

    /// Messages waiting for the main actor. Read on a background queue so the socket is drained
    /// continuously even while the UI is busy; snapshot-style channels keep only their newest message.
    private let inbox = SocketInbox()

    /// Per-channel message counts for the diagnostics line in Settings.
    private(set) var channelCounts: [String: Int] = [:]

    nonisolated private static func receiveLoop(_ t: URLSessionWebSocketTask, gen: Int, inbox: SocketInbox, l2: L2Assembler, owner: WeakSocketRef) {
        t.receive { result in
            switch result {
            case .failure(let error):
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let o = owner.value, gen == o.generation else { return }
                        o.onError?(error.localizedDescription)
                        o.reconnect()
                    }
                }
            case .success(let msg):
                var data: Data?
                switch msg {
                case .string(let s): data = Data(s.utf8)
                case .data(let d): data = d
                @unknown default: break
                }
                if let data, let json = try? JSON.parse(data) {
                    var channel = json["channel"].str
                    var payload = json["data"]
                    // The "l2" stream (what app.hyperliquid.xyz uses, ~2 updates/s) sends a snapshot and then
                    // compressed deltas; assemble them here and hand the UI a ready "l2Book" snapshot.
                    if channel == "l2" {
                        if let book = l2.handle(payload) { channel = "l2Book"; payload = book } else { channel = "" }
                    }
                    // fastAssetCtxs arrives compressed (base64 raw DEFLATE JSON) like l2 deltas.
                    if channel == "fastAssetCtxs", let b64 = payload.string {
                        if let raw = Data(base64Encoded: b64),
                           let inflated = try? (raw as NSData).decompressed(using: .zlib) as Data,
                           let decoded = try? JSON.parse(inflated) {
                            payload = decoded
                        } else { channel = "" }
                    }
                    if !channel.isEmpty, channel != "pong", channel != "subscriptionResponse",
                       inbox.push(channel, payload, gen: gen) {
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated { owner.value?.drain(gen) }
                        }
                    }
                }
                // Keep reading immediately, independent of the main thread (stops if the socket object is gone).
                if owner.value != nil { receiveLoop(t, gen: gen, inbox: inbox, l2: l2, owner: owner) }
            }
        }
    }

    private func drain(_ gen: Int) {
        let batch = inbox.take()
        guard gen == generation else { return }
        setConnected(true)
        reconnectDelay = 1
        for (channel, data) in batch {
            channelCounts[channel, default: 0] += 1
            onMessage?(channel, data)
        }
    }
}

/// Rebuilds order books from the "l2" stream: {"s": snapshot} or {"c": base64(raw DEFLATE(update))},
/// update = {"c": coin, "t": time, "l": [bidUpserts, askUpserts], "r": [removedBidIndexes, removedAskIndexes]}.
/// Removed indexes refer to the previous level arrays; upserts are {"p": px, "s": sz}. Same algorithm as the web app.
/// Used only from the socket's serial receive callbacks.
final class L2Assembler: @unchecked Sendable {
    private struct Level { let px: String; let sz: String; let n: Int; let pxValue: Double }
    private var books: [String: (bids: [Level], asks: [Level])] = [:]

    func handle(_ data: JSON) -> JSON? {
        let snap = data["s"]
        if !snap.isNull {
            let coin = snap["coin"].str
            let lv = snap["levels"]
            let bids = lv[0].array.map(Self.level), asks = lv[1].array.map(Self.level)
            books[coin] = (bids, asks)
            return Self.json(coin: coin, time: snap["time"], bids: bids, asks: asks)
        }
        guard let b64 = data["c"].string, let raw = Data(base64Encoded: b64),
              let inflated = try? (raw as NSData).decompressed(using: .zlib) as Data,
              let u = try? JSON.parse(inflated) else { return nil }
        let coin = u["c"].str
        guard let book = books[coin] else { return nil }
        let bids = Self.apply(book.bids, upserts: u["l"][0], removed: u["r"][0], descending: true)
        let asks = Self.apply(book.asks, upserts: u["l"][1], removed: u["r"][1], descending: false)
        books[coin] = (bids, asks)
        return Self.json(coin: coin, time: u["t"], bids: bids, asks: asks)
    }

    private static func level(_ j: JSON) -> Level {
        let px = j["px"].str
        return Level(px: px, sz: j["sz"].str, n: j["n"].int ?? 0, pxValue: Double(px) ?? 0)
    }

    private static func apply(_ levels: [Level], upserts: JSON, removed: JSON, descending: Bool) -> [Level] {
        let gone = Set(removed.array.compactMap(\.int))
        var byPx: [String: Level] = [:]
        for (i, l) in levels.enumerated() where !gone.contains(i) { byPx[l.px] = l }
        for u in upserts.array {
            let px = u["p"].str
            byPx[px] = Level(px: px, sz: u["s"].str, n: byPx[px]?.n ?? 0, pxValue: Double(px) ?? 0)
        }
        return byPx.values.sorted { descending ? $0.pxValue > $1.pxValue : $0.pxValue < $1.pxValue }
    }

    private static func json(coin: String, time: JSON, bids: [Level], asks: [Level]) -> JSON {
        func side(_ ls: [Level]) -> JSON {
            .array(ls.map { .object(["px": .string($0.px), "sz": .string($0.sz), "n": .number(Double($0.n))]) })
        }
        return .object(["coin": .string(coin), "time": time, "levels": .array([side(bids), side(asks)])])
    }
}

/// Immutable holder of a weak reference, safe to capture in @Sendable callbacks.
final class WeakSocketRef: @unchecked Sendable {
    weak var value: HLSocket?
    init(_ v: HLSocket) { value = v }
}

/// Thread-safe buffer between the socket's background queue and the main actor.
final class SocketInbox: @unchecked Sendable {
    /// Channels where only the newest message matters (full snapshots / latest values).
    private static let coalesced: Set<String> = ["l2Book", "bbo", "activeAssetCtx", "activeSpotAssetCtx", "activeAssetData"]
    private let lock = NSLock()
    private var queue: [(String, JSON)] = []
    private var latest: [String: JSON] = [:]
    private var latestOrder: [String] = []
    private var scheduled = false

    /// Adds a message; returns true when the caller should schedule a drain on the main thread.
    func push(_ channel: String, _ data: JSON, gen: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if Self.coalesced.contains(channel) {
            // l2Book/bbo/etc. are per-coin; key by coin so different coins don't overwrite each other.
            let key = channel + "|" + data["coin"].str
            if latest[key] == nil { latestOrder.append(key) }
            latest[key] = data
        } else {
            queue.append((channel, data))
        }
        if scheduled { return false }
        scheduled = true
        return true
    }

    func take() -> [(String, JSON)] {
        lock.lock(); defer { lock.unlock() }
        var out = queue
        for key in latestOrder {
            if let d = latest[key] { out.append((String(key.split(separator: "|", maxSplits: 1)[0]), d)) }
        }
        queue.removeAll(keepingCapacity: true)
        latest.removeAll(keepingCapacity: true)
        latestOrder.removeAll(keepingCapacity: true)
        scheduled = false
        return out
    }
}
