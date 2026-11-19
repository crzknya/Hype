import SwiftUI
import HyperCore

enum TransferKind: String, Identifiable {
    case classTransfer, withdraw, send, deposit
    var id: String { rawValue }
}

struct TransferSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let kind: TransferKind
    @State private var amountText = ""
    @State private var fromAcc = "spot"
    @State private var toAcc = ""
    @State private var destination = ""
    @State private var tokenIndex = -1    // -1 = USDC (perp balance), otherwise spot token index
    @State private var fromSpot = false
    @State private var busy = false
    @State private var arbBalance: Double?
    @State private var depositHash: String?

    var body: some View {
        NavigationStack {
            Form {
                switch kind {
                case .classTransfer: classTransfer
                case .withdraw: withdraw
                case .send: send
                case .deposit: deposit
                }
                if kind != .deposit && !(model.account?.kind.canTransfer ?? false) {
                    Section {
                        Label(L("This operation is signed by the main wallet. An API wallet can only trade. Add an account with a private key or do it on app.hyperliquid.xyz."),
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Close")) { dismiss() } } }
            .keyboardDoneToolbar()
        }
    }

    private var title: String {
        switch kind {
        case .classTransfer: return L("Transfer Perp ⇄ Spot")
        case .withdraw: return L("Withdraw to Arbitrum")
        case .send: return L("Send")
        case .deposit: return L("Deposit")
        }
    }

    @ViewBuilder private var classTransfer: some View {
        Section {
            Picker(L("From"), selection: $fromAcc) {
                ForEach(accountsList, id: \.self) { Text(accountTitle($0)).tag($0) }
            }
            Picker(L("To"), selection: $toAcc) {
                ForEach(accountsList, id: \.self) { Text(accountTitle($0)).tag($0) }
            }
            NumField(title: transferToken?.name ?? "USDC", text: $amountText) {
                Button("MAX") { amountText = Fmt.input(maxClass, 2) }.font(.caption.bold())
            }
            LabeledContent(L("Available"), value: Fmt.num(maxClass, 2))
        } footer: {
            Text(L("HIP-3 dexes (stocks, indices) have separate margin. Move collateral to the dex before trading its markets, unless unified margin is enabled on app.hyperliquid.xyz."))
        }
        Section {
            submitButton(L("Transfer funds")) {
                guard let a = Fmt.parse(amountText), a > 0 else { throw HLError(L("Enter an amount")) }
                guard fromAcc != toAcc else { throw HLError(L("Choose different accounts")) }
                let pair = Set([fromAcc, toAcc])
                if pair == Set(["", "spot"]) {
                    try await model.usdClassTransfer(amount: a, toPerp: toAcc == "")
                } else {
                    guard let t = transferToken else { throw HLError(L("Token not found")) }
                    try await model.sendAsset(from: fromAcc, to: toAcc, token: t, amount: a)
                }
                return L("Transferred {0}", Fmt.num(a, 2) + " " + (transferToken?.name ?? "USDC"))
            }
        }
    }

    /// "" = main perps, "spot", or a HIP-3 dex name.
    private var accountsList: [String] { ["", "spot"] + model.perpDexs.map(\.name) }

    private func accountTitle(_ a: String) -> String {
        switch a {
        case "": return L("Perps")
        case "spot": return L("Spot")
        default: return "HIP-3 · \(a)"
        }
    }

    /// Collateral token of the HIP-3 dex involved in the transfer (USDC otherwise).
    private var transferToken: SpotToken? {
        let dex = [fromAcc, toAcc].first { $0 != "" && $0 != "spot" }
        return model.collateral(of: dex ?? "")
    }

    private var maxClass: Double {
        switch fromAcc {
        case "": return model.summary.withdrawable
        case "spot": return model.spotBalances.first { $0.coin == (transferToken?.name ?? "USDC") }?.available ?? 0
        default: return model.dexSummaries[fromAcc]?.withdrawable ?? 0
        }
    }

    @ViewBuilder private var withdraw: some View {
        Section {
            TextField(L("Recipient address (0x…)"), text: $destination)
                .font(.system(.body, design: .monospaced)).autocorrectionDisabled().textInputAutocapitalization(.never)
            Button(L("My address")) { destination = model.account?.address ?? "" }.font(.caption)
            NumField(title: "USDC", text: $amountText) {
                Button("MAX") { amountText = Fmt.input(model.summary.withdrawable, 2) }.font(.caption.bold())
            }
            LabeledContent(L("Available"), value: Fmt.usd(model.summary.withdrawable))
        } footer: {
            Text(L("Withdraws USDC to Arbitrum. Hyperliquid network fee is $1. Usually takes a few minutes."))
        }
        Section {
            submitButton(L("Withdraw")) {
                guard Address.isValid(destination) else { throw HLError(L("Invalid address")) }
                guard let a = Fmt.parse(amountText), a > 1 else { throw HLError(L("Amount must be greater than $1")) }
                try await model.withdraw(amount: a, destination: destination)
                return L("Withdrawal of {0} sent", Fmt.usd(a))
            }
        }
    }

    @ViewBuilder private var send: some View {
        Section {
            Picker(L("Asset"), selection: $tokenIndex) {
                Text(L("USDC (perp balance)")).tag(-1)
                ForEach(model.spotBalances) { b in Text(L("{0} (spot)", b.coin)).tag(b.token) }
            }
            TextField(L("Recipient address (0x…)"), text: $destination)
                .font(.system(.body, design: .monospaced)).autocorrectionDisabled().textInputAutocapitalization(.never)
            NumField(title: L("Amount"), text: $amountText) {
                Button("MAX") { amountText = Fmt.input(maxSend, 6) }.font(.caption.bold())
            }
            LabeledContent(L("Available"), value: Fmt.num(maxSend, 4))
        } footer: {
            Text(L("Instant transfer inside Hyperliquid with no fee. Double-check the address: transfers are irreversible."))
        }
        Section {
            submitButton(L("Send")) {
                guard Address.isValid(destination) else { throw HLError(L("Invalid address")) }
                guard let a = Fmt.parse(amountText), a > 0 else { throw HLError(L("Enter an amount")) }
                if tokenIndex == -1 {
                    try await model.sendUsd(amount: a, destination: destination)
                } else {
                    guard let t = model.spotTokens[tokenIndex] else { throw HLError(L("Token not found")) }
                    try await model.sendSpot(token: t, amount: a, destination: destination)
                }
                return L("Sent")
            }
        }
    }

    private var maxSend: Double {
        tokenIndex == -1 ? model.summary.withdrawable : (model.spotBalances.first { $0.token == tokenIndex }?.available ?? 0)
    }

    @ViewBuilder private var deposit: some View {
        if model.account?.kind == .wallet && model.network.isMainnet {
            Section {
                LabeledContent(L("From"), value: "\(model.account?.walletApp.flatMap(WalletApp.init(rawValue:))?.title ?? L("Wallet")) · Arbitrum")
                NumField(title: "USDC", text: $amountText) {
                    if let b = arbBalance {
                        Button("MAX") { amountText = Fmt.input(floor(b * 100) / 100, 2) }.font(.caption.bold())
                    }
                }
                LabeledContent(L("USDC on Arbitrum")) {
                    if let b = arbBalance { Text(Fmt.num(b, 2)) } else { ProgressView().controlSize(.small) }
                }
                if let a = Fmt.parse(amountText), a > 0, a < HLBridge.minDeposit {
                    Text(L("Minimum deposit is 5 USDC")).font(.caption).foregroundStyle(Color.hlRed)
                }
                if let hash = depositHash {
                    Link(destination: URL(string: "https://arbiscan.io/tx/\(hash)")!) {
                        Label(L("Transaction sent: {0}", Address.short(hash)), systemImage: "checkmark.seal")
                    }
                }
            } footer: {
                Text(L("Sends USDC on Arbitrum from your wallet to the Hyperliquid bridge; confirm it in the wallet. Funds arrive in about a minute. You need a little ETH on Arbitrum for gas. Deposits below 5 USDC are lost."))
            }
            .task { arbBalance = await model.arbitrumUSDCBalance() }
            Section {
                PrimaryButton(title: L("Deposit"), busy: busy,
                              disabled: (Fmt.parse(amountText) ?? 0) < HLBridge.minDeposit) {
                    hideKeyboard()
                    guard let a = Fmt.parse(amountText) else { return }
                    busy = true
                    Task {
                        do {
                            depositHash = try await model.deposit(amount: a)
                            model.show(.success, L("Deposit sent. It will be credited in about a minute."))
                            Haptics.success(enabled: model.haptics)
                            amountText = ""
                        } catch {
                            model.show(.error, error.localizedDescription)
                            Haptics.error(enabled: model.haptics)
                        }
                        busy = false
                    }
                }
                .listRowBackground(Color.clear)
            }
        } else {
            Section {
                Text(L("To deposit from the app, connect a wallet in Settings (Connect wallet). Otherwise deposit on app.hyperliquid.xyz. Note: sending USDC to your own address on Arbitrum does not deposit it to Hyperliquid."))
                    .font(.subheadline)
                if let a = model.account {
                    LabeledContent(L("Your address")) {
                        Text(Address.short(a.address)).font(.system(.body, design: .monospaced))
                    }
                    Button {
                        UIPasteboard.general.string = Address.checksum(a.address)
                        model.show(.success, L("Address copied"))
                    } label: { Label(L("Copy address"), systemImage: "doc.on.doc") }
                }
                Link(destination: URL(string: "https://app.hyperliquid.xyz/trade")!) {
                    Label(L("Open app.hyperliquid.xyz"), systemImage: "safari")
                }
            } footer: {
                Text(L("Minimum bridge deposit is 5 USDC. Deposits below the minimum are lost."))
            }
        }
    }

    private func submitButton(_ title: String, _ op: @escaping () async throws -> String) -> some View {
        PrimaryButton(title: title, busy: busy, disabled: !(model.account?.kind.canTransfer ?? false)) {
            hideKeyboard()
            busy = true
            Task {
                do {
                    let msg = try await op()
                    model.show(.success, msg)
                    Haptics.success(enabled: model.haptics)
                    dismiss()
                } catch {
                    model.show(.error, error.localizedDescription)
                    Haptics.error(enabled: model.haptics)
                }
                busy = false
            }
        }
        .listRowBackground(Color.clear)
    }
}
