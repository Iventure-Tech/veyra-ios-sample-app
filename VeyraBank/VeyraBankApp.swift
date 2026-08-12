// Veyra Bank — iOS sample app for the Veyra SDK.
// Demonstrates both roles of a combined integration: Home / Get paid (SoftPOS merchant:
// tap acceptance, get-paid QR, charge a customer QR) / Pay (wallet: add card, scan-to-pay,
// show-QR-to-pay, history & receipts). Black + crimson (#C1272D).
// Credentials and identifiers come from Config/Veyra.xcconfig — see the README for setup.
import SwiftUI
import VeyraSDK
import VeyraSoftPOS
import VeyraWallet

enum SampleConfig {
    // Values are supplied via Config/Veyra.xcconfig (copy Config/Veyra.xcconfig.example and
    // fill in the credentials from your Veyra onboarding); the build injects them into
    // Info.plist, and they are read back here at launch.
    private static func configValue(_ key: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty, !value.hasPrefix("your-") else {
            fatalError("""
                Missing \(key): copy Config/Veyra.xcconfig.example to Config/Veyra.xcconfig, \
                fill in the values from your Veyra onboarding, then re-run xcodegen.
                """)
        }
        return value
    }

    static let clientID = configValue("VeyraClientID")
    static let clientSecret = configValue("VeyraClientSecret")
    static let paymentAppProviderID = configValue("VeyraPaymentAppProviderID")
    static let tokenRequestorID = configValue("VeyraTokenRequestorID")
    // payment_application_instance_id is SDK-generated per install — no longer configured here.
    // App Attest binds to teamID.bundleID, so the Apple Team ID is the signing team.
    static let appleTeamID = configValue("VeyraAppleTeamID")
    // Digitise provision_context allow-lists — the token product restricts provisioning to
    // these; a digitise outside the allowed country code is DECLINED. Country codes are
    // ISO 3166-1 numeric: 0566 = Nigeria.
    static let allowedAcquirerIDs = ["ACQ001"]
    static let allowedMerchantIDs = ["MERCHANT01"]
    static let allowedCountryCodes = ["0566"]
    static let allowedMCCs = ["5411"]

    static func configureSdks() {
        // Combined app: configure through the umbrella — installs the exclusive-mode arbiter
        // and starts inert (.none).
        VeyraSDK.configure(
            softpos: .init(
                environment: .test,
                // The provider credential the gateway resolves the acquirer id and MCC from —
                // the same identifier the wallet configuration carries.
                paymentAppProviderID: paymentAppProviderID,
                clientID: clientID,
                clientSecret: clientSecret
            ),
            wallet: .init(
                environment: .test,
                clientID: clientID,
                clientSecret: clientSecret,
                paymentAppProviderID: paymentAppProviderID,
                tokenRequestorID: tokenRequestorID,
                appleTeamID: appleTeamID, // App Attest app id = teamID.bundleID
                allowedAcquirerIDs: allowedAcquirerIDs,
                allowedMerchantIDs: allowedMerchantIDs,
                allowedCountryCodes: allowedCountryCodes,
                allowedMCCs: allowedMCCs
            )
        )
        // Clearing the SoftPOS merchant on uninstall is the SDK's job (the merchant profile
        // lives in a sandboxed protected file the OS removes with the app), so no
        // first-launch wipe is needed here.
    }
}

enum Brand {
    static let crimson = Color(red: 0xC1 / 255, green: 0x27 / 255, blue: 0x2D / 255)
}

@main
struct VeyraBankApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        SampleConfig.configureSdks()
    }

    var body: some Scene {
        WindowGroup {
            // NavigationView, not NavigationStack: the SDK floor is iOS 15 (iPhone 7 / 15.8.x
            // device-matrix floor) and NavigationStack is 16-only. .stack keeps iPad behaviour
            // identical to the stack navigation the sample was written for.
            NavigationView {
                HomeView()
            }
            .navigationViewStyle(.stack)
            .preferredColorScheme(.dark)
            .tint(Brand.crimson)
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            Task {
                // Scene-active LUK top-up: replenish the active card's payment keys
                // whenever the app foregrounds, before any pay screen is reached.
                try? await VeyraWallet.shared.tokenisation.topUpKeysIfNeeded()
                // Scene-active history reconcile: settle any PENDING rows — chiefly
                // show-to-pay QRs, which are offline and only learn their outcome this way.
                try? await VeyraWallet.shared.tokenisation.reconcilePendingTransactions()
            }
        }
    }
}

struct HomeView: View {
    // Home is the inert screen: mode is NONE here (the SDK claims a mode only while a
    // payment is actually in flight, and drops back to inert by itself).
    @State private var mode: VeyraMode = VeyraSDK.shared.currentMode
    // Get paid is locked until a merchant is registered;
    // registration/edit/activate/deactivate live behind the settings gear.
    @State private var registered = false
    @State private var showMerchantSettings = false
    @State private var merchantActionMessage: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 24) {
                Spacer()
                Text("V")
                    .font(.system(size: 72, weight: .black))
                    .foregroundStyle(Brand.crimson)
                Text("Veyra Bank")
                    .font(.title2).bold()
                    .foregroundStyle(.white)
                Text("Mode: \(mode.rawValue)")
                    .font(.footnote).foregroundStyle(.gray)
                if let merchantActionMessage {
                    Text(merchantActionMessage)
                        .font(.footnote).foregroundStyle(.gray)
                }
                Spacer()
                NavigationLink {
                    GetPaidView()
                } label: {
                    HomeTile(
                        title: "Get paid",
                        subtitle: registered
                            ? "SoftPOS — enter an amount to get paid"
                            : "Register as a merchant in Settings to accept payments"
                    )
                }
                .disabled(!registered)
                .opacity(registered ? 1 : 0.45)
                NavigationLink {
                    PayView()
                } label: {
                    HomeTile(title: "Pay", subtitle: "Wallet — add a card: choose your bank")
                }
                Spacer()
            }
            .padding()
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                // Not registered: the gear jumps straight to registration; registered:
                // Edit profile / Activate / Deactivate.
                if registered {
                    Menu {
                        Button("Edit profile") { showMerchantSettings = true }
                        Button("Activate") { Task { await merchantAction(activate: true) } }
                        Button("Deactivate") { Task { await merchantAction(activate: false) } }
                    } label: {
                        Image(systemName: "gearshape")
                    }
                } else {
                    Button {
                        showMerchantSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
        }
        // iOS 15 floor: navigationDestination(isPresented:) is 16-only, so drive the push with
        // the pre-16 NavigationLink(isActive:) pattern (hidden link, same $showMerchantSettings).
        .background(
            NavigationLink(isActive: $showMerchantSettings) {
                MerchantSettingsView()
            } label: {
                EmptyView()
            }
            .hidden()
        )
        .onAppear {
            mode = VeyraSDK.shared.currentMode
            registered = VeyraSoftPOS.shared.merchant.isRegistered
        }
    }

    private func merchantAction(activate: Bool) async {
        guard let merchantID = VeyraSoftPOS.shared.merchant.stored?.merchantID else { return }
        do {
            let status = activate
                ? try await VeyraSoftPOS.shared.merchant.activate(merchantID: merchantID)
                : try await VeyraSoftPOS.shared.merchant.deactivate(merchantID: merchantID)
            merchantActionMessage = "Merchant \(activate ? "activated" : "deactivated") (\(status.status ?? "?"))"
        } catch {
            merchantActionMessage = "Failed to \(activate ? "activate" : "deactivate") merchant"
        }
    }
}

/// iOS-15 stand-in for `LabeledContent` (16-only): label left, secondary value right —
/// the same rendering LabeledContent gives inside a Form.
struct LabeledRow: View {
    let label: String
    let value: String

    init(_ label: String, value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

struct HomeTile: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline).foregroundStyle(.white)
            Text(subtitle).font(.footnote).foregroundStyle(.gray)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Brand.crimson.opacity(0.6)))
    }
}
