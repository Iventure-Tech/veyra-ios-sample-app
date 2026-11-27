// What the stored row behind a displayed QR tells its screen to show. The QR screens never ask the
// gateway themselves: the SDK does, as often as the gateway tells it to, and writes each answer onto
// the row. The screens re-read the row from the phone's own store and render one of these states.
import Foundation

enum QrRowStates {

    /// The merchant's QR (customer scans it), read from `transaction(merchantTransactionReference:)`.
    enum MerchantQr: Equatable {
        /// Nobody has claimed the QR: keep it on screen.
        case waiting
        /// A wallet has claimed the QR and its payment has no outcome yet: take the QR down, wait.
        case claimedPending
        /// The customer was debited and the credit is queued. Not final: take the QR down, wait.
        case accepted
        /// The payment ended (approved, declined, failed): show the result.
        case final
        /// The row is gone: the QR expired unpaid, so no payment was recorded.
        case gone
    }

    /// The customer's QR (merchant scans it), read from `transactions(tokenUniqueReference:)` by its hash.
    enum ShownQr: Equatable {
        /// No merchant has charged the QR yet: keep it on screen.
        case waiting
        /// A merchant charged the QR and the payment has no outcome yet: take the QR down, wait.
        case chargedPending
        /// Debited, credit queued. Not final: take the QR down, wait.
        case accepted
        /// The payment ended: show the result.
        case final
    }

    private static let accepted = "ACCEPTED"
    private static let merchantFinal: Set<String> = ["APPROVED", "DECLINED", "FAILED", "RETRY"]
    private static let walletFinal: Set<String> = ["APPROVED", "DECLINED", "FAILED"]

    /// - Parameters:
    ///   - rowExists: false when the SDK holds no row for the QR's reference
    ///   - status: the row's `status`
    ///   - isQrClaimed: the row's `isQrClaimed`: true once a wallet has claimed the QR, false when
    ///     a claimed QR was released again, nil while nobody has claimed it
    static func merchantQr(rowExists: Bool, status: String?, isQrClaimed: Bool?) -> MerchantQr {
        guard rowExists else { return .gone }
        let stated = status?.trimmingCharacters(in: .whitespaces).uppercased() ?? ""
        if stated == accepted { return .accepted }
        if merchantFinal.contains(stated) { return .final }
        // The status is still open: the flag is what tells a claimed QR from an unscanned one.
        return isQrClaimed == true ? .claimedPending : .waiting
    }

    /// - Parameters:
    ///   - status: the row's `authorizationStatus`
    ///   - isCharged: the row's `isCharged`: true once the gateway holds the merchant's charge
    static func shownQr(status: String?, isCharged: Bool?) -> ShownQr {
        let stated = status?.trimmingCharacters(in: .whitespaces).uppercased() ?? ""
        if stated == accepted { return .accepted }
        if walletFinal.contains(stated) { return .final }
        // The status is still open: the flag is what tells a charged QR from an unscanned one.
        return isCharged == true ? .chargedPending : .waiting
    }
}
