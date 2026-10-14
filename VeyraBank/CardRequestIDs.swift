import Foundation
import VeyraWallet

/// The `clientRequestID` of the add-card (digitise) that created each card, by the card's token
/// unique reference. A card does not carry it, so the app keeps it: "Remove card" names the add-card
/// attempt with `deactivateDigitise(clientRequestID:)`, and the SDK removes the card from this phone
/// when the server says `APPROVED`.
///
/// A card with no recorded ID (added before the app kept them) is removed with
/// `deactivateToken(_:)` instead.
enum CardRequestIDs {
    private static let key = "VeyraBankCardRequestIDs"

    private static var all: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Remembers the attempt's ID when the digitise added a card. `APPROVED` covers both response
    /// codes: a card that still needs activating is on the phone too.
    static func record(_ r: DigitiseResult) {
        guard r.responseStatus == ResponseStatus.approved,
              let tokenUniqueReference = r.tokenUniqueReference, !tokenUniqueReference.isEmpty,
              let clientRequestID = r.clientRequestID, !clientRequestID.isEmpty else { return }
        all[tokenUniqueReference] = clientRequestID
    }

    /// The ID of the add-card that created the card, or nil when none was recorded.
    static func get(_ tokenUniqueReference: String) -> String? { all[tokenUniqueReference] }

    /// Forgets the card's ID once the card is removed.
    static func forget(_ tokenUniqueReference: String) { all[tokenUniqueReference] = nil }
}
