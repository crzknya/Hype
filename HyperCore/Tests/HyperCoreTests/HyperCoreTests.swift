import XCTest
@testable import HyperCore

/// Vectors produced by tools/gen_vectors.py using the official hyperliquid-python-sdk.
final class HyperCoreTests: XCTestCase {
    var v: JSON!

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "vectors", withExtension: "json"))
        v = try JSON.parse(Data(contentsOf: url))
    }

    func testKeccak() {
        XCTAssertEqual(Hex.encode(Keccak.hash256([]), prefix: false), v["keccakEmpty"].str)
        XCTAssertEqual(Hex.encode(Keccak.hash256("abc"), prefix: false), v["keccakAbc"].str)
        // Multi-block input (> 136 bytes) sanity: must not crash and be 32 bytes.
        XCTAssertEqual(Keccak.hash256([UInt8](repeating: 7, count: 300)).count, 32)
    }

    func testAddress() throws {
        let w = try HLWallet(privateKeyHex: v["privateKey"].str)
        XCTAssertEqual(w.address, v["address"].str.lowercased())
        XCTAssertEqual(Address.checksum(w.address), v["address"].str)
    }

    /// Rebuild the Python test actions with our builders.
    func buildAction(_ name: String) -> MP {
        let mainOrder = OrderWire(asset: 4, isBuy: true, limitPx: HLNum.wire(1670.1), sz: HLNum.wire(0.0147), reduceOnly: false, kind: .limit(tif: .gtc))
        let tp = OrderWire(asset: 4, isBuy: false, limitPx: HLNum.wire(1800), sz: HLNum.wire(0.0147), reduceOnly: true,
                           kind: .trigger(triggerPx: HLNum.wire(1800), isMarket: true, tpsl: .tp))
        switch name {
        case "order", "orderVaultTestnet", "orderExpires": return HLAction.order([mainOrder, tp], grouping: .normalTpsl)
        case "cancel": return HLAction.cancel([(4, 123456789)])
        case "leverage": return HLAction.updateLeverage(asset: 0, isCross: true, leverage: 10)
        case "twap": return HLAction.twapOrder(asset: 1, isBuy: true, sz: "1.5", reduceOnly: false, minutes: 30, randomize: true)
        case "spotCloid":
            return HLAction.order([OrderWire(asset: 10107, isBuy: false, limitPx: "0.00012345", sz: "100000", reduceOnly: false,
                                             kind: .limit(tif: .ioc), cloid: "0x00000000000000000000000000000001")])
        case "setReferrer": return HLAction.setReferrer(code: "HYPEIOS")
        default: fatalError("unknown case \(name)")
        }
    }

    func testL1Actions() throws {
        let w = try HLWallet(privateKeyHex: v["privateKey"].str)
        for c in v["l1"].array {
            let name = c["name"].str
            let action = buildAction(name)
            XCTAssertEqual(Hex.encode(action.pack(), prefix: false), c["msgpack"].str, "msgpack \(name)")
            let nonce = UInt64(c["nonce"].int64!)
            let expires = c["expiresAfter"].int64.map { UInt64($0) }
            let vault = c["vault"].string
            let hash = HLSigning.actionHash(action, vault: vault, nonce: nonce, expiresAfter: expires)
            XCTAssertEqual(Hex.encode(hash, prefix: false), c["actionHash"].str, "hash \(name)")
            let digest = HLSigning.l1Digest(action, vault: vault, nonce: nonce, expiresAfter: expires, isMainnet: c["mainnet"].bool!)
            XCTAssertEqual(Hex.encode(digest, prefix: false), c["digest"].str, "digest \(name)")
            let sig = w.sign(digest: digest)
            XCTAssertEqual(Hex.encode(sig.r, prefix: false), c["r"].str, "r \(name)")
            XCTAssertEqual(Hex.encode(sig.s, prefix: false), c["s"].str, "s \(name)")
            XCTAssertEqual(String(sig.v), c["v"].str, "v \(name)")
        }
    }

    func testUserSigned() throws {
        let w = try HLWallet(privateKeyHex: v["privateKey"].str)
        for c in v["user"].array {
            let a = c["action"]
            let name = c["name"].str
            let mainnet = a["hyperliquidChain"].str == "Mainnet"
            let action: UserSignedAction
            switch name {
            case "usdSend": action = HLAction.usdSend(destination: a["destination"].str, amount: a["amount"].str, time: UInt64(a["time"].int64!), mainnet: mainnet)
            case "withdraw": action = HLAction.withdraw(destination: a["destination"].str, amount: a["amount"].str, time: UInt64(a["time"].int64!), mainnet: mainnet)
            case "classTransfer": action = HLAction.usdClassTransfer(amount: a["amount"].str, toPerp: a["toPerp"].bool!, nonce: UInt64(a["nonce"].int64!), mainnet: mainnet)
            case "spotSend": action = HLAction.spotSend(destination: a["destination"].str, token: a["token"].str, amount: a["amount"].str, time: UInt64(a["time"].int64!), mainnet: mainnet)
            case "approveAgent": action = HLAction.approveAgent(agentAddress: a["agentAddress"].str, agentName: a["agentName"].str, nonce: UInt64(a["nonce"].int64!), mainnet: mainnet)
            case "sendAsset": action = HLAction.sendAsset(destination: a["destination"].str, sourceDex: a["sourceDex"].str, destinationDex: a["destinationDex"].str,
                                                          token: a["token"].str, amount: a["amount"].str, fromSubAccount: a["fromSubAccount"].str,
                                                          nonce: UInt64(a["nonce"].int64!), mainnet: mainnet)
            case "approveAgentArb":
                action = HLAction.approveAgent(agentAddress: a["agentAddress"].str, agentName: a["agentName"].str,
                                               nonce: UInt64(a["nonce"].int64!), mainnet: mainnet, chainId: 0xa4b1)
                XCTAssertEqual(action.action["signatureChainId"]?.json(), "\"0xa4b1\"")
                // Typed data JSON for the wallet must be valid and carry the domain chain id.
                let td = try JSON.parse(Data(action.typedDataJSON().utf8))
                XCTAssertEqual(td["domain"]["chainId"].int, 42161)
                XCTAssertEqual(td["primaryType"].str, "HyperliquidTransaction:ApproveAgent")
                XCTAssertEqual(td["message"]["agentName"].str, "Hype iOS")
                XCTAssertEqual(td["types"]["HyperliquidTransaction:ApproveAgent"].array.count, 4)
            default: XCTFail("unknown \(name)"); continue
            }
            let digest = HLSigning.userSignedDigest(action)
            XCTAssertEqual(Hex.encode(digest, prefix: false), c["digest"].str, "digest \(name)")
            let sig = w.sign(digest: digest)
            XCTAssertEqual(Hex.encode(sig.r, prefix: false), c["r"].str, "r \(name)")
            XCTAssertEqual(Hex.encode(sig.s, prefix: false), c["s"].str, "s \(name)")
            XCTAssertEqual(String(sig.v), c["v"].str, "v \(name)")
            // Round-trip through the wallet hex format.
            let hex = Hex.encode(sig.r + sig.s + [UInt8(sig.v - 27)])
            XCTAssertEqual(HLSignature(hex: hex), sig)
        }
    }

    func testWire() {
        for pair in v["wire"].array {
            XCTAssertEqual(HLNum.wire(pair[0].dbl), pair[1].str)
        }
    }

    func testPriceRounding() {
        XCTAssertEqual(HLNum.wire(HLNum.roundPrice(1234.567, szDecimals: 4, isSpot: false)), "1234.6")
        XCTAssertEqual(HLNum.wire(HLNum.roundPrice(123456.7, szDecimals: 5, isSpot: false)), "123457")
        XCTAssertEqual(HLNum.wire(HLNum.roundPrice(0.000123456, szDecimals: 0, isSpot: false)), "0.000123")
        XCTAssertEqual(HLNum.wire(HLNum.roundPrice(0.000123456, szDecimals: 0, isSpot: true)), "0.00012346")
        XCTAssertEqual(HLNum.wire(HLNum.roundSize(0.123456, szDecimals: 3)), "0.123")
    }

    func testMsgPackInts() {
        XCTAssertEqual(MP.int(127).pack(), [0x7f])
        XCTAssertEqual(MP.int(128).pack(), [0xcc, 0x80])
        XCTAssertEqual(MP.int(1_700_000_000_000).pack(), [0xcf, 0, 0, 0x01, 0x8b, 0xcf, 0xe5, 0x68, 0x00])
        XCTAssertEqual(MP.int(-1).pack(), [0xff])
        XCTAssertEqual(MP.int(-100).pack(), [0xd0, 0x9c])
    }

    func testJSONEncoding() {
        let m = MP.map([("a", .int(1)), ("b", .str("x\"y")), ("c", .arr([.bool(true), .null]))])
        XCTAssertEqual(m.json(), "{\"a\":1,\"b\":\"x\\\"y\",\"c\":[true,null]}")
    }
}
