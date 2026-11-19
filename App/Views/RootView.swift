import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ZStack(alignment: .top) {
            TabView(selection: $model.tab) {
                MarketsView()
                    .tabItem { Label("Рынки", systemImage: "chart.bar.xaxis") }
                    .tag(AppTab.markets)
                TradeView()
                    .tabItem { Label("Торговля", systemImage: "arrow.left.arrow.right") }
                    .tag(AppTab.trade)
                PortfolioView()
                    .tabItem { Label("Портфель", systemImage: "briefcase") }
                    .tag(AppTab.portfolio)
                ToolsView()
                    .tabItem { Label("Инструменты", systemImage: "wrench.and.screwdriver") }
                    .tag(AppTab.tools)
                SettingsView()
                    .tabItem { Label("Настройки", systemImage: "gearshape") }
                    .tag(AppTab.settings)
            }
            .tint(.hlAccent)

            if let t = model.toast {
                ToastView(toast: t)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { model.toast = nil }
                    .zIndex(10)
            }

            if model.locked {
                LockView().zIndex(20)
            }
        }
        .animation(.spring(duration: 0.3), value: model.toast)
        .background(Color.hlBg.ignoresSafeArea())
    }
}

struct LockView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            Color.hlBg.ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.hlAccent)
                Text("Hype заблокирован").font(.title3.bold())
                Button {
                    unlock()
                } label: {
                    Label("Разблокировать (\(Biometrics.name))", systemImage: "faceid")
                        .padding(.horizontal, 20).padding(.vertical, 12)
                        .background(Color.hlAccent.opacity(0.15), in: Capsule())
                }
            }
        }
        .task { unlock() }
    }

    private func unlock() {
        Task {
            if await Biometrics.authenticate(reason: "Разблокировать Hype") { model.locked = false }
        }
    }
}
