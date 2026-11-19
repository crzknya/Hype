import Foundation
import HyperCore

enum HLNetwork: String, CaseIterable, Identifiable, Codable {
    case mainnet, testnet
    var id: String { rawValue }
    var isMainnet: Bool { self == .mainnet }
    var title: String { self == .mainnet ? "Mainnet" : "Testnet" }
    var api: URL { URL(string: isMainnet ? "https://api.hyperliquid.xyz" : "https://api.hyperliquid-testnet.xyz")! }
    var ws: URL { URL(string: isMainnet ? "wss://api.hyperliquid.xyz/ws" : "wss://api.hyperliquid-testnet.xyz/ws")! }
    var explorer: String { isMainnet ? "https://app.hyperliquid.xyz/explorer" : "https://app.hyperliquid-testnet.xyz/explorer" }
}

struct HLError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

/// Thin REST client for /info and /exchange.
final class HLAPI {
    var network: HLNetwork
    private let session: URLSession

    init(network: HLNetwork) {
        self.network = network
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
    }

    func info(_ body: MP) async throws -> JSON {
        try await post(path: "/info", body: body.json())
    }

    func info(type: String, _ extra: [(String, MP)] = []) async throws -> JSON {
        try await info(.map([("type", .str(type))] + extra))
    }

    func exchange(action: MP, nonce: UInt64, signature: HLSignature, vault: String?) async throws -> JSON {
        let body = MP.map([
            ("action", action),
            ("nonce", .int(Int64(nonce))),
            ("signature", signature.mp),
            ("vaultAddress", vault.map { .str($0.lowercased()) } ?? .null),
        ])
        return try await post(path: "/exchange", body: body.json())
    }

    private func post(path: String, body: String) async throws -> JSON {
        var req = URLRequest(url: network.api.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(body.utf8)
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            if code == 429 { throw HLError(L("Rate limit exceeded (429). Please wait a moment.")) }
            throw HLError("HTTP \(code): \(text.prefix(300))")
        }
        do {
            return try JSON.parse(data)
        } catch {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw HLError(L("Unexpected response: {0}", text.prefix(300)))
        }
    }
}
