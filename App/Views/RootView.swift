import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ZStack(alignment: .top) {
            // Tapping the open Trade tab again toggles Chart ⇄ Order (the binding is set on every tap).
            TabView(selection: Binding(get: { model.tab }, set: { new in
                if new == model.tab && new == .trade { model.tradeTabReselected += 1 }
                model.tab = new
            })) {
                MarketsView()
                    .tabItem { Label(L("Markets"), systemImage: "chart.bar.xaxis") }
                    .tag(AppTab.markets)
                TradeView()
                    .tabItem { Label(L("Trade"), systemImage: "arrow.left.arrow.right") }
                    .tag(AppTab.trade)
                PortfolioView()
                    .tabItem { Label(L("Portfolio"), systemImage: "briefcase") }
                    .tag(AppTab.portfolio)
                ToolsView()
                    .tabItem { Label(L("Tools"), systemImage: "wrench.and.screwdriver") }
                    .tag(AppTab.tools)
                SettingsView()
                    .tabItem { Label(L("Settings"), systemImage: "gearshape") }
                    .tag(AppTab.settings)
            }
            .tint(.hlAccent)
            .id("\(model.language.rawValue)-\(model.theme.rawValue)")

            if let t = model.toast {
                ToastView(toast: t)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { model.toast = nil }
                    .zIndex(10)
            }

            if model.perfOverlay {
                PerfOverlay()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 8)
                    .padding(.top, 48)
                    .allowsHitTesting(false)
                    .zIndex(15)
            }

            if model.locked {
                LockView().zIndex(20)
            }
        }
        .animation(.spring(duration: 0.3), value: model.toast)
        .themedBackground()
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
                Text(L("Hype is locked")).font(.title3.bold())
                Button {
                    unlock()
                } label: {
                    Label(L("Unlock ({0})", Biometrics.name), systemImage: "faceid")
                        .padding(.horizontal, 20).padding(.vertical, 12)
                        .background(Color.hlAccent.opacity(0.15), in: Capsule())
                }
            }
        }
        .task { unlock() }
    }

    private func unlock() {
        Task {
            if await Biometrics.authenticate(reason: L("Unlock Hype")) { model.locked = false }
        }
    }
}
