// Get paid (softpos) — the merchant-side payment flow: amount entry (merchant-active gated,
// status auto-refreshed on entry) → payment-method choice → waiting screen. Both acceptance
// rails are wired: the QR (MPM) rail renders a scannable payment code, and the tap rail arms
// the CoreNFC reader through the shared EMV kernel — the dialogue runs to the ARQC; settlement
// follows with the shared payment client. The QR screen obtains a
// gateway-signed payment context (payments.createContext), renders it, and polls the
// context lifecycle until the customer's push settles. Registration/edit lives behind
// Home's settings gear (MerchantSettingsView), and Home gates this screen until a merchant
// is registered. Terminal outcomes (approved/declined/failed,
// both rails) show Done and auto-return to Home after 5s if untouched.
import CoreImage.CIFilterBuiltins
import SwiftUI
import VeyraSDK
import VeyraSoftPOS

struct GetPaidView: View {
    private enum Page {
        case amountEntry
        case method
        case qr
        case tap
        // CPM: scan the customer's payment QR → confirm its own amount → charge.
        case scanCustomerQr
        case confirmCustomerQr(ScannedCustomerQr)
        case chargingCustomerQr
        case customerQrResult(approved: Bool, detail: String?)
        // Merchant transaction history + receipts, nested inside the Get-paid flow.
        case transactions
    }

    /// Once a payment reaches a terminal outcome (approved/declined/failed), the screen returns
    /// to Home on its own after this delay — the merchant shouldn't have to touch anything
    /// between customers. Done returns immediately.
    private static let autoReturnDelayNanos: UInt64 = 5_000_000_000

    @Environment(\.presentationMode) private var presentationMode
    @State private var page: Page = .amountEntry
    // Where the transactions list returns to — it is reachable from both the amount-entry
    // page and the method page.
    @State private var transactionsReturn: Page = .amountEntry
    // The just-completed payment's merchant reference (set per rail at outcome)
    // drives the result screens' View receipt CTA — all rails, incl. CPM.
    @State private var lastPaymentReference: String?
    @State private var resultReceipt: MerchantReceipt?
    @State private var resultReceiptError = false
    @State private var autoReturnTask: Task<Void, Never>?
    @State private var customerQrScanHint: String?
    @State private var merchant: StoredMerchant?
    @State private var amountText = ""
    // Live MPM rail: context create → QR render → lifecycle polling.
    private enum QrState {
        case creating
        case live(UIImage)
        case failed(String)
        case settled(approved: Bool, responseCode: String?)
    }
    @State private var qrState: QrState = .creating
    @State private var qrTask: Task<Void, Never>?
    // Tap rail: CoreNFC reader + shared kernel; events drive this screen state.
    private enum TapState {
        case waiting                       // armed — hold the phones together
        case dialogue                      // card connected, kernel dialogue running
        case result(TapPaymentResult)
        case failed(String)
    }
    @State private var tapState: TapState = .waiting
    @State private var tapHint: String?
    @State private var tapSession: TapPaymentSession?
    @FocusState private var amountFocused: Bool

    /// A blank/absent status is treated as active
    /// (legacy stored merchants); only an explicit non-ACTIVE status locks the button.
    private var isActive: Bool {
        guard let status = merchant?.merchantStatus, !status.isEmpty else { return true }
        return status.uppercased() == "ACTIVE"
    }

    private var amountMinorUnits: Int64? {
        let trimmed = amountText.trimmingCharacters(in: .whitespaces)
        guard let value = Decimal(string: trimmed), value > 0 else { return nil }
        return NSDecimalNumber(decimal: value * 100).int64Value
    }

    private var formattedAmount: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "NGN"
        let naira = Double(amountMinorUnits ?? 0) / 100
        return formatter.string(from: NSNumber(value: naira)) ?? "₦\(naira)"
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch page {
            case .amountEntry: amountEntry
            case .method: methodChoice
            case .tap: tapWaiting
            case .qr: qrWaiting
            case .scanCustomerQr: customerQrScanner
            case .confirmCustomerQr(let scanned): customerQrConfirm(scanned)
            case .chargingCustomerQr: ProgressView("Charging…").tint(.white).foregroundStyle(.white)
            case .customerQrResult(let approved, let detail): customerQrResult(approved, detail)
            case .transactions: MerchantTransactionsView { page = transactionsReturn }
            }
        }
        .navigationTitle("Get paid")
        // Mode is SDK-managed: the tap session claims SOFTPOS when it starts and releases it
        // when it ends — no screen choreography needed here.
        .onAppear {
            merchant = VeyraSoftPOS.shared.merchant.stored
        }
        .onDisappear {
            autoReturnTask?.cancel()
        }
        // Entering the amount screen while not active kicks an immediate
        // backend status check so the screen unlocks as soon as the merchant goes active.
        .task { await refreshStatusIfInactive() }
        // The post-payment receipt sheet + failure alert, reachable from any
        // result surface (tap / MPM / CPM).
        .sheet(item: Binding(get: { resultReceipt.map { ReceiptBox(receipt: $0) } },
                             set: { if $0 == nil { resultReceipt = nil } })) { box in
            ReceiptView(receipt: box.receipt) { resultReceipt = nil }
        }
        .alert("Receipt unavailable", isPresented: $resultReceiptError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Couldn't build the receipt for this payment — find it under View transactions.")
        }
    }

    /// The result screens' View receipt CTA (all rails). Pauses the auto-return
    /// so the sheet isn't dismissed under the merchant; failures alert, never a dead tap.
    @ViewBuilder
    private var viewReceiptButton: some View {
        if let reference = lastPaymentReference {
            Button("View receipt") {
                autoReturnTask?.cancel()
                Task { @MainActor in
                    if let receipt = try? await VeyraSoftPOS.shared.transactions.receipt(forReference: reference) {
                        resultReceipt = receipt
                    } else {
                        resultReceiptError = true
                    }
                }
            }
            .font(.footnote)
            .tint(.white)
        }
    }

    private var amountEntry: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("Enter amount")
                .font(.title3).bold()
                .foregroundStyle(.white)
            TextField("0.00", text: $amountText)
                .keyboardType(.decimalPad)
                .focused($amountFocused)
                .multilineTextAlignment(.center)
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.white)
                .padding()
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.08)))
            if !isActive {
                Text("Your merchant account is not active. Please contact support to accept payments.")
                    .font(.footnote)
                    .foregroundStyle(Brand.crimson)
                    .multilineTextAlignment(.center)
            }
            Button {
                amountFocused = false
                page = .method
            } label: {
                Text("Process payment")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isActive || amountMinorUnits == nil)
            // CPM: the customer's QR carries its own cryptogram-bound amount —
            // no amount entry on this side; the merchant confirms what the QR says.
            Button {
                amountFocused = false
                page = .scanCustomerQr
            } label: {
                Label("Scan customer QR", systemImage: "qrcode.viewfinder")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .disabled(!isActive)
            // The transactions list is reachable straight from the
            // Get-paid landing page, and viewing history needs no
            // amount and no active merchant — so no `isActive` gate.
            Button {
                amountFocused = false
                transactionsReturn = .amountEntry
                page = .transactions
            } label: {
                Label("View transactions", systemImage: "list.bullet.rectangle")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
            .tint(.white)
            Spacer()
            if let merchant {
                Text("\(merchant.merchantName) · \(merchant.merchantID) · \(merchant.merchantStatus ?? "ACTIVE")")
                    .font(.footnote).foregroundStyle(.gray)
            }
        }
        .padding()
        .onAppear { amountFocused = true }
    }

    /// The two acceptance options — customer scans a QR, or taps their phone.
    private var methodChoice: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("How will your customer pay?")
                .font(.title3).bold()
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text(formattedAmount)
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(.white)
                .padding(.bottom, 16)
            Button {
                page = .qr
                startQrPayment()
            } label: {
                Label("Scan QR code", systemImage: "qrcode")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            Button {
                page = .tap
                startTapPayment()
            } label: {
                Label("Tap to pay", systemImage: "wave.3.right")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            // Transactions live inside the Get-paid flow, not a top-level Home entry.
            Button {
                transactionsReturn = .method
                page = .transactions
            } label: {
                Label("View transactions", systemImage: "list.bullet.rectangle")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .tint(.white)
            Spacer()
            Button("Back") { page = .amountEntry }
                .buttonStyle(.bordered)
        }
        .padding()
    }

    private var qrWaiting: some View {
        VStack(spacing: 24) {
            Spacer()
            Text("Scan to pay")
                .font(.title3).bold()
                .foregroundStyle(.white)
            Text(formattedAmount)
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(.white)
            // The QR is the gateway-signed PaymentContext
            // from createContext; the outcome arrives via context lifecycle polling.
            switch qrState {
            case .creating:
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 220, height: 220)
                    .overlay(ProgressView().tint(.white))
                Text("Creating your payment code…")
                    .font(.footnote).foregroundStyle(.gray)
            case .live(let image):
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 200, height: 200)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 14).fill(.white))
                Text("Ask your customer to scan this code")
                    .font(.footnote).foregroundStyle(.gray)
            case .failed(let message):
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 220, height: 220)
                    .overlay(
                        Text(message)
                            .font(.footnote).foregroundStyle(.gray)
                            .multilineTextAlignment(.center)
                            .padding()
                    )
            case .settled(let approved, let responseCode):
                VStack(spacing: 8) {
                    Image(systemName: approved ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(approved ? .green : .red)
                    Text(approved ? "Payment successful" : "Payment declined")
                        .font(.title3).bold()
                        .foregroundStyle(.white)
                    Text("Customer paid by QR · \(responseCode ?? "-")")
                        .font(.footnote).foregroundStyle(.gray)
                    viewReceiptButton
                }
            }
            Spacer()
            Button(qrFinished ? "Done" : "Cancel", role: qrFinished ? ButtonRole?.none : .destructive) {
                qrTask?.cancel()
                if qrFinished {
                    returnToHome()
                } else {
                    page = .amountEntry
                }
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .onDisappear {
            qrTask?.cancel()
            // Stop the SDK expiry watch so its callback can't fire into a dismissed view.
            VeyraSoftPOS.shared.payments.cancelQrExpiry()
        }
    }

    /// Terminal QR outcomes (settled either way, expired, create failed) — Done + auto-return.
    private var qrFinished: Bool {
        switch qrState {
        case .settled, .failed: return true
        case .creating, .live: return false
        }
    }

    /// Create the gateway-signed context, render it, and poll until the push settles.
    private func startQrPayment() {
        qrTask?.cancel()
        qrState = .creating
        lastPaymentReference = nil
        guard let merchantID = merchant?.merchantID else {
            qrState = .failed("Register as a merchant first")
            scheduleAutoReturn()
            return
        }
        let amount = amountMinorUnits ?? 0
        qrTask = Task {
            do {
                let context = try await VeyraSoftPOS.shared.payments.createContext(
                    merchantID: merchantID,
                    amountMinorUnits: amount,
                    currency: SampleData.personal.currencyCode,
                    onExpired: {
                        // The SDK owns the expiry timer; drop the live QR to the expired
                        // placeholder the moment it fires (an expired QR must not stay
                        // scannable), rather than waiting for the next server poll.
                        qrState = .failed("This payment code has expired — please start a new payment")
                        scheduleAutoReturn()
                    }
                )
                guard let image = Self.makeQR(payload: context.mpmPayload) else {
                    qrState = .failed("Could not render the payment code — please try again")
                    scheduleAutoReturn()
                    return
                }
                qrState = .live(image)
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 2_500_000_000)
                    guard let status = try? await VeyraSoftPOS.shared.payments.contextStatus(txRef: context.txRef) else {
                        continue
                    }
                    if status.isSettled {
                        // The MPM context's txRef is the recorded transaction's reference.
                        lastPaymentReference = context.txRef
                        // Settled — stop the expiry watch so it can't overwrite the outcome later.
                        VeyraSoftPOS.shared.payments.cancelQrExpiry()
                        qrState = .settled(approved: status.isApproved, responseCode: status.responseCode)
                        scheduleAutoReturn()
                        break
                    }
                    if status.state == "EXPIRED" {
                        qrState = .failed("This payment code has expired — please start a new payment")
                        scheduleAutoReturn()
                        break
                    }
                }
            } catch is CancellationError {
                // Page left / new QR requested.
            } catch {
                qrState = .failed("Could not create the payment code — please try again")
                scheduleAutoReturn()
            }
        }
    }

    private var tapWaiting: some View {
        VStack(spacing: 24) {
            Spacer()
            Text("Tap to pay")
                .font(.title3).bold()
                .foregroundStyle(.white)
            Text(formattedAmount)
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(.white)
            switch tapState {
            case .waiting:
                Image(systemName: "wave.3.right.circle")
                    .font(.system(size: 64)).foregroundStyle(.blue)
                Text(tapHint ?? "Hold the customer's phone against yours")
                    .font(.footnote).foregroundStyle(.gray)
                    .multilineTextAlignment(.center)
            case .dialogue:
                ProgressView().tint(.white).scaleEffect(1.6)
                Text("Reading — hold steady…")
                    .font(.footnote).foregroundStyle(.gray)
            case .result(let result):
                // Map the kernel outcome to a merchant-facing result — never surface
                // the raw server/kernel error string.
                let outcome = TapOutcome(status: result.status)
                Image(systemName: outcome.icon)
                    .font(.system(size: 64))
                    .foregroundStyle(outcome.color)
                Text(outcome.title)
                    .font(.title3).bold().foregroundStyle(.white)
                Text(outcome.message)
                    .font(.footnote).foregroundStyle(.gray)
                    .multilineTextAlignment(.center).padding(.horizontal)
                viewReceiptButton
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 48)).foregroundStyle(.orange)
                Text(message)
                    .font(.footnote).foregroundStyle(.gray)
                    .multilineTextAlignment(.center).padding(.horizontal)
            }
            Spacer()
            Button(tapFinished ? "Done" : "Cancel", role: tapFinished ? ButtonRole?.none : .destructive) {
                tapSession?.cancel()
                tapSession = nil
                if tapFinished {
                    returnToHome()
                } else {
                    page = .amountEntry
                }
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .onDisappear {
            tapSession?.cancel()
            tapSession = nil
        }
    }

    /// Terminal tap outcomes (result of any status, or reader failure) — Done + auto-return.
    private var tapFinished: Bool {
        switch tapState {
        case .result, .failed: return true
        case .waiting, .dialogue: return false
        }
    }

    /// Arm the CoreNFC reader for one tap; kernel dialogue events drive the screen —
    /// unsupported targets keep the reader armed with a hint, mirroring a physical terminal.
    private func startTapPayment() {
        tapState = .waiting
        tapHint = nil
        lastPaymentReference = nil
        let session = VeyraSoftPOS.shared.tap.session(amountMinorUnits: amountMinorUnits ?? 0) { event in
            switch event {
            case .cardDetected:
                tapState = .dialogue
            case .unsupportedTarget:
                tapState = .waiting
                tapHint = "Card not supported — ask for their Veyra wallet and try again"
            case .ended(let outcome):
                if outcome != .cancelled {
                    tapState = .failed("Reader ended (\(outcome.rawValue)) — please try again")
                    scheduleAutoReturn()
                }
            case .result(let result):
                lastPaymentReference = result.reference
                tapState = .result(result)
                scheduleAutoReturn()
            }
        }
        tapSession = session
        do {
            try session.start()
        } catch {
            tapState = .failed("Could not arm the reader — finish the in-flight payment first")
            scheduleAutoReturn()
        }
    }

    /// A terminal outcome auto-returns to Home after [autoReturnDelayNanos] so the
    /// merchant lands back on the main menu even without touching the screen; pressing Done
    /// (or leaving the screen) cancels the timer.
    // ── CPM: scan the customer's payment QR ──────────────────────────────────────────────────

    private var customerQrScanner: some View {
        ZStack {
            QrScannerView { payload in handleCustomerQrScan(payload) }
                .ignoresSafeArea()
            VStack {
                Spacer()
                if let customerQrScanHint {
                    Text(customerQrScanHint)
                        .font(.footnote)
                        .padding(10)
                        .background(.black.opacity(0.7), in: Capsule())
                        .foregroundStyle(.white)
                }
                Button("Cancel") { page = .amountEntry }
                    .tint(.white)
                    .padding(.bottom, 24)
            }
        }
    }

    private func handleCustomerQrScan(_ payload: String) {
        guard case .scanCustomerQr = page else { return } // one transition per scan session
        Task { @MainActor in
            do {
                let scanned = try await VeyraSoftPOS.shared.payments.inspectCustomerQr(payload)
                page = .confirmCustomerQr(scanned)
            } catch {
                // Not a payment QR — transient hint, stay armed (no terminal failure).
                customerQrScanHint = "Not a payment code — try again"
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                customerQrScanHint = nil
            }
        }
    }

    private func customerQrConfirm(_ scanned: ScannedCustomerQr) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Text("Charge customer?")
                .font(.title3).bold().foregroundStyle(.white)
            Text("₦\(Double(scanned.amountMinorUnits) / 100, specifier: "%.2f")")
                .font(.system(size: 40, weight: .semibold)).foregroundStyle(.white)
            // The QR carries the card's display name ("AFRIGO ****1234"); older QRs carry
            // none, so fall back to the last four.
            Text("\(scanned.cardholderName ?? "Card •••• \(scanned.maskedCard)") · amount read from the customer's QR")
                .font(.footnote).foregroundStyle(.gray)
            Button {
                chargeCustomerQr(scanned)
            } label: {
                Text("Charge").frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            Button("Cancel") { page = .amountEntry }
                .tint(.white)
            Spacer()
        }
        .padding()
    }

    private func chargeCustomerQr(_ scanned: ScannedCustomerQr) {
        page = .chargingCustomerQr
        lastPaymentReference = nil
        Task { @MainActor in
            do {
                let outcome = try await VeyraSoftPOS.shared.payments.chargeCustomerQr(scanned)
                // A delivered outcome (approved or declined) is recorded under this reference.
                lastPaymentReference = outcome.reference
                page = .customerQrResult(
                    approved: outcome.approved,
                    detail: "Customer QR payment · \(outcome.responseCode ?? "-")"
                )
            } catch {
                // Transport failure — nothing recorded, so no receipt CTA.
                page = .customerQrResult(approved: false, detail: error.localizedDescription)
            }
            scheduleAutoReturn()
        }
    }

    private func customerQrResult(_ approved: Bool, _ detail: String?) -> some View {
        VStack(spacing: 8) {
            Image(systemName: approved ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(approved ? .green : .red)
            Text(approved ? "Payment successful" : "Payment declined")
                .font(.title3).bold()
                .foregroundStyle(.white)
            if let detail {
                Text(detail).font(.footnote).foregroundStyle(.gray)
            }
            Button("Done") { page = .amountEntry }
                .tint(.white)
                .padding(.top, 12)
            // The CPM result gets the receipt CTA too (all rails).
            viewReceiptButton
            // Result-screen shortcut into the transactions list.
            Button("View transactions") {
                autoReturnTask?.cancel()
                page = .transactions
            }
            .font(.footnote)
            .tint(.white)
        }
    }

    private func scheduleAutoReturn() {
        autoReturnTask?.cancel()
        autoReturnTask = Task {
            try? await Task.sleep(nanoseconds: Self.autoReturnDelayNanos)
            guard !Task.isCancelled else { return }
            returnToHome()
        }
    }

    private func returnToHome() {
        autoReturnTask?.cancel()
        autoReturnTask = nil
        presentationMode.wrappedValue.dismiss()
    }

    /// Encode [payload] verbatim (the EMVCo-MPM string the wallet decodes and verifies).
    private static func makeQR(payload: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private func refreshStatusIfInactive() async {
        guard !isActive, let merchantID = merchant?.merchantID else { return }
        // The facade refreshes the stored merchant's status as part of the lookup.
        _ = try? await VeyraSoftPOS.shared.merchant.status(merchantID: merchantID)
        merchant = VeyraSoftPOS.shared.merchant.stored
    }
}

/// Merchant-facing mapping of a tap's `TransactionStatus` — icon, colour, and copy for
/// each outcome. Keeps the raw kernel/server error string out of the UI.
private struct TapOutcome {
    let icon: String
    let color: Color
    let title: String
    let message: String

    init(status: String) {
        switch status.uppercased() {
        case "APPROVED":
            icon = "checkmark.circle.fill"; color = .green
            title = "Payment successful"; message = "The customer's payment was approved."
        case "DECLINED":
            icon = "xmark.circle.fill"; color = .red
            title = "Payment declined"; message = "The customer's bank declined this payment."
        case "PENDING":
            icon = "clock.fill"; color = .orange
            title = "Payment pending"; message = "We couldn't confirm the payment yet — we'll update the status shortly."
        default: // FAILED / unknown
            icon = "xmark.circle.fill"; color = .red
            title = "Transaction failed"; message = "Something went wrong. Please ask the customer to tap again."
        }
    }
}
