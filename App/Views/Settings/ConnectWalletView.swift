import SwiftUI
import CoreImage.CIFilterBuiltins
import HyperCore

/// Connects an external wallet over WalletConnect and approves an on-device trading key
/// (the same "Enable trading" flow as app.hyperliquid.xyz). `renew` re-approves the key for an existing account.
struct ConnectWalletView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let renew: Account?

    enum Step: Equatable {
        case idle, pairing, waitingSession, approving, done
        case failed(String)
    }

    @State private var walletApp: WalletApp = .rabby
    @State private var name = ""
    @State private var step: Step = .idle
    @State private var uri: PairingLink?
    @State private var address: String?
    @State private var showQR = false
    @State private var flow: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                if renew == nil {
                    Section {
                        Picker(L("Wallet"), selection: $walletApp) {
                            ForEach(WalletApp.allCases) { Text($0.title).tag($0) }
                        }
                        TextField(L("Name (e.g. Main)"), text: $name)
                    } footer: {
                        Text(L("Your wallet signs once to allow a trading key stored on this phone. Orders are then placed without prompts; withdrawals and transfers are confirmed in the wallet. The trading key cannot withdraw funds."))
                    }
                }

                Section(L("Progress")) {
                    stepRow(L("Connect the wallet"), active: step == .pairing || step == .waitingSession,
                            done: address != nil)
                    if let address { LabeledContent(L("Address"), value: Address.short(address)).font(.caption) }
                    stepRow(L("Sign “Enable trading” in the wallet"), active: step == .approving, done: step == .done)
                    if case .failed(let msg) = step {
                        Text(msg).font(.caption).foregroundStyle(Color.hlRed)
                    }
                }

                if let uri, step == .waitingSession {
                    Section {
                        Button { walletApp.open(uri: uri) } label: {
                            Label(L("Open {0} again", walletApp.title), systemImage: "arrow.up.forward.app")
                        }
                        Button {
                            UIPasteboard.general.string = uri.absolute
                            model.show(.success, L("Link copied"))
                        } label: { Label(L("Copy connection link"), systemImage: "doc.on.doc") }
                        Button { showQR.toggle() } label: { Label(L("Show QR code"), systemImage: "qrcode") }
                        if showQR, let img = qrImage(uri.absolute) {
                            Image(uiImage: img).interpolation(.none).resizable().scaledToFit()
                                .frame(maxWidth: 240).frame(maxWidth: .infinity)
                                .padding(8).background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                        }
                    } footer: {
                        Text(L("If the wallet did not open, copy the link and paste it in the wallet's WalletConnect screen, or scan the QR code."))
                    }
                }

                Section {
                    switch step {
                    case .idle, .failed:
                        PrimaryButton(title: renew == nil ? L("Connect {0}", walletApp.title) : L("Renew trading key")) { start() }
                    case .done:
                        PrimaryButton(title: L("Done")) { dismiss() }
                    default:
                        HStack { Spacer(); ProgressView(); Spacer() }
                    }
                }
                .listRowBackground(Color.clear)
            }
            .navigationTitle(renew == nil ? L("Connect wallet") : L("Renew trading key"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Close")) {
                        flow?.cancel()
                        WalletConnectService.shared.cancelPairing()
                        dismiss()
                    }
                }
            }
            .onAppear {
                if let r = renew, let w = r.walletApp.flatMap(WalletApp.init(rawValue:)) { walletApp = w }
            }
        }
    }

    private func stepRow(_ title: String, active: Bool, done: Bool) -> some View {
        HStack {
            if done { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.hlGreen) }
            else if active { ProgressView().controlSize(.small) }
            else { Image(systemName: "circle").foregroundStyle(Color.hlMuted) }
            Text(title)
        }
    }

    private func start() {
        flow = Task { await run() }
    }

    private func run() async {
        let wc = WalletConnectService.shared
        do {
            let topic: String
            let addr: String
            let chainId: UInt64
            if let r = renew, let t = r.wcTopic, wc.hasSession(topic: t) {
                topic = t; addr = r.address; chainId = r.wcChainId ?? 42161
                address = addr
            } else {
                step = .pairing
                let pairing = try await wc.startPairing()
                uri = pairing
                step = .waitingSession
                walletApp.open(uri: pairing)
                let connected = try await wc.waitForSession()
                topic = connected.topic; addr = connected.address; chainId = connected.chainId
                address = addr
                if let r = renew, r.address.lowercased() != addr {
                    throw HLError(L("The wallet returned a different address ({0}). Switch the account in the wallet.", Address.short(addr)))
                }
            }

            step = .approving
            let (agent, agentKey) = try HLWallet.generate()
            let nonce = model.nextNonce()
            let action = HLAction.approveAgent(agentAddress: agent.address, agentName: "Hype iOS", nonce: nonce,
                                               mainnet: model.network.isMainnet, chainId: chainId)
            let sig = try await wc.signTypedData(topic: topic, address: addr, chainId: chainId,
                                                 json: action.typedDataJSON(), wallet: walletApp)
            let res = try await model.api.exchange(action: action.action, nonce: nonce, signature: sig, vault: nil)
            guard res["status"].str == "ok" else {
                throw HLError(model.translate(res["response"].string ?? L("Unknown error")))
            }

            if let r = renew, let i = model.accounts.firstIndex(where: { $0.id == r.id }) {
                Keychain.set(agentKey, for: r.keychainKey)
                model.accounts[i].signerAddress = agent.address
                model.accounts[i].wcTopic = topic
                model.accounts[i].wcChainId = chainId
            } else {
                var acc = Account(name: name.isEmpty ? walletApp.title : name, address: addr, kind: .wallet,
                                  signerAddress: agent.address)
                acc.wcTopic = topic
                acc.wcChainId = chainId
                acc.walletApp = walletApp.rawValue
                model.addAccount(acc, key: agentKey)
            }
            step = .done
            model.show(.success, L("Wallet connected, trading enabled"))
            Haptics.success(enabled: model.haptics)
        } catch is CancellationError {
            step = .idle
        } catch {
            step = .failed(error.localizedDescription)
            Haptics.error(enabled: model.haptics)
        }
    }

    private func qrImage(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        guard let out = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
