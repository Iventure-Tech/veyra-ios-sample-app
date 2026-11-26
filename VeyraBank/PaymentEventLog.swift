import os
import VeyraSoftPOS
import VeyraWallet

/// App-scope payment events: the SDKs report a payment that left PENDING (and, once before that,
/// one that became ACCEPTED) and a credit confirmation, possibly long after the view that started
/// the payment is gone, or for a payment from an earlier session. Registered once, where the app
/// tells the SDKs who is logged in, so the observers outlive every view.
///
/// Each event is logged as one line under the category `VeyraEvents` (Xcode console, or Console.app
/// filtered on that category). The lines carry identifiers, status and amount only, never an
/// account number or a person's name.
///
/// Each observer holds one listener (last registration wins), and the SDKs drop them on sign-out
/// and on a customer switch, so `register()` runs after every sign-in. A view that needs one of
/// these events itself must not register the same observer: it would replace this one.
enum PaymentEventLog {
    private static let log = Logger(subsystem: "co.veyra.bank.ios", category: "VeyraEvents")

    static func register() {
        // SoftPOS: a sale left PENDING (APPROVED / DECLINED / FAILED), or became ACCEPTED (not final).
        // Get paid registers the SoftPOS credit-confirmation observer itself, for its result page.
        do {
            try VeyraSoftPOS.shared.observeTransactionResolved { event in
                log.info("""
                    softpos transactionResolved reference=\(event.merchantTransactionReference, privacy: .public) \
                    status=\(event.status, privacy: .public) responseCode=\(event.responseCode ?? "nil", privacy: .public) \
                    reason=\(event.reason ?? "nil", privacy: .public)
                    """)
            }
        } catch {
            log.error("softpos observeTransactionResolved failed: \(error.localizedDescription, privacy: .public)")
        }
        // Wallet: a payment left PENDING, or became ACCEPTED (not final). On iOS that is the QR rails
        // (no wallet tap-to-pay on iOS).
        do {
            try VeyraWallet.shared.observeTransactionResolved { event in
                log.info("""
                    wallet transactionResolved transactionHash=\(event.transactionHash, privacy: .public) \
                    tokenUniqueReference=\(event.tokenUniqueReference ?? "nil", privacy: .public) \
                    status=\(event.status, privacy: .public) responseCode=\(event.responseCode ?? "nil", privacy: .public) \
                    reason=\(event.reason ?? "nil", privacy: .public) amountMinorUnits=\(event.amountMinorUnits, privacy: .public)
                    """)
            }
        } catch {
            log.error("wallet observeTransactionResolved failed: \(error.localizedDescription, privacy: .public)")
        }
        // Wallet: the merchant's bank received the funds (RECEIVED), or 30 days passed (UNABLE_TO_CONFIRM).
        do {
            try VeyraWallet.shared.observeCreditConfirmation { event in
                log.info("""
                    wallet creditConfirmation transactionHash=\(event.transactionHash, privacy: .public) \
                    tokenUniqueReference=\(event.tokenUniqueReference ?? "nil", privacy: .public) \
                    creditTransactionID=\(event.creditTransactionID ?? "nil", privacy: .public) \
                    status=\(event.status, privacy: .public) \
                    amountMinorUnits=\(event.amountMinorUnits.map(String.init) ?? "nil", privacy: .public) \
                    bankReference=\(event.bankReference ?? "nil", privacy: .public) \
                    creditedAt=\(event.creditedAt ?? "nil", privacy: .public)
                    """)
            }
        } catch {
            log.error("wallet observeCreditConfirmation failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
