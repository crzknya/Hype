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
                                    Text("\(Address.short(a.address)) · \(a.kind.title)\(a.vaultAddress.map { L(" · sub {0}", Address.short($0)) } ?? "")")
                                        .font(.caption).foregroundStyle(Color.hlMuted)
                                }
                            }
                        }
                        .swipeActions {
                            Button(L("Delete"), role: .destructive) { model.removeAccount(a) }
                        }
                        .contextMenu {
                            Button { UIPasteboard.general.string = Address.checksum(a.address) } label: { Label(L("Copy address"), systemImage: "doc.on.doc") }
                            Button(role: .destructive) { model.removeAccount(a) } label: { Label(L("Delete"), systemImage: "trash") }
                        }
                    }
                    Button { adding = true } label: { Label(L("Add account"), systemImage: "plus.circle") }
                    if model.account?.kind == .privateKey {
                        Button { creatingAgent = true } label: { Label(L("Create an API wallet from this account"), systemImage: "key.viewfinder") }
                    }
                } header: {
                    Text(L("Accounts"))
                } footer: {
                    Text(L("An API wallet is recommended: it can trade but cannot withdraw funds. Keys are stored in the Keychain on this device only."))
                }

                if model.account != nil { ReferralSection() }

                Section(L("Language")) {
                    Picker(L("Language"), selection: $model.language) {
                        ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section(L("Network")) {
                    Picker(L("Network"), selection: $model.network) {
                        ForEach(HLNetwork.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Text("WebSocket")
                        Spacer()
                        ConnectionDot(connected: model.wsConnected)
                        Text(model.wsConnected ? L("connected") : L("offline")).foregroundStyle(Color.hlMuted)
                    }
                }

                Section {
                    VStack(alignment: .leading) {
                        Text(L("Market order slippage: {0}", Fmt.pct(model.slippage, 1, signed: false)))
                        Slider(value: $model.slippage, in: 0.001...0.1, step: 0.001)
                    }
                    Toggle(L("Confirm orders"), isOn: $model.confirmOrders)
                    Toggle(L("Haptics"), isOn: $model.haptics)
                } header: {
                    Text(L("Trade"))
                } footer: {
                    Text(L("A market order on Hyperliquid is an IOC limit at the best price ± slippage."))
                }

                Section(L("Security")) {
                    Toggle(L("{0} lock", Biometrics.name), isOn: Binding(
                        get: { model.biometricLock },
                        set: { v in
                            Task {
                                if await Biometrics.authenticate(reason: v ? L("Enable lock") : L("Disable lock")) {
                                    model.biometricLock = v
                                }
                            }
                        }))
                    .disabled(!Biometrics.available)
                }

                Section(L("About")) {
                    LabeledContent(L("Version"), value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                    Link("Hyperliquid API Docs", destination: URL(string: "https://hyperliquid.gitbook.io/hyperliquid-docs")!)
                    Link(L("Create an API wallet (app.hyperliquid.xyz/API)"), destination: URL(string: "https://app.hyperliquid.xyz/API")!)
                    Text(L("Unofficial client. Leveraged trading carries high risk.")).font(.caption).foregroundStyle(Color.hlMuted)
                }
            }
            .navigationTitle(L("Settings"))
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
                    Picker(L("Type"), selection: $kind) {
                        ForEach(Account.Kind.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } footer: { Text(kindHelp) }

                Section {
                    TextField(L("Name (e.g. Main)"), text: $name)
                    if kind != .privateKey {
                        HStack {
                            TextField(L("Main wallet address 0x…"), text: $address)
                                .font(.system(.body, design: .monospaced))
                                .autocorrectionDisabled().textInputAutocapitalization(.never)
                            pasteButton { address = $0 }
                        }
                    }
                    if kind != .watch {
                        HStack {
                            SecureField(kind == .agent ? L("API wallet private key") : L("Wallet private key"), text: $key)
                                .font(.system(.body, design: .monospaced))
                                .autocorrectionDisabled().textInputAutocapitalization(.never)
                            pasteButton { key = $0 }
                        }
                        if let derived = derivedAddress {
                            LabeledContent(kind == .agent ? L("API wallet address") : L("Address"), value: Address.short(derived))
                                .font(.caption)
                        }
                    }
                }

                if kind != .watch {
                    Section {
                        TextField(L("Sub-account/vault address (optional)"), text: $vault)
                            .font(.system(.body, design: .monospaced))
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                    } footer: {
                        Text(L("If set, orders are sent on behalf of this sub-account or vault (you must be its owner/leader)."))
                    }
                }

                if let warning {
                    Section { Text(warning).font(.caption).foregroundStyle(.orange) }
                }

                Section {
                    PrimaryButton(title: L("Save"), busy: checking) { save() }
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle(L("New account"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { dismiss() } } }
        }
    }

    private var kindHelp: String {
        switch kind {
        case .agent:
            return L("Create an API wallet at app.hyperliquid.xyz → More → API, tap Authorize and copy the private key. Enter your main wallet address and the API wallet key here. An API wallet can trade but cannot withdraw funds.")
        case .privateKey:
            return L("Full access including withdrawals and transfers. Use only if you understand the risks: the key is stored in the Keychain on this device.")
        case .watch:
            return L("View positions, orders and history of any address without trading.")
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
        if !v.isEmpty && !Address.isValid(v) { warning = L("Invalid sub-account address"); return }
        switch kind {
        case .watch:
            guard Address.isValid(addr) else { warning = L("Invalid address"); return }
            finish(Account(name: name.isEmpty ? L("Watch") : name, address: addr, kind: .watch), key: nil)
        case .privateKey:
            guard let w = try? HLWallet(privateKeyHex: k) else { warning = L("Invalid private key"); return }
            finish(Account(name: name.isEmpty ? L("Wallet") : name, address: w.address, kind: .privateKey,
                           signerAddress: w.address, vaultAddress: v.isEmpty ? nil : v), key: k)
        case .agent:
            guard Address.isValid(addr) else { warning = L("Invalid main wallet address"); return }
            guard let w = try? HLWallet(privateKeyHex: k) else { warning = L("Invalid API wallet private key"); return }
            if w.address == addr {
                warning = L("This is the main wallet key itself. Choose the “Private key” type or use an API wallet key.")
                return
            }
            checking = true
            Task {
                let approved = await model.isAgentApproved(user: addr, agent: w.address)
                checking = false
                let acc = Account(name: name.isEmpty ? "API" : name, address: addr, kind: .agent,
                                  signerAddress: w.address, vaultAddress: v.isEmpty ? nil : v)
                if approved == false && !forceSave {
                    warning = L("API wallet {0} is not approved for {1} on {2}. Check the address and network. Tap “Save” again to save anyway.", Address.short(w.address), Address.short(addr), model.network.title)
                    forceSave = true
                    return
                }
                finish(acc, key: k)
            }
        }
    }

    private func finish(_ a: Account, key: String?) {
        model.addAccount(a, key: key)
        model.show(.success, L("Account “{0}” added", a.name))
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
                    TextField(L("API wallet name"), text: $name)
                } footer: {
                    Text(L("A new key will be generated, approved with the main wallet signature and saved as a separate “API” account. After that you can remove the main key from the app: it is not needed for trading."))
                }
                PrimaryButton(title: L("Create and approve"), busy: busy) {
                    guard let main = model.account else { return }
                    busy = true
                    Task {
                        do {
                            let (addr, key) = try await model.createAgent(name: name)
                            model.addAccount(Account(name: "\(main.name) API", address: main.address, kind: .agent,
                                                     signerAddress: addr, vaultAddress: main.vaultAddress), key: key)
                            model.show(.success, L("API wallet {0} created", Address.short(addr)))
                            dismiss()
                        } catch {
                            model.show(.error, error.localizedDescription)
                        }
                        busy = false
                    }
                }
                .listRowBackground(Color.clear)
            }
            .navigationTitle(L("New API wallet"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { dismiss() } } }
        }
    }
}

struct ReferralSection: View {
    @Environment(AppModel.self) private var model
    @State private var code = ""
    @State private var busy = false
    @State private var referredBy: String?
    @State private var volume: Double?
    @State private var result: String?
    @State private var failed = false

    var body: some View {
        Section {
            if let referredBy {
                LabeledContent(L("Referred by"), value: referredBy)
            } else {
                HStack {
                    TextField(L("Referral code"), text: $code)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                    Button {
                        if let s = UIPasteboard.general.string { code = s.trimmingCharacters(in: .whitespacesAndNewlines) }
                    } label: { Image(systemName: "doc.on.clipboard") }
                    .buttonStyle(.borderless)
                }
                Button {
                    apply()
                } label: {
                    if busy { ProgressView() } else { Text(L("Apply code")) }
                }
                .disabled(busy || code.isEmpty || !model.canTrade)
            }
            if let volume {
                LabeledContent(L("Trading volume"), value: Fmt.usd(volume, 0))
            }
            if let result {
                Text(result).font(.caption).foregroundStyle(failed ? Color.hlRed : Color.hlGreen)
            }
        } header: {
            Text(L("Referral"))
        } footer: {
            Text(L("Sends the setReferrer action to the exchange and shows its reply. The exchange may reject codes after the account's volume threshold."))
        }
        .task(id: model.activeAccountId) { await load() }
    }

    private func load() async {
        result = nil
        guard let r = await model.fetchReferral() else { return }
        referredBy = r.referredBy
        volume = r.volume
    }

    private func apply() {
        hideKeyboard()
        busy = true
        Task {
            do {
                try await model.setReferrer(code: code)
                failed = false
                result = L("Code applied")
                Haptics.success(enabled: model.haptics)
                await load()
                result = L("Code applied")
            } catch {
                failed = true
                result = L("Exchange reply: {0}", error.localizedDescription)
                Haptics.error(enabled: model.haptics)
            }
            busy = false
        }
    }
}
