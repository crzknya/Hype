import Foundation
import CryptoKit
import HyperCore

/// Verifies Unit deposit addresses: each of Unit's three guardian nodes signs the generated address with
/// its own P-256 key (ECDSA over SHA-256, signature = base64 r‖s). An address is shown only if at least two
/// guardians signed it for *this* user and chain, so a tampered API response or a man-in-the-middle cannot
/// substitute its own address.
enum UnitGuardians {
    /// Mainnet guardian public keys (uncompressed X9.63), as published in Unit's docs.
    static let mainnet: [(node: String, key: String)] = [
        ("unit-node", "04dc6f89f921dc816aa69b687be1fcc3cc1d48912629abc2c9964e807422e1047e0435cb5ba0fa53cb9a57a9c610b4e872a0a2caedda78c4f85ebafcca93524061"),
        ("hl-node", "048633ea6ab7e40cdacf37d1340057e84bb9810de0687af78d031e9b07b65ad4ab379180ab55075f5c2ebb96dab30d2c2fab49d5635845327b6a3c27d20ba4755b"),
        ("field-node", "04ae2ab20787f816ea5d13f36c4c4f7e196e29e867086f3ce818abb73077a237f841b33ada5be71b83f4af29f333dedc5411ca4016bd52ab657db2896ef374ce99"),
    ]
    static let threshold = 2

    /// Number of guardians whose signature over this address verifies.
    static func verifiedCount(signatures: [String: JSON], chain: String, asset: String,
                              destination: String, address: String) -> Int {
        mainnet.reduce(0) { n, g in
            guard let sigText = signatures[g.node]?.string,
                  let sigData = Data(base64Encoded: sigText),
                  let sig = try? P256.Signing.ECDSASignature(rawRepresentation: sigData),
                  let keyBytes = Hex.decode(g.key),
                  let key = try? P256.Signing.PublicKey(x963Representation: Data(keyBytes)) else { return n }
            let ok = payloads(node: g.node, chain: chain, asset: asset, destination: destination, address: address)
                .contains { key.isValidSignature(sig, for: $0) }
            return ok ? n + 1 : n
        }
    }

    /// Messages a guardian may have signed: the current format
    /// `{node}:user-{coinType}-{destinationChain}-{destinationAddress}-{address}` and the older
    /// `{node}:{destinationAddress}-{destinationChain}-{asset}-{address}-{sourceChain}-deposit`,
    /// with the destination as sent and EIP-55 checksummed. Every variant names our address and the
    /// deposit address, so accepting any of them keeps the guarantee.
    static func payloads(node: String, chain: String, asset: String, destination: String, address: String) -> [Data] {
        let dests = unique([destination, destination.lowercased(), Address.checksum(destination)])
        let coinTypes = unique([chain, "ethereum"])
        var out: [String] = []
        for d in dests {
            for ct in coinTypes { out.append("\(node):user-\(ct)-hyperliquid-\(d)-\(address)") }
            out.append("\(node):\(d)-hyperliquid-\(asset)-\(address)-\(chain)-deposit")
        }
        return out.map { Data($0.utf8) }
    }

    private static func unique(_ a: [String]) -> [String] {
        var seen = Set<String>()
        return a.filter { seen.insert($0).inserted }
    }
}
