// Wallet transaction detail: one history row —
// amount / merchant / status / recorded time — with two receipt
// actions: View receipt (when one is linked by transaction
// hash) and Scan receipt (camera QR → processReceipt → saved + shown). Failures are always
// surfaced (no silent try?).
import SwiftUI
import VeyraWallet

struct TransactionDetailView: View {
    let tx: TransactionSummary
    /// Lets this screen re-read its own row while it is up, so a credit confirmation that lands
    /// during the visit appears without navigating away and back.
    let tokenUniqueReference: String

    /// The freshest copy of this row, re-read from the SDK's store; falls back to what we were
    /// handed. A **store read**, never a poll — the SDK owns the credit polling and keeps asking
    /// whether or not this screen exists.
    @State private var live: TransactionSummary?
    // In-flight state for the manual "check status" ask.
    @State private var checkingStatus = false
    @State private var statusCheckNote: String?
    private var liveRow: TransactionSummary { live ?? tx }

    @State private var linkedReceipt: TransactionReceipt?
    @State private var showingReceipt = false
    @State private var scanning = false
    @State private var processingScan = false
    @State private var scanError: String?
    // The on-demand credit check's in-flight flag and its transient note (stayed unconfirmed, or
    // failed). Neither is persisted — the SDK's stored row is the durable state.
    @State private var checkingCredit = false
    @State private var creditCheckNote: String?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(amountText).font(.title2.weight(.semibold))
                    Text(merchantName).font(.subheadline)
                    if let address = merchantAddress {
                        Text(address).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                // How this wallet paid — legacy rows (nil) show nothing, no guess.
                if let paidBy = entryMethodText {
                    row("Paid by") { Text(paidBy) }
                }
                // Registered merchant location — on MPM rows and gateway-reconciled CPM rows.
                if let location = tx.merchantLocation, !location.isEmpty {
                    row("Location") { Text(location) }
                }
                // The merchant's own order id — always a row, em-dash when absent: a tap/CPM row
                // learns the value from the status poll, so absence often means "not learned yet".
                // Read from the live row so a poll that lands during the visit fills it in.
                row("Merchant order ID") {
                    Text(orDash(liveRow.merchantOrderID)).font(.subheadline.monospaced())
                }
                row("Status") {
                    Text(statusText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(statusColor)
                }
                // Outcome cause + response code, verbatim from the rail that resolved this row;
                // legacy/unresolved rows carry neither and show nothing rather than a guess.
                if let reason = tx.responseStatusReason, !reason.isEmpty {
                    row("Reason") { Text(reason).font(.subheadline) }
                }
                if let code = tx.responseCode, !code.isEmpty {
                    row("Response code") { Text(code).font(.subheadline.monospaced()) }
                }
                if let (date, time) = recordedAt {
                    row("Date") { Text(date) }
                    row("Time") { Text(time) }
                }
                if let currency = tx.transactionCurrencyCode, !currency.isEmpty {
                    row("Currency") { Text(currency).font(.subheadline.monospaced()) }
                }

                // "Check status" — the customer's manual ask beside the SDK's own background poll.
                // Shown ONLY while the row is still open, and it disappears the moment the payment
                // resolves: a settled row has nothing left to ask, and offering the action would
                // imply its outcome might still change.
                //
                // It is the only route to an answer once the SDK's 30-day poll gives up, which is
                // also why an unresolved row is shown in history at all.
                if isOpen {
                    Button {
                        Task { await checkStatus() }
                    } label: {
                        if checkingStatus {
                            HStack {
                                ProgressView()
                                Text("Checking the payment status…")
                            }
                        } else {
                            Label("Check status", systemImage: "arrow.clockwise")
                        }
                    }
                    // The SDK has no throttle by design — the screen disables its own button.
                    .disabled(checkingStatus)
                    if let note = statusCheckNote {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            // The merchant-credited indicator — did the money actually reach the merchant's bank?
            // `isCreditConfirmationSupported` is the whole gate: false/nil means the rail does not
            // exist for this payment, so the section is absent entirely. Absence means "we cannot
            // ask", never "the merchant was not paid".
            if liveRow.isCreditConfirmationSupported == true {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(creditText)
                            .font(.subheadline)
                            .foregroundStyle(creditColor)
                        if let detail = creditDetail {
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)

                    // The credit leg's own id — what a bank is quoted when a merchant says the
                    // money never arrived. Same gate as the credit status above (this section);
                    // em-dash rather than a blank.
                    row("Credit transaction ID") {
                        Text(orDash(liveRow.creditTransactionID)).font(.subheadline.monospaced())
                    }

                    // "Check merchant credit" — the manual ask beside the SDK's own 30-day credit
                    // sweep. Shown on exactly the predicate the SDK enforces internally: approved,
                    // the merchant's bank on the confirmation rail, and not already RECEIVED —
                    // which deliberately includes a row the sweep gave up on and stamped
                    // UNABLE_TO_CONFIRM. That give-up means "we stopped asking", never "the
                    // merchant was not paid", so it is the row this button matters most for.
                    if canCheckCredit {
                        Button {
                            Task { await checkMerchantCredit() }
                        } label: {
                            if checkingCredit {
                                HStack {
                                    ProgressView()
                                    Text("Checking whether the merchant's bank received the funds…")
                                }
                            } else {
                                Label("Check merchant credit", systemImage: "arrow.clockwise")
                            }
                        }
                        // No SDK-side throttle by design — the screen disables its own button.
                        .disabled(checkingCredit)
                    }
                    if let note = creditCheckNote {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if tx.transactionHash != nil {
                Section {
                    if linkedReceipt != nil {
                        Button {
                            showingReceipt = true
                        } label: {
                            Label("View receipt", systemImage: "doc.text")
                        }
                    }
                    Button {
                        scanning = true
                    } label: {
                        if processingScan {
                            HStack { ProgressView(); Text("Processing receipt…") }
                        } else {
                            Label("Scan receipt", systemImage: "qrcode.viewfinder")
                        }
                    }
                    .disabled(processingScan)
                } footer: {
                    Text("Scan the QR on the merchant's receipt to keep a copy linked to this payment.")
                }
            }
        }
        .navigationTitle("Transaction")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadLinkedReceipt() }
        .task { await watchCreditConfirmation() }
        .sheet(isPresented: $showingReceipt) {
            if let linkedReceipt {
                WalletReceiptDetailView(receipt: linkedReceipt)
            }
        }
        .sheet(isPresented: $scanning) {
            NavigationView {
                ZStack {
                    QrScannerView { payload in
                        scanning = false
                        Task { await processScanned(payload) }
                    }
                    .ignoresSafeArea(edges: .bottom)
                    VStack {
                        Spacer()
                        Text("Point your camera at the receipt QR code")
                            .font(.footnote)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.black.opacity(0.6), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(.bottom, 24)
                    }
                }
                .navigationTitle("Scan receipt")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { scanning = false }
                    }
                }
            }
        }
        .alert("Could not process receipt", isPresented: .init(
            get: { scanError != nil }, set: { if !$0 { scanError = nil } }
        )) {
            Button("OK", role: .cancel) { scanError = nil }
        } message: {
            Text(scanError ?? "")
        }
    }

    private func row(_ label: String, @ViewBuilder value: () -> some View) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            value()
        }
        .font(.subheadline)
    }

    /// An absent value renders as an em-dash — a row is never blank and never dropped, so a
    /// missing order/credit id reads as absence rather than data loss.
    private func orDash(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "—" }
        return value
    }

    // ── Data ────────────────────────────────────────────────────────────────────────────────

    private func loadLinkedReceipt() async {
        guard let hash = tx.transactionHash else { return }
        do {
            linkedReceipt = try await VeyraWallet.shared.tokenisation.receipt(forTransactionHash: hash)
        } catch {
            // A load failure is not "no receipt" — surface it rather than showing a dead screen.
            scanError = "Could not load the linked receipt: \(error.localizedDescription)"
        }
    }

    private func processScanned(_ payload: String) async {
        processingScan = true
        defer { processingScan = false }
        // processReceipt expects the scanner's raw contents base64-encoded.
        let base64 = Data(payload.utf8).base64EncodedString()
        do {
            // This scan was launched FROM this transaction — the SDK rejects a receipt
            // belonging to any other transaction instead of silently linking it elsewhere.
            let receipt = try await VeyraWallet.shared.tokenisation.processReceipt(
                base64, expectedTransactionHash: tx.transactionHash)
            linkedReceipt = receipt
            showingReceipt = true
        } catch {
            scanError = error.localizedDescription
        }
    }

    /// Re-read this row from the SDK's store while the screen is up, so a credit confirmation
    /// that lands during the visit appears immediately.
    ///
    /// A store read, not a poll — the SDK's own credit sweep is app-scoped and runs for up to 30
    /// days regardless of this view. SwiftUI cancels this `.task` when the view goes away, which
    /// ends the refresh and nothing else. Stops once the answer is terminal.
    private func watchCreditConfirmation() async {
        guard let hash = tx.transactionHash, liveRow.isCreditConfirmationSupported == true else { return }
        while !Task.isCancelled && liveRow.creditConfirmationStatus == nil {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if Task.isCancelled { return }
            let rows = (try? await VeyraWallet.shared.tokenisation
                .transactionHistory(tokenUniqueReference: tokenUniqueReference, limit: 100)) ?? []
            if let fresh = rows.first(where: { $0.transactionHash == hash }) { live = fresh }
        }
    }

    /// Is this row still awaiting an outcome? A status this build does not recognise is open too —
    /// unknown values are carried raw, and an unresolved row must not read as settled just because
    /// we cannot name its status.
    private var isOpen: Bool {
        let stated = liveRow.authorizationStatus?
            .trimmingCharacters(in: .whitespaces).uppercased() ?? ""
        return !["APPROVED", "DECLINED", "FAILED"].contains(stated)
            && liveRow.transactionHash?.isEmpty == false
    }

    /// Ask now. A resolving answer re-renders the status line and hides the button; anything else is
    /// "still processing", which is an answer rather than a failure. A failure says why — offline
    /// above all (`NO_NETWORK_CONNECTION`) — and never changes the row.
    private func checkStatus() async {
        guard let hash = liveRow.transactionHash else { return }
        checkingStatus = true
        statusCheckNote = nil
        defer { checkingStatus = false }
        do {
            let fresh = try await VeyraWallet.shared.tokenisation
                .refreshTransactionStatus(transactionHash: hash)
            if let fresh { live = fresh }
            let stated = fresh?.authorizationStatus?
                .trimmingCharacters(in: .whitespaces).uppercased() ?? ""
            if !["APPROVED", "DECLINED", "FAILED"].contains(stated) {
                statusCheckNote = "Still processing — the wallet will keep checking."
            }
        } catch VeyraWalletError.noNetworkConnection {
            statusCheckNote = "No internet connection — connect and try again."
        } catch {
            statusCheckNote = "Could not check right now: \(error.localizedDescription)"
        }
    }

    // ── The on-demand credit check ──────────────────────────────────────────────────────────

    /// The one predicate: approved, the merchant's bank on the confirmation rail, and not already
    /// confirmed. The SDK enforces the same line internally, so a press outside it would be a no-op
    /// rather than a wasted request — but offering a control that does nothing is its own defect.
    private var canCheckCredit: Bool {
        liveRow.authorizationStatus == "APPROVED"
            && liveRow.isCreditConfirmationSupported == true
            && liveRow.creditConfirmationStatus != "RECEIVED"
            && liveRow.transactionHash?.isEmpty == false
    }

    /// Ask now. A confirming answer re-renders the credit line and hides the button; anything else
    /// is "not confirmed **yet**" and leaves the row alone. A failure says why — offline above all
    /// (`NO_NETWORK_CONNECTION`) — and never changes the row.
    private func checkMerchantCredit() async {
        guard let hash = liveRow.transactionHash else { return }
        checkingCredit = true
        creditCheckNote = nil
        defer { checkingCredit = false }
        do {
            let fresh = try await VeyraWallet.shared.tokenisation
                .refreshCreditConfirmation(transactionHash: hash)
            if let fresh { live = fresh }
            if fresh?.creditConfirmationStatus != "RECEIVED" {
                creditCheckNote = "Still not confirmed — the wallet will keep checking."
            }
        } catch VeyraWalletError.noNetworkConnection {
            creditCheckNote = "No internet connection — connect and try again."
        } catch {
            creditCheckNote = "Could not check right now: \(error.localizedDescription)"
        }
    }

    // ── Display helpers ─────────────────────────────────────────────────────────────────────

    /// The merchant-credited line. Only ever rendered with the supported flag true, so `nil` here
    /// means "no answer yet" — the in-flight state — and never "not received". The 30-day give-up
    /// says "could not confirm" for exactly the same reason.
    private var creditText: String {
        switch liveRow.creditConfirmationStatus {
        case "RECEIVED": return "Merchant's bank has received the funds"
        case "UNABLE_TO_CONFIRM": return "Could not confirm the merchant's bank received the funds"
        default: return "Confirming the merchant's bank has received the funds…"
        }
    }

    private var creditColor: Color {
        switch liveRow.creditConfirmationStatus {
        case "RECEIVED": return .green
        case "UNABLE_TO_CONFIRM": return .secondary
        default: return .orange
        }
    }

    /// The bank's own description of the credit — present on `RECEIVED` only.
    private var creditDetail: String? {
        let parts = [
            liveRow.creditedAt,
            liveRow.bankReference.map { "Bank reference: \($0)" },
        ].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Display strings for the wallet-perspective entry method.
    private var entryMethodText: String? {
        switch tx.entryMethod {
        case "TAP": return "Tapped"
        case "QR_GENERATED": return "Generated QR"
        case "QR_SCANNED": return "Scanned QR"
        default: return nil
        }
    }

    /// The merchant field may carry "Name*Address".
    private var merchantName: String {
        tx.merchantName.components(separatedBy: "*").first?.trimmingCharacters(in: .whitespaces) ?? tx.merchantName
    }

    private var merchantAddress: String? {
        let parts = tx.merchantName.components(separatedBy: "*")
        guard parts.count > 1 else { return nil }
        let address = parts.dropFirst().joined(separator: "*").trimmingCharacters(in: .whitespaces)
        return address.isEmpty ? nil : address
    }

    private var amountText: String {
        String(format: "%.2f", Double(tx.amountInMinorUnit) / 100.0)
    }

    private var statusText: String {
        switch tx.authorizationStatus {
        case "APPROVED": return "Approved"
        case "DECLINED": return "Declined"
        case "FAILED": return "Failed"
        case "PENDING": return "Pending"
        default: return "—"
        }
    }

    private var statusColor: Color {
        switch tx.authorizationStatus {
        case "APPROVED": return .green
        case "DECLINED", "FAILED": return Brand.crimson
        case "PENDING": return .orange
        default: return .secondary
        }
    }

    /// Recorded time is only carried for the QR rails (`atEpochMillis`); tap rows show no date.
    private var recordedAt: (String, String)? {
        guard let millis = tx.atEpochMillis else { return nil }
        let date = Date(timeIntervalSince1970: Double(millis) / 1000.0)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMM d, yyyy"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"
        return (dateFormatter.string(from: date), timeFormatter.string(from: date))
    }
}

// ── Receipt detail ─────────────────────────────────────────────────────────────────────────────

struct WalletReceiptDetailView: View {
    let receipt: TransactionReceipt
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(receipt.merchantName).font(.headline)
                        if let address = receipt.merchantAddress, !address.isEmpty {
                            Text(address).font(.footnote).foregroundStyle(.secondary)
                        }
                        if let id = receipt.merchantId, !id.isEmpty {
                            Text("ID: \(id)").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
                Section {
                    row("Amount", amountText)
                    row("Status", receipt.transactionStatus)
                    row("Type", receipt.transactionType)
                    row("Time", receipt.transactionTime)
                    if let card = receipt.maskedToken, !card.isEmpty { row("Card", card) }
                    if let ref = receipt.merchantTransactionReference, !ref.isEmpty { row("Reference", ref) }
                    if let txnId = receipt.transactionId, !txnId.isEmpty { row("Transaction ID", txnId) }
                    if let cdcvm = cdcvmText { row("Verification", cdcvm) }
                }
            }
            .navigationTitle("Receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }

    private var amountText: String {
        if let currency = receipt.currency, !currency.isEmpty {
            return "\(receipt.totalAmountFormatted) \(currency)"
        }
        return receipt.totalAmountFormatted
    }

    private var cdcvmText: String? {
        guard let approved = receipt.cdcvmApprovedByWallet else { return nil }
        return approved ? "Approved on device (CDCVM)" : "Not verified on device"
    }
}
