import Foundation
import UIKit
import UserNotifications
import LocalAuthentication
import BackgroundTasks
import HyperCore

enum Haptics {
    static func success(enabled: Bool = true) {
        guard enabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
    static func error(enabled: Bool = true) {
        guard enabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
    static func tap(enabled: Bool = true) {
        guard enabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func notify(title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}

/// Shows notifications as banners even when the app is in the foreground.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

enum Biometrics {
    static var available: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    static var name: String {
        let c = LAContext()
        _ = c.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch c.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return L("passcode")
        }
    }

    static func authenticate(reason: String) async -> Bool {
        let c = LAContext()
        return (try? await c.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}

/// Best-effort background price-alert checks (iOS decides when to run them).
enum BackgroundAlerts {
    static let taskId = "com.hype.trader.refresh"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskId, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            schedule()
            let work = Task {
                await check()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    static func schedule() {
        let req = BGAppRefreshTaskRequest(identifier: taskId)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(req)
    }

    static func check() async {
        await LiveActivityController.refreshInBackground()
        let d = UserDefaults.standard
        guard let data = d.data(forKey: "alerts"),
              var alerts = try? JSONDecoder().decode([PriceAlert].self, from: data), !alerts.isEmpty else { return }
        let net = HLNetwork(rawValue: d.string(forKey: "network") ?? "") ?? .mainnet
        guard let mids = try? await HLAPI(network: net).info(type: "allMids") else { return }
        var remaining: [PriceAlert] = []
        for var a in alerts {
            guard let px = mids[a.coin].double else { remaining.append(a); continue }
            if (a.above && px >= a.price) || (!a.above && px <= a.price) {
                Notifier.notify(title: L("Price alert"), body: L("{0} {1} {2} — now {3}", a.name, a.above ? L("above") : L("below"), Fmt.price(a.price), Fmt.price(px)))
                if a.repeating { a.above.toggle(); remaining.append(a) }
            } else {
                remaining.append(a)
            }
        }
        alerts = remaining
        d.set(try? JSONEncoder().encode(alerts), forKey: "alerts")
    }
}
