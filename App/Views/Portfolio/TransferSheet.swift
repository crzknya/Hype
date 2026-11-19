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
    @State private var toPerp = true
    @State private var destination = ""
    @State private var tokenIndex = -1    // -1 = USDC (perp balance), otherwise spot token index
    @State private var fromSpot = false
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                switch kind {
                case .classTransfer: classTransfer
                case .withdraw: withdraw
                case .send: send
                case .deposit: deposit
                }
                if kind != .deposit && model.account?.kind != .privateKey {
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
            Picker(L("Direction"), selection: $toPerp) {
                Text(L("Spot → Perp")).tag(true)
                Text(L("Perp → Spot")).tag(false)
            }
            .pickerStyle(.segmented)
            NumField(title: "USDC", text: $amountText) {
                Button("MAX") { amountText = Fmt.input(maxClass, 2) }.font(.caption.bold())
            }
            LabeledContent(L("Available"), value: Fmt.usd(maxClass))
        }
        Section {
            submitButton(L("Transfer funds")) {
                guard let a = Fmt.parse(amountText), a > 0 else { throw HLError(L("Enter an amount")) }
                try await model.usdClassTransfer(amount: a, toPerp: toPerp)
                return L("Transferred {0}", Fmt.usd(a))
            }
        }
    }

    private var maxClass: Double { toPerp ? model.usdcSpot : model.summary.withdrawable }

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
        Section {
            Text(L("Deposits are made by sending USDC on Arbitrum through the Hyperliquid bridge. The easiest way is app.hyperliquid.xyz with a connected wallet, or sending USDC (Arbitrum) to your Hyperliquid address from an exchange that supports it."))
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

    private func submitButton(_ title: String, _ op: @escaping () async throws -> String) -> some View {
        PrimaryButton(title: title, busy: busy, disabled: model.account?.kind != .privateKey) {
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
