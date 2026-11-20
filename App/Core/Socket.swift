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
        HLSocket.receiveLoop(t, gen: gen, inbox: inbox, owner: WeakSocketRef(self))
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

    nonisolated private static func receiveLoop(_ t: URLSessionWebSocketTask, gen: Int, inbox: SocketInbox, owner: WeakSocketRef) {
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
                    let channel = json["channel"].str
                    if channel != "pong" && channel != "subscriptionResponse",
                       inbox.push(channel, json["data"], gen: gen) {
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated { owner.value?.drain(gen) }
                        }
                    }
                }
                // Keep reading immediately, independent of the main thread (stops if the socket object is gone).
                if owner.value != nil { receiveLoop(t, gen: gen, inbox: inbox, owner: owner) }
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
