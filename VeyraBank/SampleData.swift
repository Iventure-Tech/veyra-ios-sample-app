// Sample / demo prefill data — the SINGLE SOURCE for every default value the sample app
// pre-fills into a form (nothing sample-related is hardcoded in a view).
//
// The demo user is ONE account holder that can both receive (SoftPOS) and pay (Wallet). They
// are EITHER a Personal merchant OR a Business merchant — never both — so there is a single
// identity below. The ONLY thing specific to a business is the CAC number (an individual does
// not have one). Replace the placeholder identity with the test account details from your
// Veyra onboarding pack — digitise/eligibility is checked against the issuer's test records,
// so an unknown account number is declined.
import Foundation

/// A demo account holder (Personal or Business). `merchantName == accountName` for both
/// (a business's name replaces the individual's name).
struct SampleMerchant {
    enum Kind {
        case personal
        case business
    }

    let kind: Kind

    // Common identity — used whether the user registers as Personal or Business, and for both
    // receiving (SoftPOS merchant) and paying (Wallet tokenisation). Canonical = the
    // wallet-proven tuple (tokenisation returns Approved).
    let accountNumber = "1234567890" // your test account (NUBAN) from Veyra onboarding
    let institutionCode = "000000" // your test institution code
    let accountName = "Ada Demo" // = merchant name
    let bvn = "22222222222"
    let emailAddress = "ada.demo@example.com"
    let walletAccountID = "ada.demo@example.com"
    let mobileNumber = "2348000000000"
    let acquirerID = "ACQ001"
    let addressLine1 = "12 Marina Street"
    let addressLine2 = "Lagos Island"
    let city = "Lagos"
    let state = "Lagos"
    let country = "Nigeria"
    let countryCode = "0566" // ISO 4217 numeric, Nigeria
    let currencyCode = "566" // ISO 4217 numeric, NGN — the demo sale currency (gateway-required on createContext)

    /// The merchant name is the account holder name (business name for a business).
    var merchantName: String { accountName }

    /// Business registration number — only a business has one.
    var cacNumber: String? { kind == .business ? "RC-0000000" : nil }

    /// Single-line address **built** from the structured parts (derive, don't duplicate),
    /// dropping blanks and collapsing consecutive duplicates (city/state both "Lagos" render once).
    var fullAddress: String {
        [addressLine1, addressLine2, city, state, country]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { acc, part in
                if acc.last?.caseInsensitiveCompare(part) != .orderedSame { acc.append(part) }
            }
            .joined(separator: ", ")
    }
}

/// Typed access point for the demo identities.
enum SampleData {
    static let personal = SampleMerchant(kind: .personal)
    static let business = SampleMerchant(kind: .business)

    /// A stand-in for the till's own order/basket/invoice id, which a real integration would take
    /// from its POS rather than generate here.
    ///
    /// It is optional, is never used as a lookup key, and may repeat across attempts of one sale —
    /// which is what ties a retry back to the original order, since every attempt now mints its
    /// own transaction reference. The **reference** itself is the SDK's to mint and arrives on the
    /// response; an app that invents one is keying its receipts off a value no gateway has seen.
    static func nextOrderID() -> String {
        "ORDER-\(Int(Date().timeIntervalSince1970 * 1000))"
    }
}
