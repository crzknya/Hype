import Foundation
import Security

enum Keychain {
    private static let service = "com.hype.trader.keys"

    static func set(_ value: String, for account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

struct Account: Identifiable, Codable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case wallet, agent, privateKey, watch
        var id: String { rawValue }
        var title: String {
            switch self {
            case .wallet: return L("Wallet (WalletConnect)")
            case .agent: return L("API wallet")
            case .privateKey: return L("Private key")
            case .watch: return L("Watch-only")
            }
        }
        var canTrade: Bool { self != .watch }
        var canTransfer: Bool { self == .privateKey || self == .wallet }
    }

    var id = UUID()
    var name: String
    var address: String          // main account address (lowercase)
    var kind: Kind
    var signerAddress: String?   // address of the key stored in Keychain
    var vaultAddress: String?    // optional sub-account / vault to trade for
    var wcTopic: String?         // WalletConnect session topic (kind == .wallet)
    var wcChainId: UInt64?       // chain the wallet signs on (EIP-712 domain chain id)
    var walletApp: String?       // WalletApp raw value for deep links

    var keychainKey: String { "key-\(id.uuidString)" }
    var privateKey: String? { kind == .watch ? nil : Keychain.get(keychainKey) }
}
