import Foundation

/// Hyperliquid deposit: an ERC-20 USDC transfer to the Bridge2 contract on Arbitrum One.
public enum HLBridge {
    /// CCTP withdrawal through the HyperEVM: Arbitrum's CCTP domain, gas limit and fee (USDC), as the web app.
    public static let cctpArbitrumDomain: UInt64 = 3
    public static let cctpGasLimit: UInt64 = 200_000
    public static let cctpFee = 0.2
    public static let legacyWithdrawFee = 1.0
    public static let maxWithdrawal = 10_000_000.0
    /// Bridge2 on Arbitrum One (mainnet). Deposits below 5 USDC are lost.
    public static let mainnetBridge = "0x2df1c51e09aecf9cacb7bc98cb1742757f163df7"
    /// Native USDC on Arbitrum One (6 decimals).
    public static let arbitrumUSDC = "0xaf88d065e77c8cc2239327c5edb3a432268e5831"
    public static let arbitrumChainId: UInt64 = 42161
    public static let hyperEvmChainId: UInt64 = 999
    public static let minDeposit: Double = 5
    public static let usdcDecimals = 6

    /// HyperCore ⇄ HyperEVM system address of a spot token (HYPE uses 0x2222…2222).
    public static func systemAddress(tokenIndex: Int) -> String {
        if tokenIndex == 150 { return "0x2222222222222222222222222222222222222222" }
        var b = [UInt8](repeating: 0, count: 20)
        b[0] = 0x20
        var v = UInt64(tokenIndex)
        var i = 19
        while v > 0 && i > 0 { b[i] = UInt8(v & 0xff); v >>= 8; i -= 1 }
        return Hex.encode(b)
    }
}

public enum ERC20 {
    /// keccak("transfer(address,uint256)")[0..<4]
    public static let transferSelector: [UInt8] = Array(Keccak.hash256("transfer(address,uint256)").prefix(4))
    /// keccak("balanceOf(address)")[0..<4]
    public static let balanceOfSelector: [UInt8] = Array(Keccak.hash256("balanceOf(address)").prefix(4))

    static func word(address: String) -> [UInt8] {
        let b = Hex.decode(address) ?? []
        return [UInt8](repeating: 0, count: max(0, 32 - b.count)) + b.suffix(32)
    }

    static func word(_ v: UInt64) -> [UInt8] {
        [UInt8](repeating: 0, count: 24) + (0..<8).reversed().map { UInt8(truncatingIfNeeded: v >> UInt64($0 * 8)) }
    }

    /// Calldata for transfer(to, amount) where amount is in token base units.
    public static func transferData(to: String, amount: UInt64) -> String {
        Hex.encode(transferSelector + word(address: to) + word(amount))
    }

    public static func balanceOfData(owner: String) -> String {
        Hex.encode(balanceOfSelector + word(address: owner))
    }

    /// Calldata for transfer(to, amount) with a 32-byte amount word (any size).
    public static func transferData(to: String, amountWord: [UInt8]) -> String {
        Hex.encode(transferSelector + word(address: to) + amountWord)
    }

    /// 32-byte big-endian word of amount × 10^decimals, rounded down; exact for 18-decimal tokens.
    public static func baseUnitsWord(_ amount: Double, decimals: Int) -> [UInt8] {
        guard amount > 0, decimals >= 0 else { return [UInt8](repeating: 0, count: 32) }
        let d = HLNum.round(amount, places: min(decimals, 18), mode: .down)
        let scaled = NSDecimalNumber(decimal: d).multiplying(byPowerOf10: Int16(decimals))
        var digits = String(scaled.stringValue.split(separator: ".").first ?? "0").compactMap(\.wholeNumberValue)
        var bytes: [UInt8] = []
        while digits.contains(where: { $0 != 0 }) {
            var rem = 0
            var next: [Int] = []
            for dg in digits {
                let cur = rem * 10 + dg
                let q = cur / 256
                rem = cur % 256
                if !(next.isEmpty && q == 0) { next.append(q) }
            }
            bytes.insert(UInt8(rem), at: 0)
            digits = next
        }
        return [UInt8](repeating: 0, count: max(0, 32 - bytes.count)) + bytes.suffix(32)
    }

    /// JSON-RPC quantity ("0x…" without leading zeros) of a big-endian word.
    public static func quantity(_ word: [UInt8]) -> String {
        let hex = Hex.encode(word, prefix: false).drop { $0 == "0" }
        return "0x" + (hex.isEmpty ? "0" : String(hex))
    }

    /// Decimal value of a hex quantity / uint256 result in token units.
    public static func units(hex: String, decimals: Int) -> Double {
        var v = 0.0
        for c in hex.lowercased().replacingOccurrences(of: "0x", with: "") {
            guard let d = c.hexDigitValue else { continue }
            v = v * 16 + Double(d)
        }
        return v / pow(10, Double(decimals))
    }

    /// Converts a decimal amount to base units, rounding down.
    public static func baseUnits(_ amount: Double, decimals: Int) -> UInt64 {
        let d = HLNum.round(amount, places: decimals, mode: .down)
        let scaled = NSDecimalNumber(decimal: d).multiplying(byPowerOf10: Int16(decimals))
        return scaled.uint64Value
    }
}
