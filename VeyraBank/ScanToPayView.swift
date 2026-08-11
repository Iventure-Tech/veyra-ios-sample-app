// Scan to pay: the wallet customer side of the MPM QR rail —
// AVFoundation QR scan (portrait, cancel) → verified-merchant confirm screen (merchant, city,
// amount) → Face ID on Pay (SDK-recorded CDCVM, one authentication per payment) → result.
// A rejected payload never reaches confirm; cancel/auth-failure stays on confirm.
import AVFoundation
import SwiftUI
import VeyraWallet

struct ScanToPayView: View {
    enum Stage {
        case scanning
        case confirming(VerifiedPayment)
        case paying(VerifiedPayment)
        case result(state: ResultState, headline: String, detail: String?)
    }

    /// How the result page reads a push outcome. Three states, because the gateway states three
    /// kinds of thing: it approved, it refused (declined/failed), or it does not know yet — and the
    /// third is neither of the first two. Anything not stated final is pending, which is also what
    /// the SDK stored and keeps polling for.
    enum ResultState {
        case approved, pending, refused

        init(responseStatus: String?) {
            switch responseStatus?.trimmingCharacters(in: .whitespaces).uppercased() {
            case "APPROVED": self = .approved
            case "DECLINED", "FAILED": self = .refused
            default: self = .pending
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var stage: Stage = .scanning
    /// Set while authentication/pay fails without leaving confirm (stay on confirm).
    @State private var confirmError: String?
    @State private var scanRejection: String?

    var body: some View {
        Group {
            switch stage {
            case .scanning:
                scanner
            case .confirming(let payment):
                confirm(payment, busy: false)
            case .paying(let payment):
                confirm(payment, busy: true)
            case .result(let state, let headline, let detail):
                result(state: state, headline: headline, detail: detail)
            }
        }
        .navigationTitle("Scan to pay")
        .navigationBarTitleDisplayMode(.inline)
    }

    // ── Scan ────────────────────────────────────────────────────────────────────────────────

    private var scanner: some View {
        ZStack {
            QrScannerView { payload in
                handleScanned(payload)
            }
            .ignoresSafeArea(edges: .bottom)
            VStack {
                Spacer()
                if let scanRejection {
                    Text(scanRejection)
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.black.opacity(0.75), in: Capsule())
                        .foregroundStyle(Brand.crimson)
                        .padding(.bottom, 8)
                }
                Text("Point your camera at the merchant's QR code")
                    .font(.footnote)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.black.opacity(0.6), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(.bottom, 24)
            }
        }
    }

    private func handleScanned(_ payload: String) {
        // On-device verification (pinned gateway key + expiry): a rejection must never reach
        // the confirm screen — surface the reason and keep scanning.
        do {
            switch try VeyraWallet.shared.tokenisation.inspectScannedQr(payload) {
            case .verified(let payment):
                scanRejection = nil
                withAnimation { stage = .confirming(payment) }
            case .rejected(let reason, _):
                scanRejection = rejectionText(reason)
            }
        } catch {
            scanRejection = String(describing: error)
        }
    }

    private func rejectionText(_ reason: ScanRejectionReason) -> String {
        switch reason {
        case .malformed: return "Not a Veyra payment code"
        case .missingSignature, .unknownKey, .badSignature: return "This code could not be verified"
        case .expired: return "This payment code has expired — ask the merchant for a new one"
        }
    }

    // ── Confirm (verified merchant + amount; Pay triggers Face ID) ─────────────────────────

    private func confirm(_ payment: VerifiedPayment, busy: Bool) -> some View {
        VStack(spacing: 24) {
            VStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.green)
                Text("Verified merchant").font(.footnote).foregroundStyle(.secondary)
                Text(payment.merchantName).font(.title2.weight(.semibold))
                if let city = payment.merchantCity, !city.isEmpty {
                    Text(city).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 2) {
                Text("Amount").font(.footnote).foregroundStyle(.secondary)
                Text("₦\(payment.amount)")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
            }
            if let confirmError {
                Text(confirmError).font(.footnote).foregroundStyle(Brand.crimson)
                    .multilineTextAlignment(.center).padding(.horizontal)
            }
            Button {
                Task { await pay(payment) }
            } label: {
                Group {
                    if busy {
                        ProgressView().tint(.white)
                    } else {
                        Label("Pay with Face ID", systemImage: "faceid")
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Brand.crimson, in: Capsule())
                .foregroundStyle(.white)
            }
            .disabled(busy)
            .padding(.horizontal, 24)
            Button("Cancel") { dismiss() }
                .disabled(busy)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pay(_ payment: VerifiedPayment) async {
        confirmError = nil
        // No authentication call here — payScannedContext raises the system Face ID / Touch ID
        // sheet itself, naming this merchant and amount, and answers with a typed authentication
        // error if the customer cancels or it fails.
        withAnimation { stage = .paying(payment) }
        do {
            let outcome = try await VeyraWallet.shared.tokenisation.payScannedContext(payment)
            // The push answers with a status, not just a code, and PENDING is a real
            // answer — the payer must not be told they were refused when the SDK has stored the
            // payment as unresolved and is still polling for it.
            let state = ResultState(responseStatus: outcome.responseStatus)
            withAnimation {
                switch state {
                case .approved:
                    stage = .result(state: state, headline: "Payment approved",
                                    detail: "₦\(payment.amount) to \(payment.merchantName)")
                case .pending:
                    stage = .result(
                        state: state, headline: "Payment pending",
                        detail: "The bank has not confirmed this yet (\(outcome.responseCode ?? "no code")). "
                            + "It will appear in your transactions once it settles."
                    )
                case .refused:
                    stage = .result(
                        state: state, headline: "Payment declined",
                        detail: outcome.message
                            ?? "The payment was not approved (\(outcome.responseCode ?? "no code"))."
                    )
                }
            }
        } catch VeyraWalletError.onlineRequired(let message) {
            // The card must go online before it can pay — friendly, actionable copy.
            withAnimation { stage = .confirming(payment) }
            confirmError = message
        } catch {
            // Terminal transport/SDK failure: back to confirm with the reason (no false result).
            withAnimation { stage = .confirming(payment) }
            confirmError = String(describing: error)
        }
    }

    // ── Result ──────────────────────────────────────────────────────────────────────────────

    private func result(state: ResultState, headline: String, detail: String?) -> some View {
        VStack(spacing: 16) {
            Image(systemName: resultSymbol(state))
                .font(.system(size: 64))
                .foregroundStyle(resultTint(state))
            Text(headline).font(.title2.weight(.semibold))
            if let detail {
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal)
            }
            Button("Done") { dismiss() }
                .font(.headline)
                .padding(.horizontal, 32).padding(.vertical, 12)
                .background(Brand.crimson, in: Capsule())
                .foregroundStyle(.white)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resultSymbol(_ state: ResultState) -> String {
        switch state {
        case .approved: return "checkmark.circle.fill"
        case .pending: return "clock.fill"
        case .refused: return "xmark.circle.fill"
        }
    }

    private func resultTint(_ state: ResultState) -> Color {
        switch state {
        case .approved: return .green
        case .pending: return .orange
        case .refused: return Brand.crimson
        }
    }
}

/// AVFoundation QR scanner (iOS 15 floor rules out `DataScannerViewController`; camera scanning
/// is app UI — the SDK API takes the scanned string). Portrait,
/// single-shot: reports each distinct payload once so a rejected code can be re-scanned after
/// the merchant refreshes it.
// Shared with GetPaidView's customer-QR scan.
struct QrScannerView: UIViewRepresentable {
    let onScanned: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScanned: onScanned) }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        context.coordinator.start(in: view)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    static func dismantleUIView(_ uiView: PreviewView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private let onScanned: (String) -> Void
        private let session = AVCaptureSession()
        private var lastPayload: String?

        init(onScanned: @escaping (String) -> Void) {
            self.onScanned = onScanned
        }

        func start(in view: PreviewView) {
            view.previewLayer.session = session
            view.previewLayer.videoGravity = .resizeAspectFill
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard granted, let self else { return }
                self.configureAndRun()
            }
        }

        private func configureAndRun() {
            session.beginConfiguration()
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                session.commitConfiguration()
                return
            }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                return
            }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            session.commitConfiguration()
            DispatchQueue.global(qos: .userInitiated).async { [session] in
                session.startRunning()
            }
        }

        func stop() {
            DispatchQueue.global(qos: .userInitiated).async { [session] in
                session.stopRunning()
            }
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard let code = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first,
                  let payload = code.stringValue, payload != lastPayload else { return }
            lastPayload = payload
            onScanned(payload)
        }
    }
}
