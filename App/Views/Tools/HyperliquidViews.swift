import SwiftUI
import HyperCore

/// Leaderboard (stats-data.hyperliquid.xyz), as app.hyperliquid.xyz/leaderboard.
struct LeaderboardView: View {
    @Environment(AppModel.self) private var model
    @State private var rows: [LeaderboardRow] = []
    @State private var loading = false
    @State private var error: String?
    @State private var window = "month"
    @State private var metric = 0          // 0 pnl, 1 roi, 2 volume, 3 account value
    @State private var search = ""

    private let windows = ["day", "week", "month", "allTime"]
    private func windowTitle(_ w: String) -> String {
        switch w {
        case "day": return L("24h")
        case "week": return L("7d")
        case "month": return L("30d")
        default: return L("All")
        }
    }

    var body: some View {
        let me = model.masterAddress
        let filtered = search.isEmpty ? rows : rows.filter {
            $0.address.contains(search.lowercased()) || ($0.name?.lowercased().contains(search.lowercased()) ?? false)
        }
        let sorted = filtered.sorted { key($0) > key($1) }
        let top = Array(sorted.prefix(200))
        let myRank = me.flatMap { addr in sorted.firstIndex { $0.address == addr } }
        List {
            Section {
                Picker(L("Period"), selection: $window) {
                    ForEach(windows, id: \.self) { Text(windowTitle($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker(L("Sort"), selection: $metric) {
                    Text("PnL").tag(0); Text("ROI").tag(1); Text(L("Volume")).tag(2); Text(L("Account value")).tag(3)
                }
                .pickerStyle(.segmented)
                if let myRank, let row = me.flatMap({ addr in sorted.first { $0.address == addr } }) {
                    HStack {
                        Text(L("You: #{0}", myRank + 1)).font(.subheadline.bold())
                        Spacer()
                        Text(Fmt.signedUsd(row.value(window, 0))).foregroundStyle(Color.pnl(row.value(window, 0)))
                    }
                }
            }
            Section {
                if loading { ProgressView(L("Loading leaderboard…")) }
                if let error { Text(error).foregroundStyle(Color.hlRed).font(.caption) }
                ForEach(Array(top.enumerated()), id: \.element.id) { i, r in
                    HStack(spacing: 10) {
                        Text("\(i + 1)").font(.caption.monospaced()).foregroundStyle(Color.hlMuted).frame(width: 34, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.name ?? Address.short(r.address)).font(.subheadline.bold())
                                .foregroundStyle(r.address == me ? Color.hlAccent : .primary)
                            Text(L("Account {0} · Vol {1}", Fmt.compactUsd(r.accountValue), Fmt.compactUsd(r.value(window, 2))))
                                .font(.caption2).foregroundStyle(Color.hlMuted)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(Fmt.signedUsd(r.value(window, 0), 0)).font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.pnl(r.value(window, 0)))
                            Text(Fmt.pct(r.value(window, 1), 1)).font(.caption2.monospaced()).foregroundStyle(Color.pnl(r.value(window, 1)))
                        }
                    }
                    .contextMenu {
                        Button(L("Copy address")) { UIPasteboard.general.string = r.address }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .themedBackground()
        .searchable(text: $search, prompt: L("Address or name"))
        .navigationTitle(L("Leaderboard"))
        .refreshable { await load() }
        .task { if rows.isEmpty { await load() } }
    }

    private func key(_ r: LeaderboardRow) -> Double {
        metric == 3 ? r.accountValue : r.value(window, metric)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            rows = try await model.loadLeaderboard()
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

/// Points (userPoints, authenticated with the trading key), as app.hyperliquid.xyz/points.
struct PointsView: View {
    @Environment(AppModel.self) private var model
    @State private var info: PointsInfo?
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        List {
            if loading { ProgressView() }
            if let error { Text(error).foregroundStyle(Color.hlRed).font(.caption) }
            if let info {
                Section {
                    LabeledContent(L("Total points"), value: Fmt.num(info.total, 0))
                    if let r = info.rank { LabeledContent(L("Rank"), value: "#\(r)") }
                    if let p = info.percentile { LabeledContent(L("Top"), value: Fmt.pct(p, 2, signed: false)) }
                }
                Section(L("Weekly distributions")) {
                    if info.weeks.isEmpty { Text(L("No points yet")).foregroundStyle(Color.hlMuted) }
                    ForEach(info.weeks) { w in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(w.start.prefix(10)) + " – " + String(w.end.prefix(10))).font(.caption)
                                if w.referredVlm > 0 {
                                    Text(L("Referred volume {0}", Fmt.compactUsd(w.referredVlm))).font(.caption2).foregroundStyle(Color.hlMuted)
                                }
                            }
                            Spacer()
                            Text(Fmt.num(w.points, 2)).font(.system(size: 13, weight: .semibold, design: .monospaced))
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .themedBackground()
        .navigationTitle(L("Points"))
        .refreshable { await load() }
        .task { if info == nil { await load() } }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            info = try await model.loadPoints()
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

/// Referrals (as app.hyperliquid.xyz/referrals): your code, referees, rewards; enter a referrer's code.
struct ReferralsView: View {
    @Environment(AppModel.self) private var model
    @State private var info: ReferralInfo?
    @State private var newCode = ""
    @State private var busy = false
    @State private var loading = false

    var body: some View {
        Form {
            if loading && info == nil { ProgressView() }
            if let info {
                Section(L("Your referral code")) {
                    switch info.stage {
                    case "ready":
                        if let code = info.code {
                            LabeledContent(L("Code"), value: code)
                            let link = "https://app.hyperliquid.xyz/join/\(code)"
                            ShareLink(item: link) { Label(L("Share link"), systemImage: "square.and.arrow.up") }
                            Button { UIPasteboard.general.string = link; model.show(.success, L("Link copied")) } label: {
                                Label(L("Copy link"), systemImage: "doc.on.doc")
                            }
                        }
                    case "needToTrade":
                        Text(L("Trade at least {0} in volume to create a referral code (now {1}).",
                               Fmt.compactUsd(info.requiredVlm), Fmt.compactUsd(info.cumVlm)))
                            .font(.caption)
                    default:
                        TextField(L("New code"), text: $newCode)
                            .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        PrimaryButton(title: L("Create code"), busy: busy, disabled: newCode.isEmpty || !model.canTrade) {
                            run { try await model.registerReferrer(code: newCode); return L("Referral code created") }
                        }
                        .listRowBackground(Color.clear)
                    }
                }
                Section(L("Rewards")) {
                    LabeledContent(L("Unclaimed"), value: Fmt.usd(info.unclaimedRewards, 4))
                    LabeledContent(L("Claimed"), value: Fmt.usd(info.claimedRewards, 4))
                    if info.unclaimedRewards > 0 {
                        PrimaryButton(title: L("Claim rewards"), busy: busy, disabled: !model.canTrade) {
                            run { try await model.claimReferralRewards(); return L("Rewards claimed") }
                        }
                        .listRowBackground(Color.clear)
                    }
                }
                if !info.referees.isEmpty {
                    Section(L("Referred users ({0})", info.referees.count)) {
                        ForEach(info.referees) { r in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(Address.short(r.user)).font(.caption.monospaced())
                                    Text(Fmt.dateTime(r.joined)).font(.caption2).foregroundStyle(Color.hlMuted)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(Fmt.compactUsd(r.cumVlm)).font(.caption.monospaced())
                                    Text(Fmt.usd(r.rewards, 2)).font(.caption2).foregroundStyle(Color.hlGreen)
                                }
                            }
                        }
                    }
                }
            }
            ReferralSection()
        }
        .scrollContentBackground(.hidden)
        .themedBackground()
        .navigationTitle(L("Referrals"))
        .refreshable { await load() }
        .task { if info == nil { await load() } }
    }

    private func load() async {
        loading = true
        info = await model.loadReferral()
        loading = false
    }

    private func run(_ op: @escaping () async throws -> String) {
        busy = true
        Task {
            do {
                model.show(.success, try await op())
                await load()
            } catch { model.show(.error, error.localizedDescription) }
            busy = false
        }
    }
}

/// HIP-3 risk notice and market description on the trade screen.
struct Hip3Banner: View {
    @Environment(AppModel.self) private var model
    let market: Market
    @State private var expanded = false

    var body: some View {
        let dex = model.perpDexs.first { $0.name == market.dex }?.fullName ?? market.dex
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(L("HIP-3 · deployed by {0}", dex)).font(.caption.bold())
                    if market.onlyIsolated { Badge(text: L("Isolated only"), color: .hlMuted) }
                    if market.growthMode { Badge(text: L("Fees −90%"), color: .hlGreen) }
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2)
                }
            }
            .buttonStyle(.plain)
            if expanded {
                Text(L("{0} is a perp market deployed independently by {1}. Beware of low liquidity, high volatility and increased liquidation risk.", market.name, dex))
                    .font(.caption2).foregroundStyle(Color.hlMuted)
                if market.onlyIsolated {
                    Text(L("Isolated margin only: margin cannot be removed without closing the position."))
                        .font(.caption2).foregroundStyle(Color.hlMuted)
                }
                if let d = model.annotations[market.id], !d.isEmpty {
                    Text(d).font(.caption2)
                }
            }
        }
        .padding(8)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .task(id: market.id) { await model.loadAnnotation(market.id) }
    }
}
