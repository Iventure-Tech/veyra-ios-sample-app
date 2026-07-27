// Wallet transaction detail: one history row —
// amount / merchant / status / recorded time — with two receipt
// actions: View receipt (when one is linked by transaction
// hash) and Scan receipt (camera QR → processReceipt → saved + shown). Failures are always
// surfaced (no silent try?).
import SwiftUI
import VeyraWallet

struct TransactionDetailView: View {
    let tx: TransactionSummary

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
                if let (date, time) = recordedAt {
                    row("Date") { Text(date) }
                    row("Time") { Text(time) }
                }
                if let currency = tx.transactionCurrencyCode, !currency.isEmpty {
                    row("Currency") { Text(currency).font(.subheadline.monospaced()) }
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

    // ── Display helpers ─────────────────────────────────────────────────────────────────────

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
