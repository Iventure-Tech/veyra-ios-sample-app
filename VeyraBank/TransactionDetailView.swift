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
    private var liveRow: TransactionSummary { live ?? tx }

    @State private var linkedReceipt: TransactionReceipt?
    @State private var showingReceipt = false
    @State private var scanning = false
    @State private var processingScan = false
    @State private var scanError: String?

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
