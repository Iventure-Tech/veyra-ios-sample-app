# Veyra SDK for iOS — Developer Guide

This document describes the public API exposed by the Veyra SDK on **iOS**. Only the classes and methods documented here are supported API; anything else you can reach in the package is internal and may change without notice.

## Overview

The Veyra SDK turns a phone into either side of a contactless payment:

- **SoftPOS (merchant side)** — accept payments: NFC tap acceptance, get-paid QR codes (merchant-presented), scanning customer payment QRs (consumer-presented), merchant registration, transaction history and receipts.
- **Wallet (customer side)** — make payments: account tokenisation ("add card"), token activation, scan-to-pay, show-QR-to-pay, transaction history and receipts.

Three ways to ship it:

| Integration | iOS product | Use when |
|---|---|---|
| **SoftPOS only** | `VeyraSoftPOS` | Your app only accepts payments |
| **Wallet only** | `VeyraWallet` | Your app only makes payments |
| **Combined** | `VeyraSDK` | One app does both — never at the same time; the SDK enforces an exclusive mode |

Building for Android? See the Android guide in the Android sample repo: https://github.com/Iventure-Tech/veyra-android-sample-app.

A combined app is always in exactly one **mode** — none, receiving (SoftPOS) or paying (Wallet). The mode switches **implicitly** with your payment activity — the SDK claims it when a tap session or wallet payment starts and releases it when they finish; see [Exclusive mode](#exclusive-mode-combined-apps).

> **iOS note:** tap **acceptance** on iPhone reads the customer's Android Veyra wallet over CoreNFC. Tap-to-**pay** (card emulation) is not available on iOS — Apple restricts card emulation — so the iOS wallet pays by QR (scan-to-pay and show-QR-to-pay).

---

## Requirements

| Requirement | Value |
|---|---|
| Minimum iOS | **15.0** |
| Swift tools | 5.9+ |
| Device | Real device for wallet operations (App Attest does not run on the simulator); NFC-capable iPhone for tap acceptance |
| Apple Developer Team ID | Required in the wallet configuration (`appleTeamID`) — device attestation binds to `teamID.bundleID` |

**Info.plist keys** (as used by the sample app):

| Key | Value / purpose |
|---|---|
| `NFCReaderUsageDescription` | e.g. "Accept a contactless payment from your customer's Veyra wallet." — required for tap acceptance |
| `NSCameraUsageDescription` | e.g. "Scan a merchant's QR code to pay, or scan a receipt QR." — required for the QR-scanning flows |
| `NSFaceIDUsageDescription` | e.g. "Confirm payments with Face ID." — required for payment confirmation |
| `com.apple.developer.nfc.readersession.iso7816.select-identifiers` | Must contain the Veyra application identifier **`A000000891010104`** — the tap reader selects Veyra's own application (no scheme cards are read) |

**Entitlements:** `com.apple.developer.nfc.readersession.formats` = `TAG` (for tap acceptance). No background modes are required — all SDK maintenance runs while your app is in the foreground.

---

## Getting the SDK

The iOS SDK is a Swift package with three products — `VeyraSDK` (combined), `VeyraSoftPOS`, `VeyraWallet`. It is distributed via the public package repository:

```
https://github.com/Iventure-Tech/veyra-sdk-ios
```

The package wraps a precompiled binary hosted on the Veyra artifact server, which is
**authenticated** — before resolving the package, add the repository credentials from your
Veyra onboarding to `~/.netrc` (SwiftPM and Xcode read it when downloading binary targets):

```
machine repo.veyra.co
  login your-repo-username
  password your-repo-password
```

```bash
chmod 600 ~/.netrc   # netrc must not be world-readable
```

In Xcode, open *File → Add Package Dependencies*, paste the repository URL, and select the product that matches your integration (`VeyraSDK` for a combined app, `VeyraSoftPOS` for SoftPOS-only, `VeyraWallet` for wallet-only). Release versions are tagged with each SDK release — the version to pin is given in your onboarding/release notes. Or in a `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Iventure-Tech/veyra-sdk-ios", from: "1.0.17"),
]
```

Then:

```swift
import VeyraSDK       // combined
import VeyraSoftPOS   // merchant features
import VeyraWallet    // wallet features
```

The package includes a prebuilt binary that Xcode downloads and checksum-verifies automatically during package resolution — no manual embedding is needed.

---

## Main entry points

### `VeyraSDK` (combined apps)

```swift
VeyraSDK.configure(softpos: softposConfig, wallet: walletConfig)
```

**Members:**

| Member | Parameters | Description |
|--------|------------|-------------|
| `configure(softpos:wallet:)` | Both member configurations | Configures both SDKs plus the exclusive-mode arbiter. The process starts **inert**; safe to call again (reconfigures, stays inert). Call once at launch. |
| `shared` | — | The singleton. |
| `currentMode` | — | The current exclusive mode (`VeyraMode.none` / `.softpos` / `.wallet`). Read-only observation for UI state — the mode itself is entirely SDK-managed. |

In a standalone single-product app (only `VeyraSoftPOS` *or* only `VeyraWallet`), configure that product directly and skip `VeyraSDK` entirely.

### `VeyraSoftPOS` (merchant features)

```swift
VeyraSoftPOS.configure(configuration)          // standalone; combined apps configure via VeyraSDK
let merchant = VeyraSoftPOS.shared.merchant
```

**Members:**

| Member | Description |
|--------|-------------|
| `configure(_:)` | Configure the SDK. Call once, before any service use (subsequent calls reconfigure). |
| `shared` | The singleton. |
| `merchant` | Merchant lifecycle — registration, status, activate/deactivate, profile update, banks, stored merchant, and `onMerchantStatusChanged` (the SDK watches the merchant's backend status for you). |
| `tap` | Contactless tap acceptance — the customer's Android Veyra wallet taps this iPhone. |
| `payments` | QR payments — create/poll a get-paid QR (merchant-presented) and inspect/charge a customer QR (consumer-presented). |
| `transactions` | Transaction queries — local history, receipts, status polling — and the two deferred-answer observers (`onTransactionResolved`, `onCreditConfirmation`). |

### `VeyraWallet` (wallet features)

```swift
VeyraWallet.configure(configuration)           // standalone; combined apps configure via VeyraSDK
let tokenisation = VeyraWallet.shared.tokenisation
```

**Members:**

| Member | Description |
|--------|-------------|
| `configure(_:)` | Configure the SDK. Call once, before any service use (subsequent calls reconfigure). |
| `shared` | The singleton. |
| `tokenisation` | The wallet service — bank lookup, eligibility, digitise, activation, cards, payments, history, receipts. |
| `paymentApplicationInstanceID()` | This install's SDK-generated `payment_application_instance_id` (`VYRA` + 32 hex chars): minted on first use, persisted install-scoped (never backed up), new on reinstall. Read-only. |

---

## Configuration

### `VeyraSoftPOSConfiguration`

> **Breaking change:** the initializer now requires a `paymentAppProviderID` — the globally
> unique identifier issued to your organisation at onboarding, the same value your wallet
> configuration carries. The gateway links every merchant you register to it and resolves the
> acquirer id and MCC from it, so `acquirerID` no longer exists anywhere on the SoftPOS
> surface: not here, and not on the registration/update models.

```swift
let softposConfig = VeyraSoftPOSConfiguration(
    environment: .test,
    paymentAppProviderID: "your-payment-app-provider-id",
    clientID: "your-client-id",
    clientSecret: "your-client-secret"
)
```

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `environment` | **Mandatory** | `.test` or `.live`. Endpoints resolve from the SDK's defaults — no URLs to supply. |
| `paymentAppProviderID` | **Mandatory** | Your payment app provider id, issued at onboarding (the same identifier as the wallet configuration's). Sent on merchant registration/update; the gateway resolves your acquirer id and MCC from it. |
| `clientID` / `clientSecret` | **Mandatory** | OAuth client credentials. |

### `VeyraWalletConfiguration`

```swift
let walletConfig = VeyraWalletConfiguration(
    environment: .test,
    clientID: "your-client-id",
    clientSecret: "your-client-secret",
    paymentAppProviderID: "your-provider-id",
    tokenRequestorID: "50100000001",
    appVersion: "1.2.0",
    appleTeamID: "YOURTEAMID1",            // your Apple Developer Team ID
    allowedAcquirerIDs: ["ACQ001"],
    allowedMerchantIDs: ["MERCHANT01"],
    allowedCountryCodes: ["0566"],
    allowedMCCs: ["5411"]
)
```

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `environment` | **Mandatory** | `.test` or `.live`. Endpoints resolve from the SDK's defaults. |
| `clientID` / `clientSecret` | **Mandatory** | OAuth client credentials. |
| `paymentAppProviderID` | **Mandatory for wallet operations** | Your payment-app provider identifier (eligibility/digitise fail without it). |
| `tokenRequestorID` | **Mandatory for wallet operations** | Scheme-assigned token requestor ID. |
| `appleTeamID` | **Mandatory** | Your app's Apple Developer Team ID (e.g. `"ABCDE12345"`). Together with the bundle ID it forms the App Attest app ID (`teamID.bundleID`) that device attestation binds to and the backend verifies — it attests **your** app, so this is your team, not Veyra's. Digitise fails fast if missing. |
| `bundleID` | Optional | Override for the app's bundle ID (the attestation binding suffix). Normally leave `nil` — auto-detected from `Bundle.main`. |
| `appVersion` | Optional | App version reported during digitise. Default `"1.0.0"`. |
| `allowedAcquirerIDs` / `allowedMerchantIDs` / `allowedCountryCodes` / `allowedMCCs` | Optional | Provision-context allow-lists. Country codes are ISO 3166-1 numeric, 4-digit zero-padded (`"0566"` Nigeria) — never alpha codes. |

> There is **no** `paymentApplicationInstanceID` parameter — the SDK mints and persists an install-scoped one and sends it on every eligibility/digitise request; read it via `VeyraWallet.shared.paymentApplicationInstanceID()`. A restricted provision-context dimension that a payment then falls outside of is declined by the server.

### `Environment`

One shared enum for both products (nested `Environment` on each configuration).

| Value | Description |
|-------|-------------|
| `.test` | Test / staging servers. OAuth credentials required. |
| `.live` | Production servers. OAuth credentials required. |

Server hosts and endpoint paths are resolved by the SDK from the environment — you never supply URLs.

### Device type

**Detected, not configured** — the SDK reports `TABLET` on iPad and `MOBILE` otherwise.
There is no configuration parameter for it.

---

## Exclusive mode (combined apps)

A combined app is always in exactly one mode: **none**, **receiving** (SoftPOS) or **paying** (Wallet). The SDK manages this for you:

- **Claims are automatic.** The SDK claims a mode at the point of use — starting a tap session claims receiving, executing a wallet payment claims paying — and releases it when the session ends or the payment completes. Backgrounding the app drops it to inert. There is no mode API to call and no `.onAppear`/`.onDisappear` choreography; `currentMode` is available read-only for UI state.
- **Starts inert, never persisted.** The mode derives from the foreground screen; the app always starts with no mode active — even after being killed mid-payment.
- **Atomic.** The outgoing capability is fully torn down before the incoming one arms. A merely-armed (untapped) tap payment is cancelled automatically on a switch; a genuinely mid-flight payment refuses the switch instead.

**Cross-mode refusals.** If a tap session is armed while a wallet payment is genuinely mid-flight (or vice versa), the claim is refused — `TapPaymentSession.start()` throws `VeyraSoftPOSError.tapRefused`. Treat it as "finish or cancel the current payment first" and prompt the user. **This never occurs in a standalone single-product app.**

---

## SoftPOS — accepting payments

Service accessors: `VeyraSoftPOS.shared.merchant`, `.tap`, `.payments`, `.transactions`. All async methods throw `VeyraSoftPOSError` and deliver events on the main queue.

### Merchant registration & profile

A device must have a **registered, active merchant** before it can accept payments. Registration persists the merchant on the device (SDK-owned storage, cleared on uninstall); the backend assigns the merchant ID, terminal ID and category code.

---

#### `merchant.register`

Register the merchant on this device. Personal merchants require a BVN; business merchants require a CAC number — and may supply a BVN too (the account holder behind a business has one). All other fields are mandatory for both, except `walletAccountID`. There is no acquirer id: the gateway resolves it from your payment app provider and returns it on the response.

```swift
let result = try await VeyraSoftPOS.shared.merchant.register(
    MerchantRegistration(
        merchantType: .personal,           // or .business
        merchantName: "Ada's Store",
        emailAddress: "ada@example.com",
        phoneNumber: "+2348012345678",
        addressLine1: "12 Marina Road",
        city: "Lagos", state: "Lagos",
        countryCode: "0566",               // ISO 3166-1 numeric, 4 digits
        bvn: "12345678901",                // required for .personal; optional for .business
        cacNumber: nil,                    // .business only
        accountNumber: "1234567890",       // settlement NUBAN account
        institutionCode: "000000",         // from merchant.banks()
        walletAccountID: nil               // optional
    )
)
if result.success {
    // SDK persisted the merchant (backend-assigned fields win); unlock Get paid
}
```

`MerchantRegistrationResult`: `success: Bool`, `merchantID: String?`, `terminalID: String?`, `merchantStatus: String?`, `message: String?`. Validation problems come back as `success = false` with a message — nothing throws.

---

#### `merchant.banks`

Fetch the NUBAN settlement banks for the registration/update bank picker.

```swift
let banks: [SettlementBank] = try await VeyraSoftPOS.shared.merchant.banks()
// SettlementBank: slug, name, institutionCode
```

Pass the chosen bank's `institutionCode` to registration.

---

#### Merchant status — `merchant.status` / `activate` / `deactivate`

| Member | Description |
|-----|-------------|
| `merchant.isRegistered: Bool` | `true` when a complete merchant (ID, terminal, name, acquirer, MCC, country) is stored on this device. Gate your Get-paid entry on it. |
| `merchant.stored: StoredMerchant?` | The persisted merchant, or `nil`. |
| `merchant.status(merchantID:)` | Current backend status → `MerchantStatus(merchantID, status)` (e.g. `"ACTIVE"`, `"DEACTIVATED"`); refreshes the stored merchant's status. |
| `merchant.activate(merchantID:)` / `deactivate(merchantID:)` | Backend activate/deactivate → `MerchantStatus`. |
| `merchant.clearStored()` | Clear the stored merchant (logout / re-registration). |

Payments are refused for inactive merchants — call `status(merchantID:)` at the activation moment.

---

#### `merchant.update`

Update the merchant profile (terminal ID, MCC and the gateway-resolved acquirer id are preserved; the response re-states them and the SDK refreshes its stored copy). All parameters are required except `addressLine2`, `walletAccountID` and `bvn`.

```swift
let status = try await VeyraSoftPOS.shared.merchant.update(
    merchantID: merchantID,
    MerchantUpdate(merchantName: "Ada's Store", emailAddress: "ada@example.com",
                   phoneNumber: "+2348012345678", addressLine1: "12 Marina Road",
                   city: "Lagos", state: "Lagos", countryCode: "0566",
                   accountNumber: "1234567890", institutionCode: "000000")
)
```

---

### Tap acceptance

#### `tap.session`

Arm the reader for one sale and wait for the customer's tap. **Non-terminal events keep the reader armed** — mirror a physical terminal: an unsupported card or lost contact shows a transient hint on the same waiting screen; only real outcomes (approved / declined / pending / failed) end the payment.

```swift
let session = VeyraSoftPOS.shared.tap.session(amountMinorUnits: 32500) { event in
    switch event {
    case .cardDetected:
        // customer's phone connected — "hold steady"
        state = .dialogue
    case .unsupportedTarget:
        // stays armed — transient hint, keep waiting screen up
        hint = "Card not supported — ask for their Veyra wallet and try again"
    case .cardContactLost:
        // the customer moved their phone mid-read — "hold steady", keep waiting
        hint = "Contact lost — hold the phones together"
    case .cardReadingComplete:
        // the card conversation is over; nothing talks to it after this
        hint = "Card read — you can take the phone away"
    case .sendingRequestOnline:
        hint = "Contacting the bank…"
    case .receivingOnlineResponse:
        hint = "Bank responded — finishing up…"
    case .ended(let outcome):
        // reader session ended without a card — typed, so the switch is compiler-checked:
        // .cancelled (merchant dismissed the sheet — not an error), .timeout ("no card
        // presented — try again"), .unavailable (this device cannot accept taps), .error
        if outcome != .cancelled { state = .failed("Reader ended (\(outcome.rawValue)) — try again") }
    case .result(let result):
        // terminal outcome: result.status APPROVED / DECLINED / PENDING / FAILED
        lastPaymentReference = result.reference   // for the receipt afterwards
        state = .result(result)
    }
}
do {
    try session.start()      // arms the reader (claims receiving mode at the point of use)
} catch {
    // VeyraSoftPOSError.tapRefused — a wallet payment is mid-flight; finish it first
}
// Always tear down when the screen leaves:
session.cancel()
```

`session(amountMinorUnits:currencyCode:onEvent:)` — `currencyCode` is ISO 4217 numeric (`Int32`, default `566`). Create one session per waiting screen; always `cancel()` on leave. `TapPaymentResult`: `status` (`"APPROVED"` / `"DECLINED"` / `"PENDING"` / `"FAILED"`), `reference` (pass to `transactions.receipt(forReference:)`), `pan`, `cardholderName` (EMV tag `5F20` as the card presented it), `errorMessage`, plus `creditTransactionID` + `isCreditConfirmationSupported` on an approved sale — the cue to show the "confirming credit" wait and flip it from `transactions.onCreditConfirmation`.

**The four progress events are hints, not outcomes.** `cardContactLost` says the customer's phone left the field while the card was being read; the interrupted attempt still reports its own `result`, and the reader stays armed for a fresh tap. `cardReadingComplete`, `sendingRequestOnline` and `receivingOnlineResponse` mark the online window — nothing talks to the card after `cardReadingComplete`, so that is the moment to tell the merchant the tap is over. Use them for copy only; never treat one as the end of the payment.

---

### Get paid by QR (merchant-presented)

The merchant keys the amount, the SDK creates a **gateway-signed payment context**, and your app renders the returned payload as a QR for the customer's wallet to scan. Poll the context until it settles.

#### `payments.createContext`

| Parameter | Required | Description |
|-----------|----------|-------------|
| `merchantID` | **Mandatory** | Your registered merchant ID. |
| `amountMinorUnits` | **Mandatory** | Sale amount in minor units. |
| `currency` | **Mandatory** | ISO 4217 numeric (e.g. `"566"`; leading zeros accepted). |
| `onExpired` | Optional | Fired **once, on the main thread**, when the QR reaches its expiry — blank or replace the code so it can't be scanned once lapsed (a dimmed QR is still machine-readable). A new create supersedes the watch; `cancelQrExpiry()` stops it. |

Returns `PaymentContextQR`: `txRef` (poll key), `mpmPayload` (**render this string verbatim as the QR**), `expiry` (ISO-8601), `kid`. On failure the call throws.

#### `contextStatus`

Poll `contextStatus(txRef:)` on a short interval (the sample uses 2.5 s). States: `PENDING` (QR live) → `IN_FLIGHT` (wallet push settling) → `APPROVED` / `DECLINED` (settled — `responseCode` carries the rail outcome) or `EXPIRED`. Convenience: `isSettled` (`APPROVED || DECLINED`), `isApproved`. On settlement the payment is also recorded in the merchant's local history under the same `txRef`, so receipts work like any other rail.

```swift
let context = try await VeyraSoftPOS.shared.payments.createContext(
    merchantID: merchantID,
    amountMinorUnits: amount,
    currency: "566",
    onExpired: { qrState = .failed("This payment code has expired — start a new payment") },
    merchantOrderID: "ORDER-42"        // optional: YOUR order id — never a lookup key
)
// render context.mpmPayload verbatim as the QR, then poll:
while !Task.isCancelled {
    try await Task.sleep(nanoseconds: 2_500_000_000)
    guard let status = try? await VeyraSoftPOS.shared.payments.contextStatus(txRef: context.txRef) else { continue }
    if status.isSettled {
        VeyraSoftPOS.shared.payments.cancelQrExpiry()
        qrState = .settled(approved: status.isApproved, responseCode: status.responseCode)
        break
    }
    if status.state == "EXPIRED" { qrState = .expired; break }
}
```

---

### Charge a customer QR (consumer-presented)

The customer shows a payment QR from their Veyra wallet; the merchant scans it, **confirms the QR's own amount** (the amount is bound inside the QR's cryptogram — it is never keyed on the merchant side), and charges.

#### `payments.inspectCustomerQr`

Decode and validate a scanned payload. **A throw means "not a payment QR"** — show a transient hint and stay armed for another scan; it is not a terminal failure.

Returns `ScannedCustomerQr`: `maskedCard` (last 4 for display), `amountMinorUnits` (the QR's own amount — confirm, never re-key), `currencyNumeric`, `cardholderName` (the paying card's display name, e.g. `AFRIGO ****1234` — the same value a tap presents; **display only**, it rides outside the QR's cryptogram, so never branch a payment decision on it; `nil` when the QR carries none).

#### `payments.chargeCustomerQr`

Charge the confirmed QR synchronously over the standard payment rail. A tampered payload or altered amount declines at the server.

```swift
do {
    let scanned = try await VeyraSoftPOS.shared.payments.inspectCustomerQr(payload)
    confirm(scanned.amountMinorUnits, card: scanned.maskedCard)   // merchant confirms the QR's amount
    let outcome = try await VeyraSoftPOS.shared.payments.chargeCustomerQr(
        scanned,
        merchantOrderID: "ORDER-42"                // optional: YOUR order id — never a lookup key
    )
    lastPaymentReference = outcome.reference       // SDK-MINTED reference — use for the receipt
    showResult(approved: outcome.approved, code: outcome.responseCode)
} catch {
    showHint("Not a payment code — try again")     // stay armed for another scan
}
```

`CustomerQrChargeOutcome`: `approved: Bool`, `responseCode`, `transactionID`, `reference`, plus `creditTransactionID` + `isCreditConfirmationSupported` (populated on approved charges — the cue to wait for credit confirmation, see `transactions.creditConfirmation`).

> **Who mints the reference.** `reference` is minted by the **SDK** (`{terminalId}-YYYYMMDDHHmmssSSS`) so the gateway can guarantee it is unique per merchant — your app does not supply it, and it is the key for receipts, status lookups and credit confirmation. `merchantOrderID` is the field for **your** identifier: optional, echoed back, never validated for uniqueness and never used as a key, so the same value may sit on two attempts of one sale — which is exactly what links a retry to its order. Both `createContext` and `chargeCustomerQr` take it; the tap session does not.

---

### Merchant transactions & receipts

The SDK records every payment it takes — tap, get-paid QR and customer-QR charge — locally at its terminal outcome, so history needs no backend round trip.

#### `transactions.history`

```swift
let transactions = try await VeyraSoftPOS.shared.transactions.history(limit: 50)
// MerchantTransaction: reference, rail ("TAP" / "QR_MPM" / "QR_CPM"),
// railLabel ("Tap" / "QR" / "Scan"), amountMinorUnits,
// currencyNumeric, status ("APPROVED"/"DECLINED"/"PENDING"/"FAILED"), responseCode,
// transactionTime, transactionID, maskedTokenLast4, transactionHash,
// merchantOrderID (your own order/basket id as supplied on the charge — your reconciliation
// key back to your POS/till, nil on sales that carried none; display only, never a lookup
// key: receipts and status refreshes key off reference),
// cardholderName (EMV 5F20 as the card presented it — nil on QR-MPM),
// creditTransactionID + isCreditConfirmationSupported (the merchant-bank credit's identifier
// and whether that bank can confirm it — populated on approved sales only),
// creditConfirmationStatus ("RECEIVED" once the merchant's bank confirmed the funds; nil
// while unconfirmed — show nothing, never "not received")
```

Each row records the rail that actually took the payment. Display `railLabel` — the SDK derives it
so the same rail reads identically on iOS, Android and React Native, and an unrecognised rail code
passes through unchanged rather than being shown as some other rail. Branch on `rail`, not on the
label.

`PENDING` means the outcome is not yet known (the SDK keeps polling and updates the stored row); `FAILED` means the payment never reached the server. Hide receipt affordances while a row is `PENDING`.

**How the SDK waits for a `PENDING` row.** You do not have to poll, schedule anything, or keep a screen open — the SDK asks on its own, with **exponential backoff**: the first re-checks come within seconds (most payments settle at once) and the interval doubles to a steady state of roughly **once an hour**. It keeps that up for **30 days** from the transaction date, and then stops asking.

**Stopping is not an outcome.** When the 30 days elapse the row keeps whatever status it has — still `PENDING`, which is still true — and the SDK simply takes it off the poll list. It never writes `FAILED`, `DECLINED` or any other verdict of its own: only the backend decides what a payment was. So treat a long-`PENDING` row as *unresolved*, not as failed, however old it is.

**Let the merchant ask on demand — `transactions.refreshStatus(reference:)`.** The SDK polls a pending transaction for you with **exponential backoff**, and **stops after 30 days**. Polling never invents an outcome — a row that ages out simply stops being asked about and stays `PENDING`. Expose **`refreshStatus`** in your UI so the merchant can ask on demand, which is the route for anything still pending after the window closes.

A failed poll — device offline, gateway unreachable, an unreadable answer — changes nothing at all: the SDK backs off and asks again, and the row is left exactly as it was. "We could not reach the server" is never recorded as "the payment failed".

#### `transactions.refreshStatus(reference:)`

```swift
// Returns the updated stored row, or nil if this device has no such reference.
let updated = try await VeyraSoftPOS.shared.transactions.refreshStatus(reference: reference)
```

The on-demand counterpart to `history(limit:)`, which only reads what the device already knows. It
asks the gateway about that one transaction now and writes the answer into the same local store the
background sweep writes, so an on-demand check and a background check can never disagree.

- **Show it only while the row is `PENDING`.** A settled row has nothing to ask, and offering the
  action implies the outcome might still change. Hide it the moment the row is terminal.
- **It works past the 30-day window**, and on a row the sweep never had on its list — that is what it
  is for.
- **It is not a way to force an outcome.** A payment that is still unsettled answers `PENDING` again.
  Show a brief "still processing" note; do not retry in a loop.
- **A failed call throws and changes nothing** — `VeyraSoftPOSError.noNetworkConnection` when the
  device is offline. Show the error and leave the row pending.
- **No SDK-side throttle.** Disable your button while a call is in flight, as the sample does.

Distinct from `transactions.status(merchantID:merchantTransactionReference:transactionDate:)`, which
remains the **raw** query: that one returns whatever the gateway said and writes nothing to the
store, for developers who want the unfiltered answer. `refreshStatus` is the one that updates the row
your history screen renders.

**Platform note — the sweep is app-scoped.** It starts when the SDK is configured and runs for as long as the app process is alive, across every in-app navigation and whatever screen is up; no screen starts or stops it. iOS suspends timers when the OS suspends the app, so there is **no OS background execution** — the sweep pauses with the app and resumes on foreground. That costs time, never an answer: every result is written to the store, so a row resolved while you were elsewhere is simply there when you look.

#### `transactions.receipt(forReference:)`

Build the receipt for one transaction, including a **receipt QR the customer's Veyra wallet can scan** to store its own copy.

```swift
guard let receipt = try await VeyraSoftPOS.shared.transactions.receipt(forReference: reference) else { return }
// receipt.qrPayload is the JSON to render as a QR yourself (e.g. CIFilter, correction level "L",
// rendered large — ~300pt — so a camera at arm's length can decode it)
```

The receipt returns the payload string (`qrPayload`) for you to render, and carries `transactionHash` — the join key the customer wallet verifies against before storing the receipt.

#### `transactions.status`

Backend status query by reference: `status(merchantID:merchantTransactionReference:transactionDate:)` (date `YYYY-MM-DD`) → `[TransactionStatus]` (`responseCode`, `amount`, `transactionID`, …). Use the local history for everyday listing; this is for reconciliation against the backend.

#### `transactions.creditConfirmation`

Beneficiary credit confirmation: has the merchant's bank actually **received the funds** of an approved sale? Settlement confirmation only — it never changes the sale's payment outcome.

```swift
let confirmation = try await VeyraSoftPOS.shared.transactions.creditConfirmation(
    merchantID: merchantID,
    creditTransactionID: tx.creditTransactionID!,   // from the history row / payment response
    amountMinorUnits: tx.amountMinorUnits           // cross-checked by the merchant's bank
)
// confirmation.status: "RECEIVED" (terminal — funds are in the merchant's account; amountMinorUnits,
// creditedAt and bankReference describe the credit) or "UNABLE_TO_CONFIRM" (not confirmed yet — ask
// again later; the cause rides in message). Treat any unrecognised value like "UNABLE_TO_CONFIRM".
```

**The SDK owns the polling on every platform, app-scoped — never screen-scoped.** On iOS the SDK's background sweep starts at configure time and keeps asking the merchant's bank (exponential backoff, up to 30 days) for as long as the app is alive, whatever screen is up, persisting each answer onto the sale's stored history row (`creditConfirmationStatus`). iOS suspends timers when the app is backgrounded — that is expected: the sweep keeps running across in-app navigation and resumes when the app returns to the foreground; there is no OS background execution. Apps should therefore **render the store, not poll**: this manual fetch remains for an on-demand check (stop on `"RECEIVED"`; treat `"UNABLE_TO_CONFIRM"` as "not confirmed yet", never as "not received").

**Recommended pattern — the result screen renders the stored row** (see the sample's `GetPaidView`): when an approved sale says the merchant's bank supports confirmation, show "Confirming credit with merchant bank…" and re-read the sale's row from `transactions.history(...)` every few seconds while the screen is visible, flipping the line to "Funds received by merchant bank" when the SDK's sweep stamps `"RECEIVED"` (or to the could-not-confirm copy only on the stored final 30-day give-up). Leaving the screen stops only the rendering — the SDK keeps polling, and the history/transaction views show the updated state on return. Where the supported flag comes from differs by rail:

- **Customer-QR charge (CPM):** `chargeCustomerQr`'s outcome carries `creditTransactionID` + `isCreditConfirmationSupported` directly — show the waiting line at once.
- **Merchant-presented QR (MPM):** the context settle carries no credit fields (the contexts endpoint never does); the SDK learns them from the transaction-status rail moments after the settle, so just watch the stored row until `isCreditConfirmationSupported` turns up `true`.

Never show "could not be confirmed" from anything but the stored final give-up: a mid-window miss is never written to the row, so the row never lies.

#### `transactions.refreshCreditConfirmation(reference:)`

The SDK polls for beneficiary credit confirmation with **exponential backoff** and **stops after 30
days**, finalising the row as `"UNABLE_TO_CONFIRM"` — which means "we stopped asking", never "the
funds were not received". Expose **`refreshCreditConfirmation`** in your UI so the merchant can ask on
demand; it works after the window closes, and a later `"RECEIVED"` replaces the give-up state.

**Check `isCreditConfirmationSupported` on the transaction first.** Not every merchant's bank is on
this rail. `true` means the SDK is polling and you may offer the manual check; `false`/`nil` means
there is nothing to ask — do not call it, and show no credit UI for that transaction. Offer the
action only while

```swift
tx.status == "APPROVED"
    && tx.isCreditConfirmationSupported == true
    && tx.creditConfirmationStatus != "RECEIVED"
```

```swift
let updated = try await VeyraSoftPOS.shared.transactions
    .refreshCreditConfirmation(reference: tx.reference)   // MerchantTransaction?, nil if unknown here
```

- **A row outside that predicate is a no-op**, not an error: no request is made and the unchanged row
  comes back. The gateway refuses the same cases, so the SDK does not spend a round trip being told.
- **It works past the 30-day window**, including on a row already stamped `"UNABLE_TO_CONFIRM"` —
  that is the case it exists for. Nothing ever replaces `"RECEIVED"`.
- **Only a confirmation is written.** An answer of `"UNABLE_TO_CONFIRM"`, or one this SDK version does
  not recognise, leaves the row exactly as it was — "not confirmed **yet**", never "not received".
- **Settlement only.** Nothing on this path can change `status`, `responseCode` or
  `responseStatusReason`.
- **This is the one that writes the store**, unlike `transactions.creditConfirmation(...)` above,
  which stays as the raw fetch and persists nothing — a `"RECEIVED"` learned that way is gone on the
  next render. It also fires `transactions.onCreditConfirmation`, exactly as the background sweep
  does, because both go through the same write.
- **A failed call throws and changes nothing** — `VeyraSoftPOSError.noNetworkConnection` when the
  device is offline. Show the error and leave the credit line reading "not confirmed yet".
- **No SDK-side throttle.** Disable your button while a call is in flight, as the sample does.

**Holding the result screen (your app's decision, never the SDK's).** A terminal outcome is a destination, not a notification. The sample holds its result view for **60 seconds** — approved, declined, pending and failed alike — with **Done** visible for the whole hold and dismissing immediately; when the hold expires the view returns Home on its own. The single exception is an approved sale whose `isCreditConfirmationSupported` is (or later becomes) `true`: **cancel** the hold so the view cannot vanish while the merchant's bank is still being asked, show "Confirming credit with merchant bank…", and start a **fresh 60 seconds** once the confirmation is on screen (the merchant-QR rail learns the flag moments after the settle, so the cancel can happen while the hold is already running). Non-terminal tap events (`.unsupportedTarget`, lost contact) are not results — they hold nothing and dismiss nothing: the waiting screen stays up, armed for a re-tap. How long a result stays up and what dismisses it are app concerns end to end — the SDK has no concept of a screen and supplies no duration, and dismissing a view never stops its app-scoped credit polling.

---

## Wallet — making payments

Everything hangs off `VeyraWallet.shared.tokenisation`; methods are `async throws` and throw `VeyraWalletError` — see [Response codes](#response-codes--error-handling).

### Add a card (digitisation)

Flow: `banks` → `verifyAccount` → `digitise`. On success the SDK receives, decrypts and stores the payment material on-device — the card can pay immediately (`APPROVED`) or after activation (`APPROVE_REQUIRE_AUTH`).

---

#### `tokenisation.banks`

Fetch the supported NUBAN banks, optionally filtered by account number. Call as soon as the user finishes entering their account number so the list is ready for the bank picker.

| Parameter | Required | Description |
|-----------|----------|-------------|
| `accountNumber` | No | 10-digit NUBAN. When supplied, returns only banks linked to that account; `nil`/blank returns all supported banks (use as the "can't find my bank" fallback). |

```swift
let banks = try await VeyraWallet.shared.tokenisation.banks(accountNumber: "1234567890")
```

---

#### `tokenisation.verifyAccount`

Check whether an account can be tokenised before digitising. Eligible when `responseCode == "APPROVED"`.

```swift
let response = try await VeyraWallet.shared.tokenisation.verifyAccount(
    accountNumber: "1234567890",
    institutionCode: "000000",
    walletAccountID: "ada@example.com",
    accountHolderName: "Ada Obi",
    accountNumberSource: "MANUAL"
)
if response.isApproved { proceedToDigitise() }
```

`walletAccountID` is the customer's identifier with **your** wallet service — email, phone or GUID. The SDK derives a hash from it; it is not sent raw. It must match the value registered with your wallet provider.

`VerifyAccountResponse`: `responseCode` (`"APPROVED"` = eligible), `message` (+ convenience `isApproved`).

---

#### `tokenisation.digitise`

Tokenise the account: the SDK attests the device, sends the request, and on success decrypts and stores the token material on-device. The **tokenisation recommendation is your app's business decision** — the SDK never assumes one.

```swift
let r = try await VeyraWallet.shared.tokenisation.digitise(
    accountNumber: accountNumber,
    institutionCode: institutionCode,
    walletAccountID: "ada@example.com",
    accountHolderName: "Ada Obi",
    emailAddress: "ada@example.com",
    recommendation: .approve,                    // your app's risk decision — required
    mobileNumber: mobileNumber,
    bvn: bvn,
    accountHolderAddress: address,
    accountNumberSource: "MANUAL",
    consumerIdentifier: UUID().uuidString,
    deviceScore: .trusted,
    accountScore: .highlyTrusted,
    recommendationReasons: [.goodActivityHistory],
    bankName: selectedBankName                   // shown on the stored card
)
if r.isApproved { showCardAdded() }
else if r.requiresActivation { showActivationMethods(r.tokenUniqueReference, r.activationMethods) }
else { showError(r.message ?? "Could not add card") }
```

`DigitiseResult`: `tokenUniqueReference`, `responseCode`, `message`, `activationMethods` (`medium` + masked `contact`), `tokenStored` (provisioning material decrypted and stored), `isApproved`, `requiresActivation`.

---

### Activation

When digitise returns `APPROVE_REQUIRE_AUTH`, the response carries the issuer's **activation methods**. Branch on each entry's `medium`:

| Medium | UI | Then |
|---|---|---|
| `MASKED_EMAIL` / `MASKED_MOBILE_PHONE` | Show the masked contact, let the user pick | `requestActivationCode` → OTP entry → `activate` |
| `CALL_CENTER_PHONE` / `AUTOMATED_CALL_CENTER_PHONE` | Show the phone number + "Call now" | `observeActivation` while they call |
| `WEBSITE` | Show the domain + "Open website" | `observeActivation` |
| `MOBILE_APPLICATION` | "Open your bank's app" | `observeActivation` |

---

#### `requestActivationCode`

OTP delivery for the `MASKED_EMAIL` / `MASKED_MOBILE_PHONE` methods.

| Parameter | Required | Description |
|-----------|----------|-------------|
| `tokenUniqueReference` | **Mandatory** | The card being activated. |
| `method` | **Mandatory** | The chosen medium: `.maskedEmail` / `.maskedMobilePhone`. |
| `reason` | **Mandatory** (default `.addCard`) | `.addCard`, `.checkAccountEligibility` or `.other`. |

```swift
let response = try await VeyraWallet.shared.tokenisation.requestActivationCode(
    tokenUniqueReference: ref, method: .maskedMobilePhone, reason: .addCard)
```

`ActivationCodeResponse`: `tokenUniqueReference`, `expirationDateTime` (ISO-8601 — drive your countdown from it), `status` (`SUCCESS` / `FAILURE`), `message`, `failureCode` (typed `ActivationFailureCode`, nil on success) + `failureCodeRaw`. **Check `status` even inside a successful result**, and branch on `failureCode`, never on `message`: `.codeRequestRateLimited` means disable "resend" until later but keep the flow open; `.activationLocked` is terminal — end the flow and point the user at their issuer. Codes are limited-attempt and rate-limited — see [Response codes](#response-codes--error-handling).

#### `activate`

Submit the code the customer received. Success when `status == "SUCCESS"`.

```swift
let response = try await VeyraWallet.shared.tokenisation.activate(
    tokenUniqueReference: ref, activationCode: code)
switch response.failureCode {
case nil: navigateToWallet()                       // status == "SUCCESS"
case .codeInvalid: showError("Wrong code — \(response.attemptsRemaining ?? 0) attempts left")
case .maxAttemptsExceeded:
    // The cycle is closed. On .must delete the token and restart the add-card flow;
    // on .may, deletion is advisory.
    endActivationCycle(response.recommendDelete)
case .activationLocked: showLockedTerminal()       // hide both retry and resend
case .codeExpired: offerResend()
default: showError(response.message ?? "Activation failed")
}
```

`ActivateResponse` failure fields (all nil on success): `failureCode` — typed `ActivationFailureCode` (`.tokenNotFound`, `.tokenNotActivatable`, `.activationLocked`, `.noPendingActivation`, `.codeExpired`, `.codeInvalid`, `.maxAttemptsExceeded`, `.invalidRequest`, `.activationFailed`, or `.unknown(raw:)` for a code newer than this SDK); `attemptsRemaining` — code attempts left where a cap applies (0 when exhausted/locked); `recommendDelete` — `.must` / `.may` after an exhausted cycle (delete the dead token rather than leaving it in the card list), nil otherwise (raw values in `failureCodeRaw` / `recommendDeleteRaw`).

#### `observeActivation` (+ pause / resume / stop)

For the out-of-band methods (call centre / website / issuer app) the activation happens elsewhere — observe the token until it activates. The SDK polls every 10 s for up to 5 minutes; callbacks arrive on the main thread; observing the same token again replaces the previous observer.

| Parameter | Description |
|-----------|-------------|
| `tokenUniqueReference` | The card being activated. |
| `onActivated` | Fires exactly once when the token becomes active — navigate to the wallet. |
| `onTimeout` | After 5 minutes without activation — show a fallback message (the SDK keeps checking in the background thereafter). |
| `onError` | Optional — each failed check (polling continues). |

Wire the lifecycle: `pauseActivationObserver(ref)` when the screen backgrounds, `resumeActivationObserver(ref)` on return (the timeout clock keeps running while paused — if it lapsed, `onTimeout` fires immediately), `stopActivationObserver(ref)` when the screen is dismissed.

```swift
try VeyraWallet.shared.tokenisation.observeActivation(
    tokenUniqueReference: ref,
    onActivated: { Task { await reload() } },
    onTimeout:   { hint = "Still pending — we'll keep checking" }
)
// scene background/foreground → pauseActivationObserver / resumeActivationObserver
// screen dismissed → stopActivationObserver
```

---

### Cards & tokens

#### `tokenisation.tokens`

The wallet's cards, from the SDK's local registry — no network call.

```swift
let cards = try await VeyraWallet.shared.tokenisation.tokens()   // [StoredCard]
let active = try await VeyraWallet.shared.tokenisation.activeToken
```

`StoredCard`: `tokenUniqueReference`, `panLastFour`, `maskedPAN`, `expiry` (`MM/YY`), `cardHolderName` (the card's display name — scheme label + masked last four, e.g. `AFRIGO ****1234`; not a person's name, and the same value the card presents in EMV tag `5F20`), `accountHolderName`, `bankName`, `status`, `requiresActivation`, `isActive`, `requiresOnline`.

**`requiresOnline`** — `true` when the card cannot pay until the wallet has been **online** to refresh it. Render the card greyed-out and non-tappable and prompt the user to connect; the flag derives fresh on every read and clears on its own once the SDK's automatic refresh succeeds. There is no manual "refresh keys" call — key management is entirely SDK-owned.

#### Handling card states in your UI

A card is not simply "there or not" — it can be awaiting activation, frozen for a refresh, or suspended server-side. Derive one display state per card, in this precedence order, every time you render the wallet:

| Precedence | State | How you observe it | UI treatment | What unblocks it |
|---|---|---|---|---|
| 1 | **Needs activation** | `card.requiresActivation` | Show the card with an **"Activate"** badge/button that launches the [activation flow](#activation). Pay actions hidden. | `activate` succeeding, or `observeActivation` firing `onActivated`. |
| 2 | **Requires online** | `card.requiresOnline == true` | **Grey the card out and make it non-tappable**; overlay a "Connect to the internet" hint; disable every pay affordance (scan-to-pay, show-QR buttons). | Nothing you call — the SDK refreshes the card itself the next time the device is online. Re-read the list and the flag has cleared. |
| 3 | **Inactive server-side** (suspended, expired) | `card.status` (e.g. `"SUSPENDED"`) — and a pay attempt refuses with `.tokenNotActive` | Grey the card out with an **"Unavailable — contact your bank"** indicator; disable pay affordances. Don't offer retry — the state is issuer-controlled. | A later automatic status sync seeing the card active again. |
| 4 | **Payable** | None of the above | Normal rendering; pay affordances enabled for the active card. | — |

Two rules make this robust:

- **Derive, don't cache.** Every state above is computed fresh on each read and clears itself — re-read the card list whenever your wallet screen (re)appears and after any payment attempt, rather than storing state.
- **Gate the affordances, not just the card face.** Disabling only the card image but leaving a "Scan to pay" button live produces the refusal errors at pay time; disable the actions too, and treat the typed refusals (`.onlineRequired` / `.tokenNotActive`) as the backstop, not the primary UX.

The sample's card stack + gating:

```swift
let cards = try await VeyraWallet.shared.tokenisation.tokens()

// Per-card rendering:
@ViewBuilder func cardFace(_ card: StoredCard) -> some View {
    if card.requiresActivation {                          // 1. needs activation
        CardView(card).overlay(alignment: .bottom) {
            Button("Activate") { activate(card) }
        }
    } else if card.requiresOnline {                       // 2. frozen until online
        CardView(card)
            .opacity(0.4)                                 // greyed out
            .allowsHitTesting(false)                      // non-tappable
            .overlay(Text("Connect to the internet to use this card"))
    } else if card.status.uppercased() == "SUSPENDED" {   // 3. suspended server-side
        CardView(card)
            .opacity(0.4)
            .allowsHitTesting(false)
            .overlay(Text("Card unavailable — contact your bank"))
    } else {
        CardView(card)                                    // 4. payable
    }
}

// Screen-level gating:
func activeCardBlocked(_ cards: [StoredCard]) -> Bool {
    guard let active = cards.first(where: { $0.isActive }) else { return true }
    return active.requiresOnline || active.status.uppercased() == "SUSPENDED"
}
// Re-derive on every appearance and scene-activation (statuses sync in the background):
.onAppear { Task { await reload() } }
.onChange(of: scenePhase) { if $0 == .active { Task { await reload() } } }
```

A deactivated card needs no rendering rule — the SDK removes it from the list entirely (the wipe happens automatically when a status sync sees `DEACTIVATED`).

#### `tokenisation.setActiveToken`

Select the card payments use (at most one card is active).

```swift
try await VeyraWallet.shared.tokenisation.setActiveToken(tokenUniqueReference)
```

**Tap-to-pay is Android-only** — on iOS the wallet pays by QR (Apple restricts card emulation).

#### `tokenisation.deactivate` / `delete` / `wipeAll`

| Method | Behaviour |
|---|---|
| `deactivate(ref)` | Deactivates on the backend, then wipes every on-device artefact for the card and promotes the next card to active. On failure nothing local changes. |
| `delete(ref)` | The user's "remove card" action: best-effort backend deactivate, then — always — the full local wipe and promotion. |
| `wipeAll()` | Wipe every card and all SDK-held data from this device (local only). |

#### `tokenStatus` · card status sync

`tokenStatus(tokenUniqueReference:)` returns the card's current backend status string (e.g. `"ACTIVE"`). You rarely need it: the SDK syncs each card's server status automatically (on scene-active and around payments) — a suspended card becomes non-payable until a later sync sees it active again, and a deactivated card is removed from the wallet. Reflect it in UI from `StoredCard.status` / payment refusals rather than polling yourself.

---

### Scan to pay (merchant QR)

The customer scans a merchant's get-paid QR: **inspect** (on-device verification) → confirm screen → **authenticate** (biometric) → **pay**.

#### `inspectScannedQr`

Synchronous, on-device verification of the scanned payload — gateway signature against the SDK's pinned keys, plus expiry. **Only a verified result may reach your confirm screen; every rejection must end the flow.**

```swift
switch try VeyraWallet.shared.tokenisation.inspectScannedQr(payload) {
case .verified(let payment): showConfirm(payment)            // VerifiedPayment
case .rejected(let reason, _): showRejected(reason)          // .malformed/.missingSignature/.unknownKey/.badSignature/.expired
}
```

The verified context carries `merchantName`, `merchantCity`, `amount` (display string), `amountMinorUnits`, `currencyNumeric`, `txRef`, `expiryEpochSeconds` — render these on the confirm screen; the customer never keys an amount.

#### Device authentication (CDCVM) — the SDK asks, you don't

**There is no authentication method to call.** `payScannedContext` and `showQrToPay` present the
system `LocalAuthentication` sheet themselves — Face ID or Touch ID, falling back to the device
passcode — before building the payment. You cannot build a QR payment flow that skips it, and you
cannot forget to sequence it.

The SDK composes the sheet's text from the payment it is about to make, so the gesture is visibly
bound to what it authorises: *"Pay ₦5,000.00 to Ada's Store"*. It asks **once per payment
attempt** — a retry, or regenerating an expired QR, asks again.

Three typed errors can be thrown, and they need different UI:

| Error | What happened | What to do |
|---|---|---|
| `VeyraWalletError.authenticationCancelled` | The customer dismissed the sheet | Stay put and let them try again — nothing was sent |
| `VeyraWalletError.authenticationFailed` | They tried and it did not succeed | Offer a retry |
| `VeyraWalletError.authenticationUnavailable` | This device has **no** enrolled biometry *and* **no** passcode | Send them to Settings; a retry can never succeed |

The sheet appears only **after** the card checks pass, so a card that is out of keys, over its limit
or not active is refused without spending the customer's gesture.

**Changing the wording or the language.** Set these once on `VeyraWalletConfiguration` — `{amount}`
and `{merchant}` are substituted:

```swift
VeyraWalletConfiguration(
    environment: .test,
    appleTeamID: "ABCDE12345",
    cdcvmAllowDeviceCredential: true,          // false = biometry only, no passcode fallback
    cdcvmPaySubtitle: "Send {amount} to {merchant}",
    cdcvmShowQrSubtitle: "Code for {amount}"
)
```

> iOS shows a **single** string in the sheet, so the *subtitle* is what the customer reads — it is
> the one carrying the merchant and amount. Overriding only a title has no visible effect here.

> **There is no tap-to-pay on iOS**, so unlike Android this is the only place CDCVM applies.

#### `payScannedContext`

Pay the verified context with the wallet's **active card**. The SDK presents the authentication
sheet itself first (above). Whatever the gateway states — approved, declined, failed or still pending — also lands in the card's history.

**Branch on `responseStatus`, not on `approved` or the response code.** The push is a synchronous call, but its *outcome* can still be unknown: the gateway answers `PENDING` when a hop below it timed out (`68`), errored (`06`/`96`) or is still settling (`09`). That is not a refusal — the SDK records the payment as unresolved and keeps polling it until the gateway states a final outcome, which then shows on the history row. `approved` is a convenience for the happy path only (`responseStatus == "APPROVED"`); it is `false` for a pending payment as well as a declined one.

```swift
let outcome = try await VeyraWallet.shared.tokenisation.payScannedContext(payment)
switch outcome.responseStatus?.uppercased() {
case "APPROVED": showApproved(outcome.message)
case "DECLINED", "FAILED": showDeclined(outcome.message, outcome.responseStatusReason)
// Absent or anything else: not yet known. Say so, and point at history —
// never show a refusal for a payment that may still settle.
default: showPending(outcome.responseCode)
}
// catch VeyraWalletError.onlineRequired — prompt to connect, stay on confirm screen
```

---

### Show QR to pay (customer-presented)

The customer keys nothing at the till: your app asks the amount first (the merchant states it) and renders a **dynamic payment QR** — the SDK handles the authentication with the amount cryptographically bound inside. Fully offline — the merchant's SoftPOS submits the payment; the outcome lands in history via reconciliation.

#### `showQrToPay` + `cancelQrExpiry`

| Parameter | Required | Description |
|-----------|----------|-------------|
| `amountMinorUnits` | **Mandatory** | The merchant-stated amount — bound into the QR's cryptogram; the merchant's scan charges exactly this or fails. |
| `onExpired` | Optional | Fired **once, on the main thread**, when the QR lapses — blank or replace the code (a dimmed QR is still scannable). A new render supersedes the watch; `cancelQrExpiry()` stops it (call on screen teardown). |

The SDK presents the authentication sheet itself — **one gesture per QR**; regenerating after expiry is a fresh payment attempt and asks again.

```swift
let qr = try await VeyraWallet.shared.tokenisation.showQrToPay(amountMinorUnits: amount) {
    expired = true       // blank the code
}
renderQr(qr.payload)
// .onDisappear: VeyraWallet.shared.tokenisation.cancelQrExpiry()
```

The result (`PaymentQr`): `payload` (**render as the QR**), `amountMinorUnits`, `currencyNumeric`, `expiresAtEpochMillis`, `transactionHash` — this render's unique hash. To show "paid ✓" on the customer's screen, poll while the QR is up: call `reconcilePendingTransactions`, then look in `transactionHistory` for the row whose `transactionHash` matches this QR's.

---

### History, receipts & maintenance

#### `tokenisation.transactionHistory`

The card's full local history across every rail (tap, scanned QR, shown QR), most recent first. No network call.

```swift
let history = try await VeyraWallet.shared.tokenisation
    .transactionHistory(tokenUniqueReference: ref, limit: 100)
```

`TransactionSummary` fields: `merchantName`, `amountInMinorUnit`, `transactionCurrencyCode` (4-digit ISO 4217, e.g. `"0566"`), `authorizationStatus` (`PENDING` / `APPROVED` / `DECLINED` / `FAILED`; `nil` on legacy rows — treat as indeterminate), `responseCode` (the outcome's code, e.g. `"00"`, `"51"` — verbatim from the rail that resolved the row; `nil` until resolved; quote this literal in support conversations), `responseStatusReason` (the outcome's stated cause, e.g. `"INSUFFICIENT_FUNDS"` — a plain string to display, never parse; `nil` until resolved), `entryMethod` (`"TAP"`, `"QR_GENERATED"` — showed a QR, `"QR_SCANNED"` — scanned a merchant QR; `nil` legacy — show nothing rather than guess), `merchantLocation`, `transactionHash` (join key to a receipt), `atEpochMillis`, `merchantTransactionReference`, `merchantId`, `merchantOrderID` (the merchant's own order/basket id for the sale — the id the merchant's systems know it by, so a customer can quote it at the counter; a scanned-QR row carries it from payment time, generated-QR rows learn it from the status poll, so `nil` on a still-open row means "not learned yet", not "no order id"; **display only, never a lookup key** — receipts and status refreshes still key off `transactionHash` / `merchantTransactionReference`), plus the five beneficiary-credit fields below.

##### `observeTransactionResolved` (wallet) — a `PENDING` payment reached its outcome

A wallet payment that gets no immediate answer is stored and polled by the SDK until the backend
settles it — seconds, or days. Unresolved rows are visible in history, so the customer can be
looking at the row at the moment it settles. This is how your app hears it without polling:

```swift
try VeyraWallet.shared.tokenisation.observeTransactionResolved { resolution in
    // resolution.transactionHash      — which payment (match your row on this)
    // resolution.tokenUniqueReference — the card that paid
    // resolution.status               — APPROVED / DECLINED / FAILED (never PENDING)
    // resolution.responseCode         — the wire literal, for receipts and support
    // resolution.reason               — e.g. INSUFFICIENT_FUNDS — display, never parse
    // resolution.amountMinorUnits, resolution.merchantName
}
```

**This is not the same channel as `VeyraSoftPOS.shared.transactions.onTransactionResolved`**, and
the two are not interchangeable: that one is the *merchant's* side of a payment and identifies a
sale by the reference the merchant's own app supplied — a value a wallet never sees. The wallet
keys on `transactionHash`.

Fires only on a genuine `PENDING` → final transition: a poll that leaves the row pending, and a
later write that backfills merchant details onto an already-final row, both wake nothing. Register
once at start-up, no replay (read the history when a screen appears), last registration wins,
delivered on the main thread. `stopObservingTransactionResolved()` clears it.

##### Merchant credit confirmation (wallet side)

Did the money actually reach the merchant's bank? The wallet asks the same question the merchant's own SDK asks about that sale, from the payer's side — **settlement confirmation only**, it never changes or restates the payment outcome.

**The SDK does the polling; your view renders the stored row.** Once a payment is approved, an app-scoped sweep started at `configure(_:)` asks the gateway on an exponential backoff for up to **30 days**, across every screen — no view starts or stops it. There is deliberately **no wallet callback** for this: the stored row is the whole surface. Read it when a transaction detail view appears, and re-read (`transactionHistory(...)`) every few seconds while it is up if you want the line to flip live, as the sample's `TransactionDetailView` does.

These three fields are the **eligibility contract**: they are how you decide whether to render a
credit line at all, and whether you may call `refreshCreditConfirmation` (below). They are not merely
a cue to wait.

| Field | What it means for you |
|---|---|
| `isCreditConfirmationSupported: Bool?` | **The gate.** `true` ⇒ the merchant's bank is on the confirmation rail, the SDK is polling, and you should render the credit line **and may offer the manual check**. `false`/`nil` ⇒ there is nothing to ask — render **no** credit UI for that transaction, and **do not call `refreshCreditConfirmation`**. |
| `creditConfirmationStatus: String?` | `nil` = no answer yet (with the gate `true`, that is the "confirming…" state) · `"RECEIVED"` = terminal, the funds are confirmed in the merchant's account · `"UNABLE_TO_CONFIRM"` = the 30-day sweep stopped asking. |
| `creditTransactionID: String?` | The credit leg's id (NIP session id inter-bank, batch reference intra-bank) — **what you quote to a bank** when the merchant says the money never arrived. Display/support only; never pass it back to the SDK, and render it only where the gate above is `true` — a bare id with no confirmation line reads as a promise. |
| `creditedAt: String?` | When the beneficiary bank posted the credit. `"RECEIVED"` only. |
| `bankReference: String?` | The beneficiary bank's own reference for the credit. `"RECEIVED"` only. |

Two things to get right, because they are easy to get wrong in the user's favour and wrong in fact:

- **`"UNABLE_TO_CONFIRM"` does not mean the merchant was not paid.** It means we stopped asking after 30 days. Word it as "could not confirm", never as "not received".
- **No credit line at all is a normal state**, not an error: it means this transaction is not on the rail (an older row recorded before your app updated, a bank that does not support confirmation, or a payment that was not approved). Absence means "we cannot ask".

The same three core fields, with the same meanings, exist on the SoftPOS side of the SDK — so an app that implements both halves reads one contract.

**The iOS boundary, stated rather than implied:** the sweep is app-scoped, not OS-background. It keeps polling across in-app navigation and resumes when the app returns to the foreground; while the app is suspended it does not run. That costs time, never an answer — the worklist and every result live in the SDK's store.

##### `refreshCreditConfirmation` — let the customer ask on demand

The SDK polls for beneficiary credit confirmation with **exponential backoff** and **stops after 30
days**, finalising the row as `"UNABLE_TO_CONFIRM"` — which means "we stopped asking", never "the
funds were not received". Expose **`refreshCreditConfirmation`** in your UI so the user can ask on
demand; it works after the window closes, and a later `"RECEIVED"` replaces the give-up state.

**Check `isCreditConfirmationSupported` on the transaction first.** Not every merchant's bank is on
this rail. `true` means the SDK is polling and you may offer the manual check; `false`/`nil` means
there is nothing to ask — do not call it, and show no credit UI for that transaction. Offer the
action only while

```swift
tx.authorizationStatus == "APPROVED"
    && tx.isCreditConfirmationSupported == true
    && tx.creditConfirmationStatus != "RECEIVED"
```

```swift
let updated = try await VeyraWallet.shared.tokenisation
    .refreshCreditConfirmation(transactionHash: hash)   // TransactionSummary?, nil if unknown here
```

- **A row outside that predicate is a no-op**, not an error: no request is made and the unchanged row
  comes back.
- **It works past the 30-day window**, including on a row already stamped `"UNABLE_TO_CONFIRM"` —
  that is the case it exists for. Nothing ever replaces `"RECEIVED"`.
- **Only a confirmation is written.** Anything else leaves the row exactly as it was.
- **Settlement only.** Nothing on this path can change `authorizationStatus`, `responseCode` or
  `responseStatusReason`.
- **Still no callback** — the returned row and the stored history are the wallet's whole credit
  surface, by design.
- **A failed call throws and changes nothing** — `VeyraWalletError.noNetworkConnection` when the
  device is offline. Show the error and leave the credit line reading "not confirmed yet".

#### `reconcilePendingTransactions`

Reconcile still-`PENDING` rows against the backend **right now**. The SDK's own app-scoped sweep (above) already resolves them without you, so this is the explicit "check again" rather than the mechanism: call it on pull-to-refresh, on returning to the foreground, or on a short loop while a shown QR is on screen for a snappier update than the backoff would give.

Unlike the scheduled sweep it ignores both the backoff and the 30-day window — an explicit ask always reaches the backend, and it is the supported way to check a row the sweep has stopped polling. Failures are still swallowed: a row whose query fails is left exactly as it was.

```swift
try await VeyraWallet.shared.tokenisation.reconcilePendingTransactions()
```

#### `refreshTransactionStatus`

```swift
// Returns the updated row, or nil if no row carries that hash.
let updated = try await VeyraWallet.shared.tokenisation
    .refreshTransactionStatus(transactionHash: summary.transactionHash)
```

The **per-transaction** counterpart to `reconcilePendingTransactions`, which asks about every open
row and returns nothing — this one answers about the row the customer is actually looking at, keyed
by its `transactionHash`.

The SDK polls a pending transaction for you with **exponential backoff**, and **stops after 30
days**. Polling never invents an outcome — a row that ages out simply stops being asked about and
stays `PENDING`. Expose this in your UI so the customer can ask on demand, which is the only route
to an answer once the window has closed.

Show it **only while the row is `PENDING`**: a settled row has nothing to ask about. It throws
rather than returning `nil` when the device is offline (`noNetworkConnection`) — `nil` means "the
backend has no such row", which is a different answer and must not be shown as a network problem.

#### `tokenisation.processReceipt` / `receipts` / `receipt(forTransactionHash:)`

Scan a merchant's **receipt QR** to store the customer's copy. The SDK decodes, validates that the receipt matches a payment this wallet actually made, de-duplicates and stores it.

| Parameter | Required | Description |
|-----------|----------|-------------|
| `qrPayload` | **Mandatory** | The scanned contents — raw JSON or base64. |
| `expectedTransactionHash` | Optional | Set it when the scan is launched **from a specific transaction's screen** — a receipt for a different transaction is rejected instead of silently attaching elsewhere. `nil` = unscoped. |

```swift
let base64 = Data(payload.utf8).base64EncodedString()
let receipt = try await VeyraWallet.shared.tokenisation.processReceipt(
    base64, expectedTransactionHash: tx.transactionHash)

let receipts = try await VeyraWallet.shared.tokenisation.receipts(limit: 100)
let linked   = try await VeyraWallet.shared.tokenisation.receipt(forTransactionHash: hash)
```

#### Foreground maintenance — `topUpKeysIfNeeded` / `lukState`

Wire one scene-phase observer at app level; the SDK does the rest (card status sync, self-healing refreshes, payment-key top-up — the key check also runs automatically before every payment):

```swift
.onChange(of: scenePhase) { phase in
    guard phase == .active else { return }
    Task {
        try? await VeyraWallet.shared.tokenisation.topUpKeysIfNeeded()
        try? await VeyraWallet.shared.tokenisation.reconcilePendingTransactions()
    }
}
```

`lukState(tokenUniqueReference:)` returns `LukState(usableKeyCount, refreshDue)` for an optional "keys remaining" indicator. There is deliberately no manual refresh call — the SDK owns when keys refresh; your app only observes (`lukState`, `requiresOnline`).

#### `recentActivity`

`recentActivity(tokenUniqueReference:)` → `[TokenActivity]` — the card's terminal scan-to-pay outcomes (`merchantName`, `amountMinorUnits`, `status` `"APPROVED"`/`"DECLINED"`, `atEpochMillis`), most recent first, local read. Use `transactionHistory` for the full multi-rail list.

---

## Response codes & error handling

Two kinds of surface, marked throughout:

- **Typed** — enum cases / error types. Stable contract; branch on these.
- **Observable string codes** — documented values of `String` fields. Stable vocabularies, but your code matches on strings.

### Typed errors

| Error | Case | When | What to do |
|---|---|---|---|
| `VeyraWalletError` | `.notConfigured` | Any call before `VeyraWallet.configure(_:)` | Configure at launch. |
| | `.authenticationFailed(message)` | Face ID / Touch ID / passcode failed or was cancelled — **no payment was attempted**, nothing recorded | Stay on the confirm screen; let the user retry. |
| | `.onlineRequired(message)` | The card has no usable payment keys — refused **before** any payment/QR is built | Prompt the user to connect to the internet. Pre-empt it: the card already shows `requiresOnline == true` — grey it out. Clears itself after the SDK's automatic refresh. |
| | `.amountExceedsCardLimit(message)` | The amount is larger than this card can carry in one payment — refused **before** any payment/QR is built | Offer a smaller amount or another card. Unlike `.onlineRequired` this does **not** clear by going online: the per-payment limit is provisioned with the card. |

Both refusals are also available as an observer — `VeyraWallet.shared.tokenisation.observePaymentRefusals(onRequireOnline:onAmountExceedsCardLimit:)`, with `stopObservingPaymentRefusals()` — for hosts that would rather handle them in one place than at every call site. **Porting from Android? The registration shape differs.** On Android the two refusals are **per token**: you hand them to the card you are arming, so different cards can carry different handlers simultaneously. On iOS it is a **single SDK-wide registration** — observing again replaces the previous observer — and the callback's `tokenUniqueReference` tells you which card it was about. Nothing is lost, but Android code that assumes "this handler only ever hears about *this* card" must start filtering on `tokenUniqueReference` here. It is the same last-registration-wins rule the `transactions` observers follow.
| | `.tokenNotActive(message)` | The card's server-side status is not active (e.g. suspended by the issuer) — **no payment was attempted** | Tell the user the card is suspended/inactive. Don't retry locally — payments resume automatically once a status sync sees the card active again. |
| | `.noNetworkConnection(message)` | **Any** wallet backend call — get banks, verify account, digitise, request activation code, activate, check token active, get token status — on a device with no working internet connection | Ask the user to connect and try again. Nothing was sent, so nothing needs undoing. |
| | `.requestFailed(message)` | Everything else (network, backend, invalid input) | Show `error.localizedDescription` — every case carries its underlying message. |
| `VeyraSoftPOSError` | `.notConfigured` | Any call before `VeyraSoftPOS.configure(_:)` | Configure at launch. |
| | `.tapRefused(message)` | Arming the tap reader was refused — the wallet's payment is mid-flight (combined apps) | "Finish or cancel the current payment first." Never occurs in a SoftPOS-only app. |
| | `.noNetworkConnection(message)` | **Any** SoftPOS backend call — register / refresh status / activate / deactivate / update merchant, settlement banks, create payment context, take a payment — on a device with no working internet connection | Ask the merchant to connect and try again. Nothing reached the gateway; no transaction was recorded. |
| | `.requestFailed(message)` | Backend/network failure | Show the message; offer retry. |
| `VeyraSDKError` | `.notConfigured` | Combined facade used before `VeyraSDK.configure(softpos:wallet:)` | Configure at launch. |

### Tap acceptance — `TapPaymentResult.status`

Terminal outcomes only — unsupported cards and lost contact **never** produce one of these; they fire the re-tap hints and the reader stays armed.

`TapPaymentResult.status` is `"APPROVED"` / `"DECLINED"` / `"PENDING"` / `"FAILED"` (`PENDING` → poll `transactions.status`; `FAILED` → never reached the server, safe to retry). `TapPaymentEvent.ended(outcome:)` (`"CANCELLED"` / `"TIMEOUT"` / `"ERROR"` / `"UNAVAILABLE"`) means the reader session ended **without** a card — recreate the session to keep accepting.

The response codes underneath are shared on the wire across rails; where a code surfaces (`responseCode` fields, history rows), handle it as follows:

> **Read `response_status`, not the code.** Every payment outcome now carries a
> triple: `response_code` (what the wire said), `response_status` (**what to do**) and
> `response_status_reason` (why). Branch on `response_status` only — `APPROVED`, `DECLINED`, `FAILED`
> or `PENDING`. Only the first three are final; `PENDING` always means "ask again". The SDK no longer
> derives a status from the code, and neither should your app: a code you do not recognise is not a
> decline. `"99"` is retired — an unheard outcome is now `68` (no reply), `06` (the hop we called
> failed) or `96` (the SDK/service itself threw), all `PENDING`, while `91` (never connected) and
> `25` (no such transaction) are `FAILED`, meaning nothing happened and a retry is safe.


| Code | Meaning | Terminal? | What to do |
|---|---|---|---|
| `"00"` | Approved | Yes | Success screen + receipt (`result.reference` → `transactions.receipt(forReference:)`). |
| `"05"` | Declined by the issuer/server | Yes | Show decline; try another card. A stale customer QR also surfaces as `"05"` on the CPM rail — if the customer's code sat on screen a while, ask them to regenerate and rescan. |
| `"06"` | Failed before reaching the issuer — validation, cancellation, merchant not active, wrong mode, read failure after the online boundary | Yes (no money moved) | Fix the input/config and re-initiate; `message` says which check failed. |
| `"68"` (was `"99"`) | Pending — sent, no reply received (timeout/network) | Outcome unresolved | **Do not charge again.** The SDK stores the transaction as `PENDING` and keeps polling; show "processing" and let the history row resolve. |
| `"91"` | Never connected — the request provably never left | **`FAILED`** — nothing happened, retry is safe | Same — poll, don't retry-charge. |
| `"12"` / `"14"` / `"51"` / `"54"` | Invalid transaction / invalid card / insufficient funds / expired card | Yes | Hard declines — show the reason, try another card. |
| `"96"` | System malfunction — **ambiguous**: the payment may have failed *or* succeeded with the response lost | Yes, but unresolved | Don't assume failure: poll the transaction status briefly before telling the merchant it failed. |

### QR context lifecycle — `contextStatus().state`

| State | Meaning | What to do |
|---|---|---|
| `PENDING` | QR live, unpaid | Keep polling. |
| `IN_FLIGHT` | A wallet claimed it; settling | Keep polling. |
| `APPROVED` / `DECLINED` | Settled — `responseCode` carries the rail outcome | Stop polling; result screen + receipt. |
| `EXPIRED` | Lapsed unpaid (your `onExpired` callback has blanked the QR) | Offer a fresh QR. An expired context is never recorded in history. |

### Rail response codes (all QR + settlement legs)

| Code | Meaning | What to do |
|---|---|---|
| `"00"` | Approved | `approved` convenience fields on every outcome type are exactly this check. |
| `"05"` | Definitive decline (issuer/token provider refused — includes stale/tampered customer QRs, restriction and limit breaches) | Show decline. On a customer-QR charge, a code that sat on screen may simply be stale — ask the customer to regenerate. |
| `"96"` | System error — **outcome ambiguous** (may settle later via reconciliation) | Keep polling briefly (merchant: `contextStatus` / `transactions.status`; wallet: `reconcilePendingTransactions`) before declaring failure. |
| `null` | Not settled yet | Keep polling. |

### Digitisation & eligibility — `responseCode`

Three values, and a rule for everything else, on both eligibility and digitise responses:

| Code | Meaning | What to do |
|---|---|---|
| `"APPROVED"` | Eligible / provisioned and active | Card is ready — show it in the wallet. |
| `"APPROVE_REQUIRE_AUTH"` | Provisioned, needs activation | Run the activation flow with the returned `activationMethods`. |
| `"DECLINED"` | Refused | Show `message` (it carries the reason — e.g. the account falls outside your configured provision-context allow-lists). Flow ends. |
| Any other code (or none) | Not recognised by this SDK version | The token is **discarded** — nothing provisioned, no card added, even if the response carried full token data. Show the error and offer a retry; update the SDK if it persists. |

The last row is a **throw**, not a returned code: `digitise` fails with `VeyraWalletError.unrecognisedResponseCode(message:)`, whose message quotes the raw code. A token whose terms the SDK cannot interpret is never installed on a guess — so the wallet is left exactly as it was, and the SDK asks the backend to release the token it minted.

### Activation — `status` + `failureCode`

`ActivationCodeResponse.status` / `ActivateResponse.status` are `"SUCCESS"` / `"FAILURE"` — **check `status` even when the call itself succeeds.** On failure, branch on the typed `failureCode` (`message` is display text — never string-match it):

| `failureCode` | Meaning | What to do |
|---|---|---|
| `.codeExpired` | Code lapsed; attempts may remain | Offer "resend code". |
| `.codeInvalid` | Wrong code, attempts remain | Stay on entry; show `attemptsRemaining`. |
| `.maxAttemptsExceeded` | The 3-attempt limit for this code is exhausted | The cycle is closed; honour `recommendDelete` (`.must`: delete the token and restart add-card; `.may`: advisory). |
| `.codeRequestRateLimited` | Re-request rate cap (per token, per hour) | Disable "resend" with a cool-down message — do **not** end the flow. |
| `.noPendingActivation` | No live code (never requested, or the pending window lapsed) | Request a code first. |
| `.activationLocked` | Locked after repeated exhausted cycles | Terminal — hide both retry and resend; the issuer must unlock; direct the user to their bank. |
| `.tokenNotFound` / `.tokenNotActivatable` | No activatable token behind the reference | End the flow; re-digitise or contact the issuer. |
| `.invalidRequest` / `.activationFailed` | Malformed request / server-side activation error | Show `message`; safe to retry `.activationFailed` later. |
| `.unknown(raw:)` | A code newer than this SDK | Show `message`; log the raw value. |

### Card lifecycle statuses

The wallet syncs each card's server status automatically (foreground sweeps and around payments). What your app observes:

| Server status | Effect in the SDK | What to do |
|---|---|---|
| `ACTIVE` | Card pays normally | — |
| `SUSPENDED` / `EXPIRED` / `PENDING_ACTIVATION` | Card refuses to pay (`.tokenNotActive`); `StoredCard.status` shows the status | Render the card as unavailable. **Not sticky** — a later sync unfreezes it automatically. |
| `DEACTIVATED` | The card and all its material are wiped and it disappears from `tokens()` | Refresh your card list; the user re-adds the card if needed. |

#### `observeTokenLifecycle` — the SDK tells you when a card's status changes

Reading the table above on your next render is not always soon enough. The sweep can apply
`SUSPENDED` while the customer is *looking at* a card screen — so the card stays drawn as usable,
they tap, and it fails. Subscribe and you are told the moment it is applied:

```swift
try VeyraWallet.shared.tokenisation.observeTokenLifecycle { change in
    // change.tokenUniqueReference — which card (it fires for any stored card)
    // change.status               — ACTIVE / SUSPENDED / EXPIRED / DEACTIVATED /
    //                               PENDING_ACTIVATION / UNKNOWN
    // change.rawStatus            — the literal as stored; log this one
    // change.canPay               — whether the card can pay right now
    // change.previousStatus       — what it held before, or nil if this is its first status
}
```

- **Branch on `canPay`, not on `status`.** It is the same predicate the SDK's own payment gates
  use, so a status added to the backend after your build shipped is correctly reported as *not*
  payable instead of falling through a `switch` that has never heard of it.
- **Register once, at start-up** — not per card screen. The card that matters is the one no screen
  is showing.
- **It does not replay.** If your app was not running when the issuer suspended the card, nothing
  is queued — read `tokens()` when a screen appears. The observer is a convenience over the store,
  not a delivery guarantee, so keep the read path.
- **Only genuine changes fire.** A sweep re-applying the status a card already had wakes nothing.
- **Last registration wins**; `stopObservingTokenLifecycle()` clears it. No subscription token.
- Delivered on the main thread.

#### `observeCardKeyState` — a card ran out of payment keys, or got them back

`StoredCard.requiresOnline` tells you a card cannot pay until the SDK refreshes its keys. This is
the push version of that same value — and it *is* the same value, because the observer and
`tokens()` read one function, so a callback can never contradict the list you are about to draw.

```swift
try VeyraWallet.shared.tokenisation.observeCardKeyState { tokenUniqueReference, requiresOnline in
    // grey the card, or un-grey it
}
```

**Read this limit before you word your UI.** It fires from the two moments the SDK is actually
executing: a payment consuming a key, and a refresh delivering new ones. Payment keys *also* expire
by clock, which happens with no SDK code running at all — **nothing fires for that**, and such a
card simply reads as `requiresOnline` on your next `tokens()`. The first evaluation of a card after
launch is a silent baseline, for the same reason. Keep reading the card list when a screen appears.

Observation only: there is deliberately no API to trigger a key refresh — the SDK owns when keys
are replenished. `stopObservingCardKeyState()` clears it.

### Merchant statuses

`ACTIVE` / `INACTIVE` / `SUSPENDED` / `DEACTIVATED` (on registration results, `status()` responses and every payment response's `merchantStatus`). Payments are refused client-side unless the merchant is `ACTIVE` — gate your get-paid entry on `merchant.isRegistered` and the stored merchant's last known status, and call `status(merchantID:)` while awaiting activation.

#### `merchant.onMerchantStatusChanged` — the SDK now watches it for you

The SDK polls the registered merchant's status in the background and tells you when it changes:

```swift
try VeyraSoftPOS.shared.merchant.onMerchantStatusChanged { change in
    // change.merchantID, change.status, change.previousStatus
    if !change.canAcceptPayments { disableGetPaid() }
}
```

Two uses: stop offering to take payments the moment a merchant is deactivated mid-session, rather
than at the next screen load; and catch the **activation** moment after registration without
polling for it yourself — which previously you had to, by calling `status(merchantID:)` on a timer
of your own.

**Branch on `canAcceptPayments`, not on `status`** — it is the same reading the client-side payment
gate uses, so you cannot end up more permissive than the gate that will refuse the sale. Anything
that is not `ACTIVE`, including a status newer than your build, is `false`.

**The polling is the SDK's and is app-scoped, not screen-scoped.** It starts at `configure` (and
after a successful `register`), keeps running as the merchant navigates, and no screen may start or
stop it. One platform boundary, stated plainly: iOS suspends timers when the OS suspends your app,
so polling pauses while backgrounded and resumes on foreground. **No answer is lost** — the status
lives in the SDK's store and the comparison is against what was persisted, so a change that
happened while you were away still arrives on the first poll after you return.

Only genuine changes fire, registration is single-listener with last-registration-wins, there is no
replay, and delivery is on the main thread. `stopObservingMerchantStatus()` clears it.

### History status vocabularies

| Field | Values |
|---|---|
| Wallet `TransactionSummary.authorizationStatus` | `PENDING` (still polling) / `APPROVED` / `DECLINED` / `FAILED` / `nil` (legacy — indeterminate) |
| Merchant history status | `APPROVED` / `DECLINED` / `PENDING` (outcome unknown, SDK keeps polling) / `FAILED` (never reached the server) |
| Wallet scan rejection (typed) | `.malformed` / `.missingSignature` / `.unknownKey` / `.badSignature` (show "couldn't verify this code") / `.expired` (show "code expired — ask the merchant for a fresh one"); every rejection ends the flow |

### Quick reference — handling failed & declined responses

The consolidated playbook. "Safe to retry" means no money can have moved.

| You receive | Where | Safe to retry? | Do this |
|---|---|---|---|
| Code `"05"` / status `DECLINED` | Merchant tap / rails | Yes (new attempt) | Show decline; try another card or rail. |
| Code `"06"` / status `FAILED` | Merchant tap | Yes | Nothing reached the issuer — fix what `message` names (input, config, merchant inactive) and re-initiate. |
| Status `PENDING` (any code: `68`, `06`, `96`, `09`) or `FAILED` with `91` | Merchant tap | **No — never re-charge** | Outcome unknown at the issuer. Show "processing"; the SDK polls and resolves the history row. Re-charging risks a double charge. |
| Code `"96"` | Any rail | **No — not yet** | Ambiguous: may have succeeded with the response lost. Poll briefly (context status / transaction status / reconcile) before reporting failure. |
| `EXPIRED` context / `onExpired` fired | Get-paid QR | Yes | The QR died unpaid (never recorded). Blank it, offer a fresh one. |
| `inspectCustomerQr` throws | Merchant CPM scan | Yes | Not a payment QR — transient hint, stay armed for another scan. |
| `"05"` on a customer-QR charge | Merchant CPM | Yes (fresh QR) | Could be a stale/hoarded QR: ask the customer to regenerate and rescan before treating it as a funds decline. |
| Scan rejected (`.expired` / `.badSignature` / …) | Wallet MPM scan | Yes (fresh scan) | End the flow; ask the merchant for a fresh code. Never show a rejected payment on a confirm screen. |
| `.authenticationFailed` | Wallet payments | Yes | Nothing was sent. Stay on the confirm screen; let the user retry the biometric. |
| `.onlineRequired` | Wallet payments | After going online | Prompt to connect; the SDK refreshes the card itself. Pre-empt with `requiresOnline` (grey the card out). |
| `.amountExceedsCardLimit` | Wallet payments | **Not by retrying** | The amount exceeds the card's per-payment limit. Going online does **not** help — offer a smaller amount or another card. |
| `.tokenNotActive` | Wallet payments | No (until active) | Card is suspended/inactive server-side. Show why; it unfreezes automatically when a sync sees it active. Don't build retry loops. |
| Digitise `"DECLINED"` | Add card | Per `message` | Show the server's message; the flow ends. Common cause: the account falls outside your provision-context allow-lists. |
| `.unrecognisedResponseCode` | Add card | Yes | Digitisation answered with a code this SDK version does not know, so the token was discarded and no card was added. Retry; if it persists, update the Veyra SDK. |
| Activation `"FAILURE"` | Activation | Per `message` | Branch on the [known messages](#activation--status--failure-messages): resend on expiry, cool-down on the rate cap, stop entirely on lockout ("contact your issuer"). |
| `.tapRefused` | Combined apps | Yes (after mode settles) | The other mode's payment is mid-flight — prompt to finish/cancel it. |
| `.noNetworkConnection` (both enums; `TapPaymentResult.sdkErrorCode == "NO_NETWORK_CONNECTION"`) | Any backend call, both products | Yes, once connected | The device has no working internet connection and the call never left it. Ask the user to connect and retry. |

**Three things end with "get online", and they are not the same thing.** Confusing them produces
either a card you have wrongly greyed out or a promise of a refresh that cannot happen:

- **`.noNetworkConnection`** — the *device* has no connection. Every call fails the same way and
  nothing recovers until the user reconnects. Retrying is safe: nothing was sent.
- **`.onlineRequired`** — the *card* has run out of payment keys. The device is usually online
  already; the SDK refreshes the card itself, typically within seconds. It is a card state, not a
  network state, so greying a card out on `.noNetworkConnection` is wrong — the card is fine.
- **`91` / `ISSUER_SWITCH_NOT_AVAILABLE`** — the device reached the network and the gateway refused
  the connection. The payment provably never went through, so it is safe to retry — but the user's
  connection is not the problem and telling them to check it wastes their time.

An offline tap is reported as `.noNetworkConnection` on the error surface and as
`sdkErrorCode == "NO_NETWORK_CONNECTION"` on `TapPaymentResult` — with **no** response code, because
nothing reached the gateway. Do not show it as a decline, and do not poll it: there is no transaction
to reconcile.

---

## Data models

Reference for the public models. All are immutable value types; fields not listed here are not public API.

```swift
public struct StoredCard {                  // wallet card display record
    let tokenUniqueReference: String        // identity for activation/removal/status
    let panLastFour: String
    let maskedPAN: String                   // "•••• •••• •••• 1112"
    let expiry: String                      // "MM/YY"
    let cardHolderName: String      // "AFRIGO ****1234" — scheme + masked last four, not a person
    let accountHolderName: String
    let bankName: String?
    let status: String                      // lifecycle: "ACTIVE", "PENDING_ACTIVATION", "SUSPENDED", "EXPIRED"
    let requiresActivation: Bool
    let isActive: Bool                      // the card payments use
    let requiresOnline: Bool                // grey out + prompt to connect
}

// tokenisation.observeTokenLifecycle payload — branch on canPay, not on status
public struct TokenStatusChange {
    let tokenUniqueReference: String; let status: String; let rawStatus: String
    let canPay: Bool; let previousStatus: String?
}
// tokenisation.observeTransactionResolved payload — keyed on transactionHash, NOT on a
// merchant reference (that is the merchant SDK's separate channel)
public struct WalletTransactionResolution {
    let transactionHash: String; let tokenUniqueReference: String?; let status: String
    let responseCode: String?; let reason: String?
    let amountMinorUnits: Int64; let merchantName: String
}
// merchant.onMerchantStatusChanged payload — branch on canAcceptPayments, not on status
public struct MerchantStatusChange {
    let merchantID: String; let status: String
    let canAcceptPayments: Bool; let previousStatus: String?
}

public struct Bank { let slug: String; let name: String; let institutionCode: String }
public struct VerifyAccountResponse { let responseCode: String?; let message: String?; var isApproved: Bool }
public struct DigitiseResult {
    let tokenUniqueReference: String?; let responseCode: String?; let message: String?
    let activationMethods: [DigitiseActivationMethod]   // medium + masked contact
    let tokenStored: Bool
    var isApproved: Bool; var requiresActivation: Bool
}
public enum TokenizationRecommendation { case approve, decline, requireAdditionalAuthentication }
public enum TrustScore { case untrusted, lowTrust, moderateTrust, trusted, highlyTrusted }
public enum ActivationMethod { case maskedEmail, maskedMobilePhone }
public enum ActivationReason { case addCard, checkAccountEligibility, other }
public struct ActivationCodeResponse { let tokenUniqueReference: String?; let expirationDateTime: String?; let status: String?; let message: String? }
public struct ActivateResponse { let tokenUniqueReference: String?; let status: String?; let message: String? }
public struct TokenStatusUpdateResponse { let tokenUniqueReference: String?; let status: String?; let message: String? }

public enum ScanInspection { case verified(VerifiedPayment); case rejected(ScanRejectionReason, detail: String?) }
public enum ScanRejectionReason { case malformed, missingSignature, unknownKey, badSignature, expired }
public struct VerifiedPayment {
    let txRef: String; let merchantID: String; let merchantName: String; let merchantCity: String?
    let amount: String                      // "5000.00"
    let amountMinorUnits: Int64; let currencyNumeric: String; let expiryEpochSeconds: Int64
}
public struct PaymentOutcome {
    let approved: Bool                       // derived: responseStatus == "APPROVED"; false for PENDING too
    let responseCode: String?                // "00", "51", "68"… — always populated, quote it verbatim
    let responseStatus: String?              // APPROVED · DECLINED · FAILED · PENDING — what the payment IS
    let responseStatusReason: String?        // stated cause: INSUFFICIENT_FUNDS, NO_RESPONSE_RECEIVED…
    let message: String?
    let merchantName: String?                // registered name from the gateway (beats the QR copy)
    let merchantLocation: String?            // "city, state" from the gateway; nil if not supplied
}
public struct PaymentQr {
    let tokenUniqueReference: String
    let payload: String                     // render as the QR
    let amountMinorUnits: Int64; let currencyNumeric: String
    let expiresAtEpochMillis: Int64
    let transactionHash: String             // match against history to reconcile exactly this QR
}
public struct LukState { let usableKeyCount: Int; let refreshDue: Bool }
public struct TokenActivity { let merchantName: String; let amountMinorUnits: Int64; let currencyNumeric: String; let status: String; let atEpochMillis: Int64 }

public struct TransactionSummary {          // wallet history row
    let merchantName: String; let amountInMinorUnit: Int64  // Int64 since 1.0.15; was Int
    let transactionCurrencyCode: String?
    let authorizationStatus: String?        // PENDING / APPROVED / DECLINED / FAILED / nil
    let responseCode: String?               // the outcome's code, verbatim ("00", "51"...); nil until resolved
    let responseStatusReason: String?       // the stated cause ("INSUFFICIENT_FUNDS"...); display, never parse
    let entryMethod: String?                // "TAP" / "QR_GENERATED" / "QR_SCANNED" / nil
    let merchantLocation: String?; let transactionHash: String?
    let atEpochMillis: Int64?; let merchantTransactionReference: String?; let merchantId: String?
    let merchantOrderID: String?            // the merchant's own order id; display only, never a key
    // Beneficiary credit confirmation — settlement only, never the payment outcome.
    let creditTransactionID: String?           // credit-leg id; display/support only
    let isCreditConfirmationSupported: Bool?   // THE GATE: true ⇒ SDK is polling, render the line
    let creditConfirmationStatus: String?      // nil = no answer yet / "RECEIVED" / "UNABLE_TO_CONFIRM"
    let creditedAt: String?                    // when the bank posted the credit (RECEIVED only)
    let bankReference: String?                 // the bank's own reference   (RECEIVED only)
}
public struct TransactionReceipt {
    /* merchantName, merchantId, merchantAddress, transactionType, transactionStatus,
       transactionTime, totalAmount, totalAmountFormatted, currency, maskedToken,
       merchantTransactionReference, cdcvmApprovedByWallet, cdcvmOutcome,
       transactionId, transactionHash */
}

// SoftPOS side:
public struct SettlementBank { let slug: String; let name: String; let institutionCode: String }
public struct MerchantRegistration { /* see Merchant registration */ }
public struct MerchantRegistrationResult { let success: Bool; let merchantID: String?; let terminalID: String?; let merchantStatus: String?; let message: String? }
public struct MerchantStatus { let merchantID: String; let status: String? }
public struct MerchantUpdate { /* see merchant.update */ }
public struct StoredMerchant { /* full stored profile incl. backend-assigned merchantCategoryCode, terminalID, merchantStatus */ }
public enum TapPaymentEvent { case cardDetected, unsupportedTarget, cardContactLost, cardReadingComplete, sendingRequestOnline, receivingOnlineResponse, ended(outcome: TapSessionOutcome), result(TapPaymentResult) }
public struct TapPaymentResult { let status: String; let pan: String?; let cardholderName: String?; let errorMessage: String?; let reference: String?; let creditTransactionID: String?; let isCreditConfirmationSupported: Bool? }
public struct PaymentContextQR { let txRef: String; let expiry: String?; let kid: String?; let mpmPayload: String }
public struct PaymentContextState { let txRef: String; let state: String; let responseCode: String?; var isSettled: Bool; var isApproved: Bool }
public struct ScannedCustomerQr { let maskedCard: String; let amountMinorUnits: Int64; let currencyNumeric: String; let cardholderName: String? }
public struct CustomerQrChargeOutcome { let approved: Bool; let responseCode: String?; let transactionID: String?; let reference: String; let creditTransactionID: String?; let isCreditConfirmationSupported: Bool? }
public struct MerchantTransaction { let reference: String; let rail: String; let railLabel: String; let amountMinorUnits: Int64; let currencyNumeric: String?; let status: String; let responseCode: String?; let responseStatusReason: String?; let transactionTime: String?; let transactionID: String?; let merchantOrderID: String?; let maskedTokenLast4: String; let transactionHash: String?; let cardholderName: String?; let creditTransactionID: String?; let isCreditConfirmationSupported: Bool?; let creditConfirmationStatus: String? }
public struct CreditConfirmation { let creditTransactionID: String; let status: String; let amountMinorUnits: Int64?; let creditedAt: String?; let bankReference: String?; let message: String? }   // the on-demand fetch's reply
public struct TransactionResolution { let reference: String; let responseCode: String?; let status: String; let reason: String? }   // transactions.onTransactionResolved payload
public struct SaleCreditConfirmation { let reference: String; let creditTransactionID: String?; let status: String; let amountMinorUnits: Int64?; let bankReference: String?; let creditedAt: String? }   // transactions.onCreditConfirmation payload
public struct MerchantReceipt { let merchantName: String; let merchantAddress: String; let transactionType: String; let totalAmountMinorUnits: Int64; let totalAmountFormatted: String; let maskedToken: String; let reference: String; let transactionHash: String?; let qrPayload: String }
public struct TransactionStatus { let merchantTransactionReference: String; let merchantID: String; let amount: Int64; let responseCode: String; let merchantStatus: String?; let transactionID: String? }
```

---

## Complete flows

### Add a card (wallet)

```
User enters account number
        │
        ▼
  banks(accountNumber:)  ──►  user picks their bank (institutionCode)
        │
        ▼
  verifyAccount
        │
        ├─ not APPROVED ──► show error (flow ends)
        │
        ▼ APPROVED
    digitise
        │
        ├────────────────┬──────────────────────────┐
        ▼                ▼                          ▼
    APPROVED     APPROVE_REQUIRE_AUTH           DECLINED
        │                │                          │
        ▼                ▼                          ▼
  Card added ✓   Show activation methods       Show error
   (flow ends)    (branch on medium)            (flow ends)
                         │
        ┌────────────────┴───────────────────────┐
        ▼                                        ▼
 MASKED_EMAIL /                      CALL_CENTER_PHONE / WEBSITE /
 MASKED_MOBILE_PHONE                 MOBILE_APPLICATION
        │                                        │
        ▼                                        ▼
 requestActivationCode                Show contact info + action button
        │                             ("Call now" / "Open website" / "Open app")
        ▼                                        │
 OTP entry screen                                ▼
 (masked contact +                       observeActivation
  countdown from                    polls every 10 s, up to 5 min
  expirationDateTime)                            │
        │                          ┌─────────────┴───────────┐
        ▼                          ▼                         ▼
    activate                  onActivated                onTimeout
        │                  → wallet home ✓         → "still pending" hint;
        ├─ SUCCESS ──► card active ✓                 SDK keeps checking
        └─ else ────► wrong code — retry
```

### Get paid (merchant) — pick the rail per sale

```
Merchant registered & ACTIVE? ──no──► register / activate first
        │ yes
        ▼
 Amount entry (minor units)
        │
        ├─────────────── Tap ───────────────► tap.session
        │                                       ├─ .cardDetected: "hold steady"
        │                                       ├─ .unsupportedTarget / .cardContactLost:
        │                                       │    transient hint, stays armed
        │                                       ├─ .cardReadingComplete → .sendingRequestOnline
        │                                       │    → .receivingOnlineResponse: progress
        │                                       └─ terminal outcome → result screen
        │
        ├─────────── Show a QR ─────────────► payments.createContext
        │                                       render mpmPayload; poll contextStatus
        │                                       until APPROVED / DECLINED / EXPIRED
        │                                       (onExpired blanks the code)
        │
        └────── Scan the customer's QR ─────► inspectCustomerQr → confirm the QR's own
                                                amount → chargeCustomerQr
                                                → approved iff code "00"
        After any settled rail:
        receipt(forReference:) → show receipt + receipt QR
        (customer scans it with their wallet's processReceipt)
```

### Pay by scanning a merchant QR (wallet)

```
Camera scan ──► inspectScannedQr
                    ├─ rejected (malformed / bad signature / expired) ──► end flow, show reason
                    └─ verified ──► confirm screen (merchant + the QR's amount)
                                        │ user confirms
                                        ▼
                          SDK presents the Face ID / passcode sheet itself
                                        ├─ failed/cancelled ──► stay on confirm screen
                                        ▼ success (single-use)
                              payScannedContext
                                        ├─ approved ──► success screen; history row APPROVED
                                        ├─ declined ──► declined screen; history row DECLINED
                                        └─ onlineRequired ──► "connect to the internet", stay on confirm
```

## Building with React Native?

Use the official React Native SDK —
[`veyra-sdk-react-native`](https://www.npmjs.com/package/veyra-sdk-react-native) — and
its [sample app](https://github.com/Iventure-Tech/veyra-react-native-sample-app), whose
`DEVELOPER-GUIDE.md` is the canonical React Native guide. Do **not** integrate the
artifacts documented here directly from React Native: the SDK's automatic payment-mode
arming follows native screen lifecycle, which a React Native app's JavaScript
navigation does not exercise — the React Native SDK's session hooks exist precisely to
bridge that gap.

### Holding a `PENDING` payment, and being told when it settles

Because the SDK no longer invents terminal outcomes, a tap that gets no answer hands you
`responseStatus == PENDING`. **That is not a failure and not a decline** — the payment may well have
completed, so the one thing you must not do is charge again.

What the app should do:

1. **Stay on the confirmation screen** and show "processing". Do not navigate away and do not print a
   receipt yet.
2. **Let the SDK resolve it.** It stores the transaction and polls with backoff; you do not have to.
3. **Finish when it settles** — either from `onTransactionResolved` (below) or by reading the row with
   `getTransaction(reference)` / `getLastTransactions()`.

A pending row always converges: it becomes `APPROVED`, `DECLINED` or `FAILED` when the backend settles
it, or it stays `PENDING`. It never turns into a terminal outcome the SDK made up, and there is no
attempt cap that gives up on it.

**`TRANSACTION_IN_PROCESS_ESCALATED`** is the one reason that changes what *you* do. It means automated
reconciliation has stopped and a human will settle the payment. Stop any tight loop of your own, tell
the merchant "we're looking into this", and re-check lazily — next app open, or a long backoff. It will
still resolve; it just will not resolve in seconds.

#### `transactions.onTransactionResolved` — the SDK pushes the answer

```swift
try VeyraSoftPOS.shared.transactions.onTransactionResolved { resolution in
    // resolution.reference    — which payment (you may have more than one pending)
    // resolution.status       — "APPROVED" / "DECLINED" / "FAILED" (never "PENDING")
    // resolution.reason       — e.g. "INSUFFICIENT_FUNDS"
    // resolution.responseCode — the wire literal, for receipts and support
}

// …and when you no longer want it:
try VeyraSoftPOS.shared.transactions.stopObservingTransactionResolved()
```

Five things worth knowing before you rely on it:

- **Register once, at start-up** — not per payment. It fires for *any* transaction that resolves,
  including one started in an earlier app session and settled by a later poll. That is the case that
  matters most: a tap that resolves after your app was backgrounded or killed.
- **Registration is single-listener: last registration wins.** Calling it again *replaces* the previous
  observer rather than adding a second one, and `stopObservingTransactionResolved()` clears it. There
  is no subscription token and no listener list — if two parts of your app both want the answer, fan it
  out yourself from one registration.
- **It does not replay.** If your app was not running when the row settled, nothing is queued for you —
  read `transactions.history(limit:)` at start-up. The observer is a convenience over the store, not a
  delivery guarantee, so keep the read path.
- **The payment callback still fires exactly once**, possibly with `PENDING`. The resolution arrives on
  this separate channel; the two are not alternatives.
- It is delivered on the main queue, like the payment callback.

It fires from every rail this platform has — the tap reader, the merchant-presented QR settle and the
customer-QR charge — because the SDK announces it from the one place a stored row stops being pending.

#### `transactions.onCreditConfirmation` — the funds landed

The settlement half of the same idea: after an approved sale whose response said
`isCreditConfirmationSupported`, the SDK asks the merchant's bank (exponential backoff, up to 30 days)
and pushes the answer here.

```swift
try VeyraSoftPOS.shared.transactions.onCreditConfirmation { confirmation in
    // confirmation.reference        — which sale
    // confirmation.status           — "RECEIVED", or the final 30-day "UNABLE_TO_CONFIRM"
    // confirmation.amountMinorUnits — as the merchant's bank reported it (RECEIVED only)
    // confirmation.bankReference / .creditedAt / .creditTransactionID
}

try VeyraSoftPOS.shared.transactions.stopObservingCreditConfirmation()
```

Same rules as above — main queue, register once, **last registration wins**, no replay — plus one that
is specific to it: **`UNABLE_TO_CONFIRM` is a give-up, never a reversal.** The payment outcome is
unchanged; only the *settlement* could not be confirmed. And the answer is written to the sale's stored
row (`creditConfirmationStatus`) as well as announced, so a screen opened later still shows it — which
is why the store re-read in `transactions.creditConfirmation`'s recommended pattern stays even when you
take the callback.

#### When the SDK could not start a payment at all

On iOS a payment that was never attempted — request validation, merchant not onboarded, a stale or
malformed QR — surfaces as a **thrown error** from the call that refused it, not as a payment outcome.
There is no response code and no status in that case, deliberately: a response code asserts that a
payment was attempted and something answered or failed to, so a fabricated one would invite you to
retry something that never left the device (and put a made-up code on a receipt). Fix the input and
call again — nothing needs reconciling, because nothing was sent.

(`sdkErrorCode` on the payment response is the Android tap rail's equivalent of the same rule; iOS has
no tap rail, so here the refusal arrives before any response object exists.)

