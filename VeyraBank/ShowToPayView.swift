// Show QR to pay (dynamic CPM) — the customer keys the merchant-stated amount, the
// SDK gates on Face ID (one authentication per QR, SDK-enforced), and the rendered QR carries
// the amount inside its cryptogram: the merchant's scan charges exactly it or fails
// verification. Fully offline — nothing is sent; the outcome lands via history polling.

import CoreImage.CIFilterBuiltins
import SwiftUI
import VeyraWallet

struct ShowToPayView: View {
    // How often the shown QR re-reads its payment's stored row. A read of the phone's own store:
    // nothing is sent. How often the gateway is asked is the SDK's business.
    private static let rowWatchNanos: UInt64 = 1_000_000_000
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
    // The merchant charged this QR and the bank accepted it: debited, credit queued. Not final,
    // but the QR is used, so it comes down while the wait for the final status continues.
    @State private var accepted = false
    // The merchant charged this QR and the payment has no outcome yet. The QR is used, so it comes
    // down while the wait for the outcome continues.
    @State private var charged = false
    // The outcome arrives on the payment's stored row, which the SDK keeps up to date. Watch the
    // row while the QR is up; this screen sends nothing.
    @State private var rowWatchTask: Task<Void, Never>?
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
            rowWatchTask?.cancel()
            rowWatchTask = nil
            // Stop the SDK's expiry watch so its callback can't fire into a dismissed view.
            VeyraWallet.shared.cancelQrExpiry()
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
                if expired || settled != nil || accepted || charged {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(uiColor: .secondarySystemBackground))
                        Image(systemName: settled != nil ? "checkmark.circle" : (accepted || charged) ? "clock" : "clock.badge.xmark")
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
                // The payment reached its final status while the QR was up:
                // show the outcome — with the registered merchant name when echoed.
                Label(
                    settled.approved
                        ? "Paid\(settled.merchantName.map { " — \($0)" } ?? "")"
                        : "Declined",
                    systemImage: settled.approved ? "checkmark.circle.fill" : "xmark.circle.fill"
                )
                .font(.headline)
                .foregroundStyle(settled.approved ? .green : Brand.crimson)
            } else if accepted {
                Label("Payment accepted - waiting for credit approval", systemImage: "clock.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
            } else if charged {
                Label("The merchant has charged this code - payment pending", systemImage: "clock.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text("Don't pay again. The result will show here and in your transactions.")
                    .font(.footnote).foregroundStyle(.secondary)
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
            // No authentication call — showQrToPay raises the system sheet itself, once per
            // render, so a regenerate after expiry asks again on its own.
            // The SDK owns the expiry timer and fires onExpired when the QR lapses — blank the
            // code then (an expired QR must not stay scannable).
            let qr = try await VeyraWallet.shared.showQrToPay(amountMinorUnits: amount) {
                expired = true
            }
            // Showing a QR ends with an outcome: APPROVED (a QR was made) or NOT_SENT with the
            // reason no QR could be made. Nothing is sent either way.
            guard qr.responseStatus == ResponseStatus.approved, let payload = qr.payload else {
                switch qr.responseStatusReason {
                case "AUTH_CANCELLED":
                    // The customer dismissed the sheet — back to amount entry, no error banner.
                    break
                case "DEVICE_NOT_BOUND":
                    // The card was added on another device, or before this app was reinstalled, and
                    // will never be given payment keys here. Neither going online nor a smaller amount helps.
                    errorMessage = "This card can't pay on this phone — remove it and add it again on this phone"
                default:
                    // ONLINE_REQUIRED, AMOUNT_EXCEEDS_CARD_LIMIT, AUTH_UNAVAILABLE, TOKEN_NOT_ACTIVE, …:
                    // the SDK's message says what to do.
                    errorMessage = qr.message ?? qr.responseStatusReason ?? "Could not make a payment QR"
                }
                phase = .amountEntry
                return
            }
            guard let image = Self.qrImage(from: payload) else {
                errorMessage = "Could not render the QR"
                phase = .amountEntry
                return
            }
            expired = false
            settled = nil
            accepted = false
            charged = false
            phase = .showing(qr, image)
            startRowWatch(for: qr)
        } catch {
            errorMessage = error.localizedDescription
            phase = .amountEntry
        }
    }

    /// While the QR is displayed, watch THIS payment's stored row and show what happens to it:
    /// charged (the merchant scanned and charged the code; no outcome yet), accepted (debited,
    /// credit queued) and the final outcome. It reads the SDK's own store on a short local timer
    /// and makes no network call: the SDK keeps the row up to date, checking with the gateway as
    /// often as the gateway asks. Stops on a final status or on leave.
    private func startRowWatch(for qr: PaymentQr) {
        rowWatchTask?.cancel()
        // The hash is unique per render, so only the row for this QR can move the display.
        guard let hash = qr.transactionHash, let token = qr.tokenUniqueReference else { return }
        rowWatchTask = Task { @MainActor in
            while !Task.isCancelled && settled == nil {
                try? await Task.sleep(nanoseconds: Self.rowWatchNanos)
                guard !Task.isCancelled else { return }
                // A local read. The newest rows are enough: this payment was recorded moments ago.
                guard let rows = try? await VeyraWallet.shared.transactions(tokenUniqueReference: token, limit: 20),
                      let row = rows.first(where: { $0.transactionHash?.caseInsensitiveCompare(hash) == .orderedSame })
                else { continue }
                switch QrRowStates.shownQr(status: row.authorizationStatus, isCharged: row.isCharged) {
                case .waiting:
                    // Not charged yet: the QR stays up to be scanned.
                    continue
                case .chargedPending:
                    // The merchant's charge has reached the gateway and has no outcome yet: the
                    // code is used, so it comes down while the wait goes on.
                    charged = true
                case .accepted:
                    // ACCEPTED is not final: say so, and keep watching for the final status.
                    accepted = true
                case .final:
                    // Don't display the placeholder as a merchant name.
                    let name = row.merchantName == "QR payment" ? nil : row.merchantName
                    settled = (approved: row.authorizationStatus?.uppercased() == "APPROVED", merchantName: name)
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
