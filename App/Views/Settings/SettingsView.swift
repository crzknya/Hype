import SwiftUI
import HyperCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var adding = false
    @State private var creatingAgent = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    ForEach(model.accounts) { a in
                        Button { model.activeAccountId = a.id } label: {
                            HStack {
                                Image(systemName: a.id == model.activeAccountId ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(a.id == model.activeAccountId ? Color.hlAccent : Color.hlMuted)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(a.name).foregroundStyle(.primary)
                                    Text("\(Address.short(a.address)) · \(a.kind.title)\(a.vaultAddress.map { " · субакк. \(Address.short($0))" } ?? "")")
                                        .font(.caption).foregroundStyle(Color.hlMuted)
                                }
                            }
                        }
                        .swipeActions {
                            Button("Удалить", role: .destructive) { model.removeAccount(a) }
                        }
                        .contextMenu {
                            Button { UIPasteboard.general.string = Address.checksum(a.address) } label: { Label("Скопировать адрес", systemImage: "doc.on.doc") }
                            Button(role: .destructive) { model.removeAccount(a) } label: { Label("Удалить", systemImage: "trash") }
                        }
                    }
                    Button { adding = true } label: { Label("Добавить аккаунт", systemImage: "plus.circle") }
                    if model.account?.kind == .privateKey {
                        Button { creatingAgent = true } label: { Label("Создать API-кошелёк из этого аккаунта", systemImage: "key.viewfinder") }
                    }
                } header: {
                    Text("Аккаунты")
                } footer: {
                    Text("Рекомендуется API-кошелёк: он может только торговать и не может выводить средства. Ключи хранятся в Keychain только на этом устройстве.")
                }

                Section("Сеть") {
                    Picker("Сеть", selection: $model.network) {
                        ForEach(HLNetwork.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Text("WebSocket")
                        Spacer()
                        ConnectionDot(connected: model.wsConnected)
                        Text(model.wsConnected ? "подключён" : "нет связи").foregroundStyle(Color.hlMuted)
                    }
                }

                Section {
                    VStack(alignment: .leading) {
                        Text("Проскальзывание рыночных ордеров: \(Fmt.pct(model.slippage, 1, signed: false))")
                        Slider(value: $model.slippage, in: 0.001...0.1, step: 0.001)
                    }
                    Toggle("Подтверждать ордера", isOn: $model.confirmOrders)
                    Toggle("Вибрация", isOn: $model.haptics)
                } header: {
                    Text("Торговля")
                } footer: {
                    Text("Рыночный ордер на Hyperliquid — это IOC-лимит по цене лучшей заявки ± проскальзывание.")
                }

                Section("Безопасность") {
                    Toggle("Блокировка \(Biometrics.name)", isOn: Binding(
                        get: { model.biometricLock },
                        set: { v in
                            Task {
                                if await Biometrics.authenticate(reason: v ? "Включить блокировку" : "Отключить блокировку") {
                                    model.biometricLock = v
                                }
                            }
                        }))
                    .disabled(!Biometrics.available)
                }

                Section("О приложении") {
                    LabeledContent("Версия", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                    Link("Hyperliquid API Docs", destination: URL(string: "https://hyperliquid.gitbook.io/hyperliquid-docs")!)
                    Link("Создать API-кошелёк (app.hyperliquid.xyz/API)", destination: URL(string: "https://app.hyperliquid.xyz/API")!)
                    Text("Неофициальный клиент. Торговля с плечом сопряжена с высоким риском.").font(.caption).foregroundStyle(Color.hlMuted)
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $adding) { AddAccountView() }
            .sheet(isPresented: $creatingAgent) { CreateAgentView() }
        }
    }
}

struct AddAccountView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var kind: Account.Kind = .agent
    @State private var name = ""
    @State private var address = ""
    @State private var key = ""
    @State private var vault = ""
    @State private var checking = false
    @State private var warning: String?
    @State private var forceSave = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Тип", selection: $kind) {
                        ForEach(Account.Kind.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } footer: { Text(kindHelp) }

                Section {
                    TextField("Название (например, Основной)", text: $name)
                    if kind != .privateKey {
                        HStack {
                            TextField("Адрес основного кошелька 0x…", text: $address)
                                .font(.system(.body, design: .monospaced))
                                .autocorrectionDisabled().textInputAutocapitalization(.never)
                            pasteButton { address = $0 }
                        }
                    }
                    if kind != .watch {
                        HStack {
                            SecureField(kind == .agent ? "Приватный ключ API-кошелька" : "Приватный ключ кошелька", text: $key)
                                .font(.system(.body, design: .monospaced))
                                .autocorrectionDisabled().textInputAutocapitalization(.never)
                            pasteButton { key = $0 }
                        }
                        if let derived = derivedAddress {
                            LabeledContent(kind == .agent ? "Адрес API-кошелька" : "Адрес", value: Address.short(derived))
                                .font(.caption)
                        }
                    }
                }

                if kind != .watch {
                    Section {
                        TextField("Адрес субаккаунта/vault (необязательно)", text: $vault)
                            .font(.system(.body, design: .monospaced))
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                    } footer: {
                        Text("Если указан — ордера будут отправляться от имени этого субаккаунта или vault (вы должны быть его владельцем/лидером).")
                    }
                }

                if let warning {
                    Section { Text(warning).font(.caption).foregroundStyle(.orange) }
                }

                Section {
                    PrimaryButton(title: "Сохранить", busy: checking) { save() }
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Новый аккаунт")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
        }
    }

    private var kindHelp: String {
        switch kind {
        case .agent:
            return "Создайте API-кошелёк на app.hyperliquid.xyz → «Ещё» → API, нажмите Authorize и скопируйте приватный ключ. Укажите здесь адрес вашего основного кошелька и ключ API-кошелька. API-кошелёк может торговать, но не может выводить средства."
        case .privateKey:
            return "Полный доступ, включая выводы и переводы. Используйте только если понимаете риски: ключ хранится в Keychain на устройстве."
        case .watch:
            return "Просмотр позиций, ордеров и истории любого адреса без возможности торговать."
        }
    }

    private var derivedAddress: String? {
        guard !key.isEmpty else { return nil }
        return try? HLWallet(privateKeyHex: key).address
    }

    private func pasteButton(_ set: @escaping (String) -> Void) -> some View {
        Button {
            if let s = UIPasteboard.general.string { set(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
        } label: { Image(systemName: "doc.on.clipboard") }
        .buttonStyle(.borderless)
    }

    private func save() {
        warning = nil
        let addr = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let v = vault.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !v.isEmpty && !Address.isValid(v) { warning = "Неверный адрес субаккаунта"; return }
        switch kind {
        case .watch:
            guard Address.isValid(addr) else { warning = "Неверный адрес"; return }
            finish(Account(name: name.isEmpty ? "Наблюдение" : name, address: addr, kind: .watch), key: nil)
        case .privateKey:
            guard let w = try? HLWallet(privateKeyHex: k) else { warning = "Неверный приватный ключ"; return }
            finish(Account(name: name.isEmpty ? "Кошелёк" : name, address: w.address, kind: .privateKey,
                           signerAddress: w.address, vaultAddress: v.isEmpty ? nil : v), key: k)
        case .agent:
            guard Address.isValid(addr) else { warning = "Неверный адрес основного кошелька"; return }
            guard let w = try? HLWallet(privateKeyHex: k) else { warning = "Неверный приватный ключ API-кошелька"; return }
            if w.address == addr {
                warning = "Это ключ самого основного кошелька. Выберите тип «Приватный ключ» или используйте ключ API-кошелька."
                return
            }
            checking = true
            Task {
                let approved = await model.isAgentApproved(user: addr, agent: w.address)
                checking = false
                let acc = Account(name: name.isEmpty ? "API" : name, address: addr, kind: .agent,
                                  signerAddress: w.address, vaultAddress: v.isEmpty ? nil : v)
                if approved == false && !forceSave {
                    warning = "API-кошелёк \(Address.short(w.address)) не найден среди одобренных для \(Address.short(addr)) в сети \(model.network.title). Проверьте адрес и сеть. Нажмите «Сохранить» ещё раз, чтобы сохранить всё равно."
                    forceSave = true
                    return
                }
                finish(acc, key: k)
            }
        }
    }

    private func finish(_ a: Account, key: String?) {
        model.addAccount(a, key: key)
        model.show(.success, "Аккаунт «\(a.name)» добавлен")
        dismiss()
    }
}

struct CreateAgentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = "hype-ios"
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Имя API-кошелька", text: $name)
                } footer: {
                    Text("Будет создан новый ключ, одобрен подписью основного кошелька и сохранён как отдельный аккаунт «API». После этого основной ключ можно удалить из приложения — для торговли он не нужен.")
                }
                PrimaryButton(title: "Создать и одобрить", busy: busy) {
                    guard let main = model.account else { return }
                    busy = true
                    Task {
                        do {
                            let (addr, key) = try await model.createAgent(name: name)
                            model.addAccount(Account(name: "\(main.name) API", address: main.address, kind: .agent,
                                                     signerAddress: addr, vaultAddress: main.vaultAddress), key: key)
                            model.show(.success, "API-кошелёк \(Address.short(addr)) создан")
                            dismiss()
                        } catch {
                            model.show(.error, error.localizedDescription)
                        }
                        busy = false
                    }
                }
                .listRowBackground(Color.clear)
            }
            .navigationTitle("Новый API-кошелёк")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
        }
    }
}
