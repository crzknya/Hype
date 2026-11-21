import Foundation
import UIKit
import Combine
import WalletConnectSign
import HyperCore

/// WalletConnect v2 (Reown) dApp side: pairs with an external wallet such as Rabby,
/// asks it to sign Hyperliquid typed data. Private keys never leave the wallet.
@MainActor
final class WalletConnectService {
    static let shared = WalletConnectService()
    static let projectId = "48bed0afd888a9b5ad0e86913d4c50f0"
    static let requiredMethods: Set<String> = ["eth_signTypedData_v4", "personal_sign", "eth_sendTransaction"]

    private var configured = false
    private var bag = Set<AnyCancellable>()
    private var settleWaiter: CheckedContinuation<Session, Error>?
    private var requestWaiters: [String: CheckedContinuation<String, Error>] = [:]

    // MARK: Setup

    func configure() {
        guard !configured else { return }
        configured = true
        Networking.configure(groupIdentifier: Self.keychainAccessGroup(),
                             projectId: Self.projectId,
                             socketFactory: URLSessionSocketFactory())
        let redirect = (try? AppMetadata.Redirect(native: "hype://", universal: nil))
        Pair.configure(metadata: AppMetadata(name: "Hype", description: "Hyperliquid trading app for iOS",
                                             url: "https://app.hyperliquid.xyz",
                                             icons: ["https://app.hyperliquid.xyz/favicon.ico"],
                                             redirect: redirect ?? (try! AppMetadata.Redirect(native: "hype://", universal: nil))))
        Sign.configure(crypto: WCCrypto())

        Sign.instance.sessionSettlePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.settleWaiter?.resume(returning: value.session)
                self?.settleWaiter = nil
            }
            .store(in: &bag)
        Sign.instance.sessionRejectionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.settleWaiter?.resume(throwing: HLError(L("Wallet rejected the connection: {0}", value.1.message)))
                self?.settleWaiter = nil
            }
            .store(in: &bag)
        Sign.instance.sessionResponsePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] response in
                guard let self else { return }
                let key = "\(response.id)"
                guard let waiter = self.requestWaiters.removeValue(forKey: key) else { return }
                switch response.result {
                case .response(let value):
                    if let sig = try? value.get(String.self) { waiter.resume(returning: sig) }
                    else { waiter.resume(throwing: HLError(L("Unexpected wallet response"))) }
                case .error(let err):
                    waiter.resume(throwing: HLError(L("Wallet declined: {0}", err.message)))
                }
            }
            .store(in: &bag)
    }

    /// The keychain access group this (re-signed) app actually has. The SDK stores keys in it,
    /// so it must be a group present in the app's entitlements — we read the default one at runtime.
    static func keychainAccessGroup() -> String {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.hype.trader.probe",
            kSecAttrAccount as String: "access-group-probe",
        ]
        var query = base
        query[kSecReturnAttributes as String] = true
        var result: AnyObject?
        var status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = Data("probe".utf8)
            add[kSecReturnAttributes as String] = true
            status = SecItemAdd(add as CFDictionary, &result)
        }
        if status == errSecSuccess, let attrs = result as? [String: Any],
           let group = attrs[kSecAttrAccessGroup as String] as? String, !group.isEmpty {
            return group
        }
        return Bundle.main.bundleIdentifier ?? "com.hype.trader"
    }

    // MARK: Connect

    /// Creates a pairing and returns the wc: link to open in the wallet.
    func startPairing() async throws -> PairingLink {
        configure()
        let methods: Set<String> = Self.requiredMethods
        let events: Set<String> = ["accountsChanged", "chainChanged"]
        let chains = [42161, 1, 8453, 10, 137, 56, 999].compactMap { Blockchain("eip155:\($0)") }   // 999 = HyperEVM
        let ns = ["eip155": ProposalNamespace(chains: chains, methods: methods, events: events)]
        let uri = try await Sign.instance.connect(namespaces: ns)
        return PairingLink(absolute: uri.absoluteString, encoded: uri.deeplinkUri)
    }

    /// Waits until the wallet approves the session.
    func waitForSession() async throws -> ConnectedWallet {
        let session: Session = try await withCheckedThrowingContinuation { cont in
            settleWaiter?.resume(throwing: HLError(L("Cancelled")))
            settleWaiter = cont
        }
        guard let acc = Self.account(of: session) else { throw HLError(L("The wallet did not share an EVM account")) }
        return ConnectedWallet(topic: session.topic, address: acc.address, chainId: acc.chainId)
    }

    func cancelPairing() {
        settleWaiter?.resume(throwing: HLError(L("Cancelled")))
        settleWaiter = nil
    }

    func hasSession(topic: String) -> Bool {
        configure()
        return Sign.instance.getSessions().contains { $0.topic == topic }
    }

    /// Whether the session was approved with all methods this app needs (older sessions lack eth_sendTransaction).
    func sessionSupportsAll(topic: String) -> Bool {
        configure()
        guard let session = Sign.instance.getSessions().first(where: { $0.topic == topic }),
              let methods = session.namespaces["eip155"]?.methods else { return false }
        return Self.requiredMethods.isSubset(of: methods)
    }

    func disconnect(topic: String) {
        configure()
        Task { try? await Sign.instance.disconnect(topic: topic) }
    }

    /// First EVM account of a session: (address, chainId).
    static func account(of session: Session) -> (address: String, chainId: UInt64)? {
        guard let acc = session.namespaces["eip155"]?.accounts.first else { return nil }
        return (acc.address.lowercased(), UInt64(acc.reference) ?? 42161)
    }

    // MARK: Signing

    /// Asks the wallet to sign EIP-712 typed data. Opens the wallet app so the user sees the request.
    func signTypedData(topic: String, address: String, chainId: UInt64, json: String, wallet: WalletApp?) async throws -> HLSignature {
        configure()
        guard let chain = Blockchain("eip155:\(chainId)") else { throw HLError(L("Unsupported chain")) }
        let params = AnyCodable([address, json])
        let request = try Request(topic: topic, method: "eth_signTypedData_v4", params: params, chainId: chain)
        let hex: String = try await withCheckedThrowingContinuation { cont in
            requestWaiters["\(request.id)"] = cont
            Task {
                do {
                    try await Sign.instance.request(params: request)
                    wallet?.open()
                } catch {
                    if let w = requestWaiters.removeValue(forKey: "\(request.id)") { w.resume(throwing: error) }
                }
            }
        }
        guard let sig = HLSignature(hex: hex) else { throw HLError(L("Unexpected wallet response")) }
        return sig
    }
}

/// An approved wallet session.
struct ConnectedWallet {
    let topic: String
    let address: String
    let chainId: UInt64
}

/// A WalletConnect pairing link (keeps SDK types out of the UI layer).
struct PairingLink: Equatable {
    let absolute: String   // wc:…
    let encoded: String    // percent-encoded for ?uri=
}

/// Known wallet apps for deep links.
enum WalletApp: String, CaseIterable, Identifiable, Codable {
    case rabby, metamask, trust, rainbow, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .rabby: return "Rabby"
        case .metamask: return "MetaMask"
        case .trust: return "Trust Wallet"
        case .rainbow: return "Rainbow"
        case .other: return L("Other wallet")
        }
    }
    private var scheme: String? {
        switch self {
        case .rabby: return "rabby://"
        case .metamask: return "metamask://"
        case .trust: return "trust://"
        case .rainbow: return "rainbow://"
        case .other: return nil
        }
    }

    /// Opens the wallet with a pairing URI.
    func open(uri: PairingLink) {
        let candidates: [String] = (scheme.map { ["\($0)wc?uri=\(uri.encoded)"] } ?? []) + [uri.absolute]
        Self.openFirst(candidates)
    }

    /// Brings the wallet to the foreground (to show a pending signature request).
    func open() {
        guard let scheme else { return }
        Self.openFirst([scheme])
    }

    private static func openFirst(_ urls: [String]) {
        guard let first = urls.first, let url = URL(string: first) else { return }
        UIApplication.shared.open(url, options: [:]) { ok in
            if !ok { openFirst(Array(urls.dropFirst())) }
        }
    }
}

extension WalletConnectService {
    /// Asks the wallet to send a transaction; returns the transaction hash.
    func sendTransaction(topic: String, from: String, chainId: UInt64, to: String, data: String, value: String = "0x0",
                         wallet: WalletApp?) async throws -> String {
        configure()
        guard sessionSupportsAll(topic: topic) else {
            throw HLError(L("Reconnect the wallet in Settings to allow deposits (Renew trading key)."))
        }
        guard let chain = Blockchain("eip155:\(chainId)") else { throw HLError(L("Unsupported chain")) }
        if let session = Sign.instance.getSessions().first(where: { $0.topic == topic }),
           let accounts = session.namespaces["eip155"]?.accounts,
           !accounts.contains(where: { $0.reference == String(chainId) }) {
            throw HLError(L("The wallet session does not include this network (chain {0}). Reconnect the wallet in Settings.", chainId))
        }
        let tx: [String: String] = ["from": from, "to": to, "data": data, "value": value]
        let request = try Request(topic: topic, method: "eth_sendTransaction", params: AnyCodable([tx]), chainId: chain)
        return try await withCheckedThrowingContinuation { cont in
            requestWaiters["\(request.id)"] = cont
            Task {
                do {
                    try await Sign.instance.request(params: request)
                    wallet?.open()
                } catch {
                    if let w = requestWaiters.removeValue(forKey: "\(request.id)") { w.resume(throwing: error) }
                }
            }
        }
    }
}

// MARK: - SDK plumbing

private struct WCCrypto: CryptoProvider {
    func recoverPubKey(signature: EthereumSignature, message: Data) throws -> Data {
        // Only needed for SIWE/One-Click Auth, which this app does not use.
        throw HLError("recoverPubKey is not supported")
    }

    func keccak256(_ data: Data) -> Data {
        Data(Keccak.hash256([UInt8](data)))
    }
}

private struct URLSessionSocketFactory: WebSocketFactory {
    func create(with url: URL) -> WebSocketConnecting { URLSessionWebSocket(url: url) }
}

/// WebSocket for the WalletConnect relay built on URLSessionWebSocketTask (no third-party socket library).
private final class URLSessionWebSocket: NSObject, WebSocketConnecting, URLSessionWebSocketDelegate {
    var isConnected = false
    var onConnect: (() -> Void)?
    var onDisconnect: ((Error?) -> Void)?
    var onText: ((String) -> Void)?
    var request: URLRequest

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?

    init(url: URL) {
        request = URLRequest(url: url)
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: OperationQueue())
    }

    func connect() {
        task?.cancel(with: .goingAway, reason: nil)
        let t = session.webSocketTask(with: request)
        task = t
        t.resume()
        receive(t)
    }

    func disconnect() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        if isConnected {
            isConnected = false
            onDisconnect?(nil)
        }
    }

    func write(string: String, completion: (() -> Void)?) {
        task?.send(.string(string)) { _ in completion?() }
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self, t === self.task else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let s): self.onText?(s)
                case .data(let d): if let s = String(data: d, encoding: .utf8) { self.onText?(s) }
                @unknown default: break
                }
                self.receive(t)
            case .failure(let error):
                if self.isConnected {
                    self.isConnected = false
                    self.onDisconnect?(error)
                }
            }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard webSocketTask === task else { return }
        isConnected = true
        onConnect?()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard webSocketTask === task else { return }
        if isConnected {
            isConnected = false
            onDisconnect?(nil)
        }
    }
}
