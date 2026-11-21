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
}
