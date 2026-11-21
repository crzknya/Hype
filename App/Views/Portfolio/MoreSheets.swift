import SwiftUI
import HyperCore

/// "Swap Stablecoins" (app.hyperliquid.xyz → Portfolio): an IOC spot order at most 1% from the book.
struct SwapStablecoinsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var from = "USDC"
    @State private var to = "USDT0"
    @State private var amountText = ""
    @State private var busy = false

    var body: some View {
        let available = model.spotAvailable(from)
        let amount = Fmt.parse(amountText) ?? 0
        let pair = model.swapMarket(from: from, to: to)
        let px = pair.map { model.mid($0.market.id) } ?? 0
        let receive = pair.map { $0.isBuy ? (px > 0 ? amount / px : 0) : amount * px } ?? 0
        let fee = pair.map { model.fees(for: $0.market).taker } ?? 0
        NavigationStack {
            Form {
                Section {
                    Picker(L("Sell"), selection: $from) {
                        ForEach(AppModel.swapStables, id: \.self) { Text(label($0)).tag($0) }
                    }
                    NumField(title: label(from), text: $amountText) {
                        Button("MAX") { amountText = Fmt.input(floor(available * 100) / 100, 2) }.font(.caption.bold())
                    }
                    LabeledContent(L("Available"), value: Fmt.num(available, 2))
                    Picker(L("Buy"), selection: $to) {
                        ForEach(AppModel.swapStables.filter { $0 != from && model.swapMarket(from: from, to: $0) != nil }, id: \.self) {
                            Text(label($0)).tag($0)
                        }
                    }
                }
                Section {
                    LabeledContent(L("You receive ≈"), value: "\(Fmt.num(receive * (1 - fee), 2)) \(label(to))")
                    LabeledContent(L("Estimated fee"), value: "\(Fmt.num(receive * fee, 4)) \(label(to))")
                } footer: {
                    Text(L("Execution is not guaranteed due to potential slippage in the order book. The swap is partially filled if slippage is above 1%."))
                }
                Section {
                    PrimaryButton(title: L("Swap"), busy: busy,
                                  disabled: pair == nil || amount <= 0 || amount > available + 1e-9 || !model.canTrade) {
                        busy = true
                        Task {
                            do {
                                let msg = try await model.swapStable(from: from, to: to, amount: amount)
                                model.show(.success, msg)
                                dismiss()
                            } catch { model.show(.error, error.localizedDescription) }
                            busy = false
                        }
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle(L("Swap stablecoins"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Close")) { dismiss() } } }
            .keyboardDoneToolbar()
            .onChange(of: from) { _, f in
                if to == f || model.swapMarket(from: f, to: to) == nil {
                    to = AppModel.swapStables.first { $0 != f && model.swapMarket(from: f, to: $0) != nil } ?? to
                }
            }
        }
    }

    private func label(_ token: String) -> String { token == "USDT0" ? "USDT" : token }
}

/// HyperCore spot ⇄ HyperEVM transfer (app.hyperliquid.xyz → "EVM ⇄ Core").
struct EvmCoreSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var toEvm = true
    @State private var tokenIndex = 0
    @State private var amountText = ""
    @State private var evmBalance: Double?
    @State private var busy = false

    private var tokens: [SpotToken] {
        let linked = model.spotTokens.values.filter(\.isEvmLinked)
        let held = Set(model.spotBalances.map(\.token))
        let common: Set<String> = ["USDC", "HYPE", "USDT0", "USDH", "UBTC", "UETH", "USOL"]
        return linked.filter { held.contains($0.index) || common.contains($0.name) }.sorted { $0.name < $1.name }
    }

    var body: some View {
        let token = model.spotTokens[tokenIndex]
        let coreAvail = token.map { model.spotAvailable($0.name) } ?? 0
        let available = toEvm ? coreAvail : (evmBalance ?? 0)
        NavigationStack {
            Form {
                Section {
                    Picker(L("Direction"), selection: $toEvm) {
                        Text(L("Core → EVM")).tag(true)
                        Text(L("EVM → Core")).tag(false)
                    }
                    .pickerStyle(.segmented)
                    Picker(L("Asset"), selection: $tokenIndex) {
                        ForEach(tokens) { Text($0.name).tag($0.index) }
                    }
                    NumField(title: token?.name ?? "", text: $amountText) {
                        Button("MAX") { amountText = Fmt.input(available, min(token?.szDecimals ?? 2, 6)) }.font(.caption.bold())
                    }
                    LabeledContent(L("HyperCore spot"), value: Fmt.num(coreAvail, 4))
                    LabeledContent(L("HyperEVM")) {
                        if let b = evmBalance { Text(Fmt.num(b, 4)) } else { Text("—") }
                    }
                } footer: {
                    Text(toEvm
                         ? L("Moves the token from your HyperCore spot balance to the same address on the HyperEVM. Signed by the main wallet; a small HYPE fee is charged to receive it on the EVM.")
                         : L("Sends the token on the HyperEVM (chain 999) to its system address, which credits your HyperCore spot balance. Confirm the transaction in your wallet; it needs a little HYPE for gas."))
                }
                Section {
                    PrimaryButton(title: L("Transfer"), busy: busy,
                                  disabled: token == nil || (Fmt.parse(amountText) ?? 0) <= 0 || (Fmt.parse(amountText) ?? 0) > available + 1e-9) {
                        guard let token, let a = Fmt.parse(amountText) else { return }
                        busy = true
                        Task {
                            do {
                                if toEvm {
                                    try await model.coreToEvm(token, amount: a)
                                    model.show(.success, L("Sent to the HyperEVM"))
                                } else {
                                    let hash = try await model.evmToCore(token, amount: a)
                                    model.show(.success, L("Transaction sent: {0}", Address.short(hash)))
                                }
                                dismiss()
                            } catch { model.show(.error, error.localizedDescription) }
                            busy = false
                        }
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle(L("EVM ⇄ Core"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Close")) { dismiss() } } }
            .keyboardDoneToolbar()
            .task(id: tokenIndex) {
                evmBalance = nil
                if let t = model.spotTokens[tokenIndex] { evmBalance = await model.evmBalance(t) }
            }
            .onAppear {
                if model.spotTokens[tokenIndex] == nil || !(model.spotTokens[tokenIndex]?.isEvmLinked ?? false) {
                    tokenIndex = tokens.first { $0.name == "USDC" }?.index ?? tokens.first?.index ?? 0
                }
            }
        }
    }
}

/// Sub-accounts of the master: create, rename, fund and trade as a sub-account.
struct SubAccountsView: View {
    @Environment(AppModel.self) private var model
    @State private var newName = ""
    @State private var busy = false
    @State private var renaming: SubAccount?
    @State private var renameText = ""
    @State private var transferFor: SubAccount?

    var body: some View {
        Form {
            Section {
                if model.subAccounts.isEmpty { Text(L("No sub-accounts yet")).foregroundStyle(Color.hlMuted) }
                ForEach(model.subAccounts) { sub in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(sub.name).font(.subheadline.bold())
                            if model.activeSubAccount == sub.address { Badge(text: L("Active"), color: .hlGreen) }
                            Spacer()
                            Text(Fmt.usd(value(sub))).font(.system(size: 13, design: .monospaced))
                        }
                        Text(Address.short(sub.address)).font(.caption2.monospaced()).foregroundStyle(Color.hlMuted)
                        HStack(spacing: 8) {
                            Button(model.activeSubAccount == sub.address ? L("Back to master") : L("Trade as")) {
                                model.activeSubAccount = model.activeSubAccount == sub.address ? nil : sub.address
                            }
                            Button(L("Transfer")) { transferFor = sub }
                            Button(L("Rename")) { renameText = sub.name; renaming = sub }
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                    }
                    .padding(.vertical, 4)
                }
            } footer: {
                Text(L("Sub-accounts have their own positions and balances and are traded with the master's key (as a vault address)."))
            }
            Section(L("Create sub-account")) {
                TextField(L("Name (up to 16 characters)"), text: $newName)
                PrimaryButton(title: L("Create"), busy: busy, disabled: newName.trimmingCharacters(in: .whitespaces).isEmpty || newName.count > 16 || !model.canTrade) {
                    busy = true
                    Task {
                        do {
                            let addr = try await model.createSubAccount(name: newName)
                            model.show(.success, L("Created sub-account {0}", Address.short(addr)))
                            newName = ""
                        } catch { model.show(.error, error.localizedDescription) }
                        busy = false
                    }
                }
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle(L("Sub-accounts"))
        .refreshable { await model.refreshHistory() }
        .alert(L("Rename sub-account"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(L("Name"), text: $renameText)
            Button(L("Cancel"), role: .cancel) {}
            Button(L("Save")) {
                guard let sub = renaming else { return }
                model.perform {
                    try await model.renameSubAccount(sub, name: renameText)
                    return L("Renamed")
                }
            }
        }
        .sheet(item: $transferFor) { SubAccountTransferSheet(sub: $0) }
    }

    private func value(_ s: SubAccount) -> Double {
        s.perpsValue + s.balances.reduce(0) { $0 + $1.total * model.spotPrice($1.coin) }
    }
}

struct SubAccountTransferSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let sub: SubAccount
    @State private var toSub = true
    @State private var tokenIndex = -1   // -1 = perps USDC
    @State private var amountText = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("", selection: $toSub) {
                        Text(L("To sub-account")).tag(true)
                        Text(L("To master")).tag(false)
                    }
                    .pickerStyle(.segmented)
                    Picker(L("Asset"), selection: $tokenIndex) {
                        if !model.isUnified { Text(L("USDC (perps)")).tag(-1) }
                        ForEach(tokens) { Text(L("{0} (spot)", $0.name)).tag($0.index) }
                    }
                    NumField(title: L("Amount"), text: $amountText) {
                        Button("MAX") { amountText = Fmt.input(available, 2) }.font(.caption.bold())
                    }
                    LabeledContent(L("Available"), value: Fmt.num(available, 4))
                }
                Section {
                    PrimaryButton(title: L("Transfer"), busy: busy, disabled: (Fmt.parse(amountText) ?? 0) <= 0) {
                        guard let a = Fmt.parse(amountText) else { return }
                        busy = true
                        Task {
                            do {
                                try await model.transferSubAccount(sub, amount: a, toSub: toSub,
                                                                   token: tokenIndex < 0 ? nil : model.spotTokens[tokenIndex])
                                model.show(.success, L("Transferred {0}", Fmt.num(a, 4)))
                                dismiss()
                            } catch { model.show(.error, error.localizedDescription) }
                            busy = false
                        }
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle(sub.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Close")) { dismiss() } } }
            .keyboardDoneToolbar()
            .onAppear { if model.isUnified && tokenIndex < 0 { tokenIndex = 0 } }
        }
        .presentationDetents([.medium, .large])
    }

    private var tokens: [SpotToken] {
        let balances = toSub ? model.spotBalances : sub.balances
        return balances.compactMap { model.spotTokens[$0.token] }
    }

    private var available: Double {
        if tokenIndex < 0 { return toSub ? model.summary.withdrawable : sub.withdrawable }
        let balances = toSub ? model.spotBalances : sub.balances
        return max(0, balances.first { $0.token == tokenIndex }?.available ?? 0)
    }
}
