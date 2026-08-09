// Merchant transaction history + receipts. The merchant side of the wallet's
// TransactionsView: every payment taken (tap / QR MPM / QR CPM) kept locally by the SDK, shown
// most-recent-first with a status + rail badge; a row tap builds the receipt QR the customer's
// wallet can scan. Nested inside the Get-paid flow (no top-level Home entry).
import SwiftUI
import CoreImage.CIFilterBuiltins
import VeyraSoftPOS

struct MerchantTransactionsView: View {
    let onBack: () -> Void

    @State private var transactions: [MerchantTransaction] = []
    @State private var loading = true
    @State private var receipt: MerchantReceipt?
    @State private var loadError: String?
    // A receipt that should exist but fails to load surfaces an alert, never a dead tap.
    @State private var receiptError = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.left").foregroundStyle(.white)
                }
                Spacer()
                Text("Transactions").font(.headline).foregroundStyle(.white)
                Spacer()
                Color.clear.frame(width: 44, height: 1) // balance the back button
            }
            .padding()

            if loading {
                Spacer(); ProgressView().tint(.white); Spacer()
            } else if transactions.isEmpty {
                Spacer()
                Text(loadError ?? "No transactions yet")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                // ScrollView, not List: the sample targets iOS 15 and List's background can't be
                // cleared there (scrollContentBackground is iOS 16+).
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(transactions.enumerated()), id: \.offset) { _, tx in
                            row(tx)
                                .padding(.horizontal)
                            Divider().background(Color.white.opacity(0.15))
                        }
                    }
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .task { await load() }
        .sheet(item: Binding(get: { receipt.map { ReceiptBox(receipt: $0) } }, set: { if $0 == nil { receipt = nil } })) { box in
            ReceiptView(receipt: box.receipt) { receipt = nil }
        }
        .alert("Receipt unavailable", isPresented: $receiptError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Couldn't build the receipt for this transaction — please try again.")
        }
    }

    /// Final statuses have receipts; a
    /// PENDING row shows no control rather than a dead tap.
    private static func hasReceipt(_ tx: MerchantTransaction) -> Bool {
        tx.status == "APPROVED" || tx.status == "DECLINED" || tx.status == "FAILED"
    }

    private func row(_ tx: MerchantTransaction) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(amountText(tx)).font(.subheadline.weight(.medium)).foregroundStyle(.white)
                    Spacer()
                    Text(tx.status)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor(tx.status))
                }
                HStack(spacing: 8) {
                    Text(tx.railLabel)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Capsule())
                        .foregroundStyle(.white.opacity(0.85))
                    if let t = tx.transactionTime {
                        Text(t).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                // The outcome's stated cause + code, verbatim from the backend (e.g.
                // "51 · INSUFFICIENT_FUNDS"); unresolved/legacy rows carry neither.
                if let reason = tx.responseStatusReason, !reason.isEmpty {
                    Text([tx.responseCode, reason].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary)
                } else if let code = tx.responseCode, !code.isEmpty {
                    Text(code).font(.caption2).foregroundStyle(.secondary)
                }
                // Whether the merchant's bank confirmed receiving the funds. Absent
                // while unconfirmed — nothing is shown, never "not received". (iOS has no
                // background poller; the field reflects what the SDK's store holds, and the
                // app can refresh it via transactions.creditConfirmation.)
                if let credit = tx.creditConfirmationStatus, !credit.isEmpty {
                    Text(credit == "RECEIVED" ? "Funds received by merchant bank" : "Bank credit could not be confirmed")
                        .font(.caption2)
                        .foregroundStyle(credit == "RECEIVED" ? Color.green : Color.secondary)
                }
                // Cardholder Name (EMV 5F20) as the card presented it — a Veyra token shows
                // its display name, e.g. "AFRIGO ****1234". Absent on QR-MPM (the merchant
                // never reads the card) and on rows recorded before the SDK captured it.
                if let cardholder = tx.cardholderName, !cardholder.isEmpty {
                    Text(cardholder).font(.caption2).foregroundStyle(.secondary)
                }
            }
            // An explicit receipt CTA — an invisible whole-row tap reads as
            // "no capability" on device.
            if Self.hasReceipt(tx) {
                Button { Task { await loadReceipt(tx.reference) } } label: {
                    Image(systemName: "qrcode")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
                .accessibilityLabel("View receipt")
            }
        }
        .padding(.vertical, 4)
    }

    private func load() async {
        do {
            transactions = try await VeyraSoftPOS.shared.transactions.history(limit: 50)
        } catch {
            loadError = "Couldn't load transactions"
        }
        loading = false
    }

    private func loadReceipt(_ reference: String) async {
        // Distinguish "load failed / no receipt" (alert) from success (sheet).
        if let loaded = try? await VeyraSoftPOS.shared.transactions.receipt(forReference: reference) {
            receipt = loaded
        } else {
            receiptError = true
        }
    }

    private func amountText(_ tx: MerchantTransaction) -> String {
        let major = Double(tx.amountMinorUnits) / 100
        return "₦" + String(format: "%.2f", major)
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "APPROVED": return .green
        case "DECLINED", "FAILED": return .red
        default: return .yellow
        }
    }
}

/// Identifiable wrapper so a `MerchantReceipt` can drive a `.sheet(item:)`.
/// Shared with GetPaidView's post-payment View-receipt CTA.
struct ReceiptBox: Identifiable {
    let receipt: MerchantReceipt
    var id: String { receipt.reference }
}

/// The receipt QR (rendered on-device via CIFilter) + summary.
struct ReceiptView: View {
    let receipt: MerchantReceipt
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Receipt").font(.headline)
                Spacer()
                Button("Done", action: onClose)
            }
            if let image = Self.makeQR(payload: receipt.qrPayload) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    // The customer's wallet camera must lock this — bigger than
                    // the payment QRs (those are read by a SoftPOS reader held close). Combined
                    // with the low-EC recipe below, the modules stay large enough to decode.
                    .frame(width: 300, height: 300)
            }
            Text(receipt.merchantName).font(.subheadline.weight(.semibold))
            Text("₦" + receipt.totalAmountFormatted).font(.title3.weight(.bold))
            Text(receipt.maskedToken).font(.footnote).foregroundStyle(.secondary)
            // The paying card as it presented itself (EMV 5F20) — merchant's copy only;
            // absent on QR-MPM, where the merchant never reads the card.
            if let cardholder = receipt.cardholderName, !cardholder.isEmpty {
                Text(cardholder).font(.footnote).foregroundStyle(.secondary)
            }
            Text("Show this to the customer to scan into their wallet")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
        }
        .padding()
    }

    /// Receipt QR recipe. Unlike the payment QRs (read by a SoftPOS reader held right against the
    /// screen), this one is scanned by the customer's phone camera at arm's length, so it must be
    /// as easy to decode as possible: error-correction "L" keeps a receipt-sized JSON payload at a
    /// lower QR version (fewer, larger modules) than the default "M" — the difference between the
    /// customer's wallet locking it and only "seeing" it.
    static func makeQR(payload: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "L"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
