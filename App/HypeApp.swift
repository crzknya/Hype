import SwiftUI
import UserNotifications

@main
struct HypeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    init() {
        BackgroundAlerts.register()
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        ThemeAppearance.apply()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(model.theme.isDark ? .dark : .light)
                .task { model.start() }
                .onChange(of: phase) { _, p in
                    model.sceneActive(p == .active)
                    if p == .background { BackgroundAlerts.schedule() }
                }
        }
    }
}

/// The app is portrait; the full-screen chart unlocks landscape while it is open.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }
}

@MainActor
enum OrientationLock {
    static var mask: UIInterfaceOrientationMask = .portrait

    /// Allows the given orientations; `rotateTo` also turns the screen (e.g. back to portrait on close).
    static func allow(_ m: UIInterfaceOrientationMask, rotateTo: UIInterfaceOrientationMask? = nil) {
        mask = m
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                var vc = window.rootViewController
                while let c = vc {
                    c.setNeedsUpdateOfSupportedInterfaceOrientations()
                    vc = c.presentedViewController
                }
            }
            if let rotateTo { scene.requestGeometryUpdate(.iOS(interfaceOrientations: rotateTo)) { _ in } }
        }
    }
}

/// Bars use the system iOS 26 Liquid Glass look; only the title colors are themed.
enum ThemeAppearance {
    static func apply() {
        let nav = UINavigationBarAppearance()
        nav.configureWithDefaultBackground()
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        let edge = UINavigationBarAppearance()
        edge.configureWithTransparentBackground()
        UINavigationBar.appearance().scrollEdgeAppearance = edge
    }
}
