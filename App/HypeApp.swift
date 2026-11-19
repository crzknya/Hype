import SwiftUI
import UserNotifications

@main
struct HypeApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    init() {
        BackgroundAlerts.register()
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(Color.hlBg)
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = UIColor(Color.hlBg)
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .task { model.start() }
                .onChange(of: phase) { _, p in
                    model.sceneActive(p == .active)
                    if p == .background { BackgroundAlerts.schedule() }
                }
        }
    }
}
