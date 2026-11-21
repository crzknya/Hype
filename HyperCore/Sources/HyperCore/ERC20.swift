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
    public static let minDeposit: Double = 5
    public static let usdcDecimals = 6
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

    /// Converts a decimal amount to base units, rounding down.
    public static func baseUnits(_ amount: Double, decimals: Int) -> UInt64 {
        let d = HLNum.round(amount, places: decimals, mode: .down)
        let scaled = NSDecimalNumber(decimal: d).multiplying(byPowerOf10: Int16(decimals))
        return scaled.uint64Value
    }
}
