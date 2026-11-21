import Foundation
import AudioToolbox
import UIKit
import UserNotifications
import HyperCore

/// Market categories from `perpCategories` (as the web's market filters).
enum MarketCategory: String, CaseIterable, Identifiable {
    case crypto, stocks, commodities, indices, fx, preipo, rates
    var id: String { rawValue }

    static func normalize(_ raw: String) -> String {
        switch raw.lowercased() {
        case "stock", "stocks": return "stocks"
        case "fx": return "fx"
        default: return raw.lowercased()
        }
    }

    var title: String {
        switch self {
        case .crypto: return L("Crypto")
        case .stocks: return L("Stocks")
        case .commodities: return L("Commodities")
        case .indices: return L("Indices")
        case .fx: return "FX"
        case .preipo: return "Pre-IPO"
        case .rates: return L("Rates")
        }
    }
}

/// Sound and background notification for fills.
enum FillAlerts {
    static func playSound() {
        AudioServicesPlaySystemSound(1057)
    }

    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Posts a local notification when the app is not in the foreground (fills that arrive before iOS suspends it).
    @MainActor
    static func notifyIfBackground(_ text: String) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = "Hype"
        content.body = text
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}

// MARK: - Referrals

struct ReferralInfo {
    struct Referee: Identifiable, Hashable {
        let user: String
        let cumVlm: Double
        let rewards: Double
        let joined: Date
        var id: String { user }
    }

    var referredBy: String?          // referrer's code
    var cumVlm: Double = 0
    var unclaimedRewards: Double = 0
    var claimedRewards: Double = 0
    var stage = ""                   // needToCreateCode / needToTrade / ready
    var requiredVlm: Double = 0
    var code: String?
    var referees: [Referee] = []

    init(_ j: JSON) {
        let by = j["referredBy"]
        referredBy = by["code"].string ?? by.string
        cumVlm = j["cumVlm"].dbl
        unclaimedRewards = j["unclaimedRewards"].dbl
        claimedRewards = j["claimedRewards"].dbl
        let st = j["referrerState"]
        stage = st["stage"].str
        requiredVlm = st["data"]["required"].dbl
        code = st["data"]["code"].string
        referees = st["data"]["referralStates"].array.map {
            Referee(user: $0["user"].str, cumVlm: $0["cumVlm"].dbl, rewards: $0["cumFeesRewardedToReferrer"].dbl,
                    joined: Date(timeIntervalSince1970: $0["timeJoined"].dbl / 1000))
        }.sorted { $0.cumVlm > $1.cumVlm }
    }
}

// MARK: - Points

struct PointsInfo {
    struct Week: Identifiable, Hashable {
        let start: String
        let end: String
        let points: Double
        let referredVlm: Double
        var id: String { start }
    }
    var total: Double = 0
    var rank: Int?
    var percentile: Double?
    var weeks: [Week] = []

    init(_ j: JSON) {
        let u = j["userSummary"]
        rank = u["rank"].int
        percentile = u["percentile"].double
        weeks = u["distributionHistory"].array.map {
            Week(start: $0["startDate"].str, end: $0["endDate"].str, points: $0["points"].dbl, referredVlm: $0["referredVlm"].dbl)
        }.sorted { $0.start > $1.start }
        total = weeks.reduce(0) { $0 + $1.points }
    }
}

// MARK: - Leaderboard

struct LeaderboardRow: Identifiable, Hashable {
    let address: String
    let name: String?
    let accountValue: Double
    /// window ("day", "week", "month", "allTime") → (pnl, roi, volume)
    let perf: [String: [Double]]
    var id: String { address }

    func value(_ window: String, _ index: Int) -> Double { perf[window]?[index] ?? 0 }
}

extension AppModel {
    /// Description of a HIP-3 market (perpAnnotation), cached.
    func loadAnnotation(_ coin: String) async {
        guard annotations[coin] == nil,
              let j = try? await api.info(type: "perpAnnotation", [("coin", .str(coin))]) else { return }
        annotations[coin] = j["description"].string ?? ""
    }

    func loadReferral() async -> ReferralInfo? {
        guard let user = masterAddress,
              let j = try? await api.info(type: "referral", [("user", .str(user))]) else { return nil }
        return ReferralInfo(j)
    }

    /// Creates the account's own referral code.
    func registerReferrer(code: String) async throws {
        let c = code.trimmingCharacters(in: .whitespaces).uppercased()
        guard !c.isEmpty else { throw HLError(L("Enter a code")) }
        try await submit(.map([("type", .str("registerReferrer")), ("code", .str(c))]), vault: .some(nil))
    }

    func claimReferralRewards() async throws {
        try await submit(.map([("type", .str("claimRewards"))]), vault: .some(nil))
    }

    /// Points summary: an info request authenticated by an agent signature (as the web app).
    func loadPoints() async throws -> PointsInfo {
        guard let user = masterAddress else { throw HLError(L("Add an account in Settings")) }
        let w = try wallet()
        let ts = UInt64(Date().timeIntervalSince1970)
        let digest = HLSigning.agentDigest(connectionId: HLSigning.userPointsConnectionId(timestamp: ts), isMainnet: network.isMainnet)
        let sig = w.sign(digest: digest)
        let j = try await api.info(type: "userPoints", [
            ("user", .str(user)),
            ("signature", .map([("r", .str(Hex.encode(sig.r))), ("s", .str(Hex.encode(sig.s))), ("v", .int(Int64(sig.v)))])),
            ("timestamp", .int(Int64(ts))),
        ])
        return PointsInfo(j)
    }

    /// Full leaderboard from stats-data.hyperliquid.xyz (large: parsed off the main thread).
    func loadLeaderboard() async throws -> [LeaderboardRow] {
        let url = URL(string: "https://stats-data.hyperliquid.xyz/\(network.isMainnet ? "Mainnet" : "Testnet")/leaderboard")!
        let (data, _) = try await URLSession.shared.data(from: url)
        return try await Task.detached(priority: .userInitiated) { () throws -> [LeaderboardRow] in
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = root["leaderboardRows"] as? [[String: Any]] else { throw HLError(L("Unexpected leaderboard format")) }
            func num(_ v: Any?) -> Double {
                if let d = v as? Double { return d }
                if let s = v as? String { return Double(s) ?? 0 }
                if let n = v as? NSNumber { return n.doubleValue }
                return 0
            }
            return rows.compactMap { r -> LeaderboardRow? in
                guard let addr = r["ethAddress"] as? String else { return nil }
                var perf: [String: [Double]] = [:]
                for w in r["windowPerformances"] as? [[Any]] ?? [] {
                    guard w.count == 2, let k = w[0] as? String, let v = w[1] as? [String: Any] else { continue }
                    perf[k] = [num(v["pnl"]), num(v["roi"]), num(v["vlm"])]
                }
                return LeaderboardRow(address: addr.lowercased(), name: r["displayName"] as? String,
                                      accountValue: num(r["accountValue"]), perf: perf)
            }
        }.value
    }
}
