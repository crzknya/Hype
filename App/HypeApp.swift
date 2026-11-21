import SwiftUI
import UserNotifications

@main
struct HypeApp: App {
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
