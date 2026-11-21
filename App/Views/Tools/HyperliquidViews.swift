import SwiftUI
import HyperCore

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
