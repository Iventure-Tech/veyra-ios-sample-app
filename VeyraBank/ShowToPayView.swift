// Show QR to pay (dynamic CPM) — the customer keys the merchant-stated amount, the
// SDK gates on Face ID (one authentication per QR, SDK-enforced), and the rendered QR carries
// the amount inside its cryptogram: the merchant's scan charges exactly it or fails
// verification. Fully offline — nothing is sent; the outcome lands via history polling.

import CoreImage.CIFilterBuiltins
import SwiftUI
import VeyraWallet

struct ShowToPayView: View {
    private enum Phase {
        case amountEntry
        case working
        case showing(PaymentQr, UIImage)
    }

    @State private var phase: Phase = .amountEntry
    @State private var amountText = ""
    @State private var errorMessage: String?
    @State private var secondsLeft: Int = 0
    @State private var expired = false
    // The outcome arrives via the gateway reconcile — poll while the QR is
    // up instead of waiting for a scene-active/Transactions-list visit that may never come.
    @State private var reconcileTask: Task<Void, Never>?
    @State private var settled: (approved: Bool, merchantName: String?)?

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            switch phase {
            case .amountEntry:
                amountEntry
            case .working:
                ProgressView("Preparing your QR…")
            case .showing(let qr, let image):
                qrDisplay(qr, image)
            }
        }
        .navigationTitle("Show QR to pay")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            reconcileTask?.cancel()
            reconcileTask = nil
            // Stop the SDK's expiry watch so its callback can't fire into a dismissed view.
            VeyraWallet.shared.tokenisation.cancelQrExpiry()
        }
    }

    private var amountEntry: some View {
        VStack(spacing: 16) {
            Text("Enter the amount the merchant stated")
                .font(.headline)
            TextField("0.00", text: $amountText)
                .keyboardType(.decimalPad)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
                .multilineTextAlignment(.center)
                .font(.title2)
            if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(Brand.crimson)
            }
            Button {
                Task { await render() }
            } label: {
                Label("Show QR", systemImage: "qrcode")
                    .font(.headline)
                    .padding(.horizontal, 24).padding(.vertical, 12)
                    .background(Brand.crimson, in: Capsule())
                    .foregroundStyle(.white)
            }
            .disabled(minorUnits == nil)
        }
        .padding()
    }

    private func qrDisplay(_ qr: PaymentQr, _ image: UIImage) -> some View {
        VStack(spacing: 14) {
            Text("₦\(Double(qr.amountMinorUnits) / 100, specifier: "%.2f")")
                .font(.largeTitle.bold())
            // Once the QR lapses (or the payment settles) the code must become
            // UNSCANNABLE, not merely dimmed — a faint QR is still machine-readable, so another
            // device could scan a no-longer-valid code. Swap the payload for an opaque placeholder
            // so nothing decodable remains on screen.
            Group {
                if expired || settled != nil {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(uiColor: .secondarySystemBackground))
                        Image(systemName: settled != nil ? "checkmark.circle" : "clock.badge.xmark")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                }
            }
            .frame(width: 280, height: 280)
            if let settled {
                // The gateway reconcile settled the payment while the QR was up:
                // show the outcome — with the registered merchant name when echoed.
                Label(
                    settled.approved
                        ? "Paid\(settled.merchantName.map { " — \($0)" } ?? "")"
                        : "Declined",
                    systemImage: settled.approved ? "checkmark.circle.fill" : "xmark.circle.fill"
                )
                .font(.headline)
                .foregroundStyle(settled.approved ? .green : Brand.crimson)
            } else {
                Text(expired ? "Expired — get a new QR" : "Expires in \(secondsLeft)s")
                    .font(.footnote)
                    .foregroundStyle(expired ? Brand.crimson : .secondary)
                Text("Show this code to the merchant")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button {
                Task { await render(amountMinorUnits: qr.amountMinorUnits) }
            } label: {
                Label("New QR", systemImage: "arrow.clockwise")
            }
        }
        .padding()
        .onReceive(ticker) { _ in
            if case .showing(let qr, _) = phase {
                let left = Int((Double(qr.expiresAtEpochMillis) / 1000) - Date().timeIntervalSince1970)
                secondsLeft = max(0, left)
                // This ticker is only the cosmetic "Expires in Ns" countdown — the
                // blanking trigger (`expired`) comes from the SDK's onExpired callback.
            }
        }
    }

    private var minorUnits: Int64? {
        guard let naira = Double(amountText), naira > 0 else { return nil }
        return Int64((naira * 100).rounded())
    }

    private func render(amountMinorUnits: Int64? = nil) async {
        guard let amount = amountMinorUnits ?? minorUnits else { return }
        errorMessage = nil
        phase = .working
        do {
            // One authentication per QR render — a regenerate re-authenticates (SDK-enforced).
            try await VeyraWallet.shared.tokenisation.authenticateForScannedPayment(
                reason: "Show a QR to pay ₦\(String(format: "%.2f", Double(amount) / 100))"
            )
            // The SDK owns the expiry timer and fires onExpired when the QR lapses —
            // blank the code then (an expired QR must not stay scannable).
            let qr = try await VeyraWallet.shared.tokenisation.showQrToPay(amountMinorUnits: amount) {
                expired = true
            }
            guard let image = Self.qrImage(from: qr.payload) else {
                throw VeyraWalletError.requestFailed(message: "Could not render the QR")
            }
            expired = false
            settled = nil
            phase = .showing(qr, image)
            startReconcilePolling(for: qr)
        } catch VeyraWalletError.onlineRequired(let message) {
            // The card must go online before a payment QR can be produced.
            errorMessage = message
            phase = .amountEntry
        } catch {
            errorMessage = error.localizedDescription
            phase = .amountEntry
        }
    }

    /// While the QR is displayed, drive the gateway reconcile
    /// every few seconds — the CPM outcome only exists server-side once the merchant charges,
    /// and nothing else polls while this screen is up. Stops on settle, expiry, or leave.
    private func startReconcilePolling(for qr: PaymentQr) {
        reconcileTask?.cancel()
        // Settlement is matched on THIS render's own transaction hash — never a time
        // window. transactionHistory returns only TERMINAL rows, so a time heuristic
        // ("recorded after now-15s") would let a just-settled PREVIOUS CPM payment show as this
        // unscanned QR's outcome ("Paid — <merchant>" before the merchant charged). The hash is
        // unique per render, so only the row for this QR can settle the display.
        reconcileTask = Task { @MainActor in
            while !Task.isCancelled && settled == nil && !expired {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                try? await VeyraWallet.shared.tokenisation.reconcilePendingTransactions()
                if let row = try? await VeyraWallet.shared.tokenisation
                    .transactionHistory(tokenUniqueReference: qr.tokenUniqueReference, limit: 10)
                    .first(where: { $0.transactionHash == qr.transactionHash }),
                    let status = row.authorizationStatus { // terminal by construction
                    // Don't display the pre-backfill placeholder as a merchant name.
                    let name = row.merchantName == "QR payment" ? nil : row.merchantName
                    settled = (approved: status == "APPROVED", merchantName: name)
                }
            }
        }
    }

    private static func qrImage(from payload: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
