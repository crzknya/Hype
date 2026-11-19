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
                        Label("Эта операция подписывается основным кошельком. API-кошелёк может только торговать. Добавьте аккаунт с приватным ключом или выполните операцию на app.hyperliquid.xyz.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
            .keyboardDoneToolbar()
        }
    }

    private var title: String {
        switch kind {
        case .classTransfer: return "Перевод Перп ⇄ Спот"
        case .withdraw: return "Вывод в Arbitrum"
        case .send: return "Отправить"
        case .deposit: return "Депозит"
        }
    }

    @ViewBuilder private var classTransfer: some View {
        Section {
            Picker("Направление", selection: $toPerp) {
                Text("Спот → Перп").tag(true)
                Text("Перп → Спот").tag(false)
            }
            .pickerStyle(.segmented)
            NumField(title: "USDC", text: $amountText) {
                Button("MAX") { amountText = Fmt.input(maxClass, 2) }.font(.caption.bold())
            }
            LabeledContent("Доступно", value: Fmt.usd(maxClass))
        }
        Section {
            submitButton("Перевести") {
                guard let a = Fmt.parse(amountText), a > 0 else { throw HLError("Укажите сумму") }
                try await model.usdClassTransfer(amount: a, toPerp: toPerp)
                return "Переведено \(Fmt.usd(a))"
            }
        }
    }

    private var maxClass: Double { toPerp ? model.usdcSpot : model.summary.withdrawable }

    @ViewBuilder private var withdraw: some View {
        Section {
            TextField("Адрес получателя (0x…)", text: $destination)
                .font(.system(.body, design: .monospaced)).autocorrectionDisabled().textInputAutocapitalization(.never)
            Button("Мой адрес") { destination = model.account?.address ?? "" }.font(.caption)
            NumField(title: "USDC", text: $amountText) {
                Button("MAX") { amountText = Fmt.input(model.summary.withdrawable, 2) }.font(.caption.bold())
            }
            LabeledContent("Доступно", value: Fmt.usd(model.summary.withdrawable))
        } footer: {
            Text("Вывод USDC в сеть Arbitrum. Комиссия сети Hyperliquid — $1. Обычно занимает несколько минут.")
        }
        Section {
            submitButton("Вывести") {
                guard Address.isValid(destination) else { throw HLError("Неверный адрес") }
                guard let a = Fmt.parse(amountText), a > 1 else { throw HLError("Сумма должна быть больше $1") }
                try await model.withdraw(amount: a, destination: destination)
                return "Вывод \(Fmt.usd(a)) отправлен"
            }
        }
    }

    @ViewBuilder private var send: some View {
        Section {
            Picker("Актив", selection: $tokenIndex) {
                Text("USDC (перп-баланс)").tag(-1)
                ForEach(model.spotBalances) { b in Text("\(b.coin) (спот)").tag(b.token) }
            }
            TextField("Адрес получателя (0x…)", text: $destination)
                .font(.system(.body, design: .monospaced)).autocorrectionDisabled().textInputAutocapitalization(.never)
            NumField(title: "Сумма", text: $amountText) {
                Button("MAX") { amountText = Fmt.input(maxSend, 6) }.font(.caption.bold())
            }
            LabeledContent("Доступно", value: Fmt.num(maxSend, 4))
        } footer: {
            Text("Мгновенный перевод внутри Hyperliquid без комиссии. Проверьте адрес — перевод необратим.")
        }
        Section {
            submitButton("Отправить") {
                guard Address.isValid(destination) else { throw HLError("Неверный адрес") }
                guard let a = Fmt.parse(amountText), a > 0 else { throw HLError("Укажите сумму") }
                if tokenIndex == -1 {
                    try await model.sendUsd(amount: a, destination: destination)
                } else {
                    guard let t = model.spotTokens[tokenIndex] else { throw HLError("Токен не найден") }
                    try await model.sendSpot(token: t, amount: a, destination: destination)
                }
                return "Отправлено"
            }
        }
    }

    private var maxSend: Double {
        tokenIndex == -1 ? model.summary.withdrawable : (model.spotBalances.first { $0.token == tokenIndex }?.available ?? 0)
    }

    @ViewBuilder private var deposit: some View {
        Section {
            Text("Пополнение выполняется переводом USDC в сети Arbitrum через мост Hyperliquid. Удобнее всего сделать это на app.hyperliquid.xyz, подключив кошелёк, или отправив USDC (Arbitrum) на ваш адрес в Hyperliquid с биржи, которая поддерживает такой вывод.")
                .font(.subheadline)
            if let a = model.account {
                LabeledContent("Ваш адрес") {
                    Text(Address.short(a.address)).font(.system(.body, design: .monospaced))
                }
                Button {
                    UIPasteboard.general.string = Address.checksum(a.address)
                    model.show(.success, "Адрес скопирован")
                } label: { Label("Скопировать адрес", systemImage: "doc.on.doc") }
            }
            Link(destination: URL(string: "https://app.hyperliquid.xyz/trade")!) {
                Label("Открыть app.hyperliquid.xyz", systemImage: "safari")
            }
        } footer: {
            Text("Минимальный депозит через мост — 5 USDC. Депозит меньше минимума будет потерян.")
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
