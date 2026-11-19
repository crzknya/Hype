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
        receive(gen)
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

    private func receive(_ gen: Int) {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                switch result {
                case .failure(let error):
                    self.onError?(error.localizedDescription)
                    self.reconnect()
                case .success(let msg):
                    self.setConnected(true)
                    self.reconnectDelay = 1
                    var data: Data?
                    switch msg {
                    case .string(let s): data = Data(s.utf8)
                    case .data(let d): data = d
                    @unknown default: break
                    }
                    if let data, let json = try? JSON.parse(data) {
                        let channel = json["channel"].str
                        if channel != "pong" && channel != "subscriptionResponse" {
                            self.onMessage?(channel, json["data"])
                        }
                    }
                    self.receive(gen)
                }
            }
        }
    }
}
