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
    .package(url: "https://github.com/Iventure-Tech/veyra-sdk-ios", from: "1.0.8"),
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
| `merchant` | Merchant lifecycle — registration, status, activate/deactivate, profile update, banks, stored merchant. |
| `tap` | Contactless tap acceptance — the customer's Android Veyra wallet taps this iPhone. |
| `payments` | QR payments — create/poll a get-paid QR (merchant-presented) and inspect/charge a customer QR (consumer-presented). |
| `transactions` | Transaction queries — local history, receipts, status polling. |

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

```swift
let softposConfig = VeyraSoftPOSConfiguration(
    environment: .test,
    clientID: "your-client-id",
    clientSecret: "your-client-secret"
)
```

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `environment` | **Mandatory** | `.test` or `.live`. Endpoints resolve from the SDK's defaults — no URLs to supply. |
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

Register the merchant on this device. Personal merchants require a BVN; business merchants require a CAC number. All other fields are mandatory for both.

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
        bvn: "12345678901",                // .personal only
        cacNumber: nil,                    // .business only
        accountNumber: "1234567890",       // settlement NUBAN account
        institutionCode: "000000",         // from merchant.banks()
        acquirerID: "ACQ001"
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

Update the merchant profile (terminal ID and MCC are preserved). All parameters are required except `addressLine2`.

```swift
let status = try await VeyraSoftPOS.shared.merchant.update(
    merchantID: merchantID,
    MerchantUpdate(merchantName: "Ada's Store", emailAddress: "ada@example.com",
                   phoneNumber: "+2348012345678", addressLine1: "12 Marina Road",
                   city: "Lagos", state: "Lagos", countryCode: "0566",
                   accountNumber: "1234567890", institutionCode: "000000",
                   acquirerID: "ACQ001")
)
```

---

### Tap acceptance

#### `tap.session`

Arm the reader for one sale and wait for the customer's tap. **Non-terminal events keep the reader armed** — mirror a physical terminal: an unsupported card or lost contact shows a transient hint on the same waiting screen; only real outcomes (approved / declined / pending / error) end the payment.

```swift
let session = VeyraSoftPOS.shared.tap.session(amountMinorUnits: 32500) { event in
    switch event {
    case .cardDetected:
        // customer's phone connected — "hold steady"
        state = .dialogue
    case .unsupportedTarget:
        // stays armed — transient hint, keep waiting screen up
        hint = "Card not supported — ask for their Veyra wallet and try again"
    case .ended(let outcome):
        // reader session ended without a card: CANCELLED / TIMEOUT / ERROR / UNAVAILABLE
        if outcome != "CANCELLED" { state = .failed("Reader ended (\(outcome)) — try again") }
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

`session(amountMinorUnits:currencyCode:onEvent:)` — `currencyCode` is ISO 4217 numeric (`Int32`, default `566`). Create one session per waiting screen; always `cancel()` on leave. `TapPaymentResult`: `status` (`"APPROVED"` / `"DECLINED"` / `"PENDING"` / `"FAILED"`), `reference` (pass to `transactions.receipt(forReference:)`), `pan`, `errorMessage`.

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
    onExpired: { qrState = .failed("This payment code has expired — start a new payment") }
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

Returns `ScannedCustomerQr`: `maskedCard` (last 4 for display), `amountMinorUnits` (the QR's own amount — confirm, never re-key), `currencyNumeric`.

#### `payments.chargeCustomerQr`

Charge the confirmed QR synchronously over the standard payment rail. A tampered payload or altered amount declines at the server.

```swift
do {
    let scanned = try await VeyraSoftPOS.shared.payments.inspectCustomerQr(payload)
    confirm(scanned.amountMinorUnits, card: scanned.maskedCard)   // merchant confirms the QR's amount
    let outcome = try await VeyraSoftPOS.shared.payments.chargeCustomerQr(scanned)
    lastPaymentReference = outcome.reference       // SDK-submitted reference — use for the receipt
    showResult(approved: outcome.approved, code: outcome.responseCode)
} catch {
    showHint("Not a payment code — try again")     // stay armed for another scan
}
```

`CustomerQrChargeOutcome`: `approved: Bool`, `responseCode`, `transactionID`, `reference`.

---

### Merchant transactions & receipts

The SDK records every payment it takes — tap, get-paid QR and customer-QR charge — locally at its terminal outcome, so history needs no backend round trip.

#### `transactions.history`

```swift
let transactions = try await VeyraSoftPOS.shared.transactions.history(limit: 50)
// MerchantTransaction: reference, rail ("TAP" / "QR_MPM" / "QR_CPM"), amountMinorUnits,
// currencyNumeric, status ("APPROVED"/"DECLINED"/"PENDING"/"FAILED"), responseCode,
// transactionTime, transactionID, maskedTokenLast4, transactionHash
```

`PENDING` means the outcome is not yet known (the SDK keeps polling and updates the stored row); `FAILED` means the payment never reached the server. Hide receipt affordances while a row is `PENDING`.

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

`ActivationCodeResponse`: `tokenUniqueReference`, `expirationDateTime` (ISO-8601 — drive your countdown from it), `status` (`SUCCESS` / `FAILURE`), `message`. **Check `status` even inside a successful result.** Codes are limited-attempt and rate-limited — see [Response codes](#response-codes--error-handling).

#### `activate`

Submit the code the customer received. Success when `status == "SUCCESS"`.

```swift
let response = try await VeyraWallet.shared.tokenisation.activate(
    tokenUniqueReference: ref, activationCode: code)
```

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

`StoredCard`: `tokenUniqueReference`, `panLastFour`, `maskedPAN`, `expiry` (`MM/YY`), `accountHolderName`, `bankName`, `status`, `requiresActivation`, `isActive`, `requiresOnline`.

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

#### `authenticateForScannedPayment`

Biometric confirmation (system prompt; passcode/credential fallback allowed by default). On success the SDK records a **fresh, single-use** authentication — exactly one payment (or one QR render) consumes it. Put the merchant and amount in the prompt so the gesture is visibly bound to what it authorises.

```swift
do {
    try await VeyraWallet.shared.tokenisation.authenticateForScannedPayment(
        reason: "Pay ₦\(payment.amount) to \(payment.merchantName)")
} catch {
    // cancelled/failed — stay on the confirm screen; nothing was sent
    return
}
```

#### `payScannedContext`

Pay the verified context with the wallet's **active card**. Requires the fresh authentication above (the SDK enforces one per payment). The delivered outcome — approved or declined — also lands in the card's history.

```swift
let outcome = try await VeyraWallet.shared.tokenisation.payScannedContext(payment)
showResult(outcome.approved, outcome.responseCode)
// catch VeyraWalletError.onlineRequired — prompt to connect, stay on confirm screen
```

---

### Show QR to pay (customer-presented)

The customer keys nothing at the till: your app asks the amount first (the merchant states it), authenticates, and renders a **dynamic payment QR** with the amount cryptographically bound inside. Fully offline — the merchant's SoftPOS submits the payment; the outcome lands in history via reconciliation.

#### `showQrToPay` + `cancelQrExpiry`

| Parameter | Required | Description |
|-----------|----------|-------------|
| `amountMinorUnits` | **Mandatory** | The merchant-stated amount — bound into the QR's cryptogram; the merchant's scan charges exactly this or fails. |
| `onExpired` | Optional | Fired **once, on the main thread**, when the QR lapses — blank or replace the code (a dimmed QR is still scannable). A new render supersedes the watch; `cancelQrExpiry()` stops it (call on screen teardown). |

Requires a fresh `authenticateForScannedPayment` first — **one authentication per QR**; regenerating after expiry needs a new one.

```swift
try await VeyraWallet.shared.tokenisation.authenticateForScannedPayment(
    reason: "Show a QR to pay ₦\(String(format: "%.2f", Double(amount) / 100))")
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

`TransactionSummary` fields: `merchantName`, `amountInMinorUnit`, `transactionCurrencyCode` (4-digit ISO 4217, e.g. `"0566"`), `authorizationStatus` (`PENDING` / `APPROVED` / `DECLINED` / `FAILED`; `nil` on legacy rows — treat as indeterminate), `entryMethod` (`"TAP"`, `"QR_GENERATED"` — showed a QR, `"QR_SCANNED"` — scanned a merchant QR; `nil` legacy — show nothing rather than guess), `merchantLocation`, `transactionHash` (join key to a receipt), `atEpochMillis`, `merchantTransactionReference`, `merchantId`.

#### `reconcilePendingTransactions`

Reconcile still-`PENDING` rows against the backend. Call it opportunistically: on returning to the foreground, on pull-to-refresh, and on a short loop while a shown QR is on screen (that rail is offline — reconciliation is how its outcome arrives).

```swift
try await VeyraWallet.shared.tokenisation.reconcilePendingTransactions()
```

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
| | `.tokenNotActive(message)` | The card's server-side status is not active (e.g. suspended by the issuer) — **no payment was attempted** | Tell the user the card is suspended/inactive. Don't retry locally — payments resume automatically once a status sync sees the card active again. |
| | `.requestFailed(message)` | Everything else (network, backend, invalid input) | Show `error.localizedDescription` — every case carries its underlying message. |
| `VeyraSoftPOSError` | `.notConfigured` | Any call before `VeyraSoftPOS.configure(_:)` | Configure at launch. |
| | `.tapRefused(message)` | Arming the tap reader was refused — the wallet's payment is mid-flight (combined apps) | "Finish or cancel the current payment first." Never occurs in a SoftPOS-only app. |
| | `.requestFailed(message)` | Backend/network failure | Show the message; offer retry. |
| `VeyraSDKError` | `.notConfigured` | Combined facade used before `VeyraSDK.configure(softpos:wallet:)` | Configure at launch. |

### Tap acceptance — `TapPaymentResult.status`

Terminal outcomes only — unsupported cards and lost contact **never** produce one of these; they fire the re-tap hints and the reader stays armed.

`TapPaymentResult.status` is `"APPROVED"` / `"DECLINED"` / `"PENDING"` / `"FAILED"` (`PENDING` → poll `transactions.status`; `FAILED` → never reached the server, safe to retry). `TapPaymentEvent.ended(outcome:)` (`"CANCELLED"` / `"TIMEOUT"` / `"ERROR"` / `"UNAVAILABLE"`) means the reader session ended **without** a card — recreate the session to keep accepting.

The response codes underneath are shared on the wire across rails; where a code surfaces (`responseCode` fields, history rows), handle it as follows:

| Code | Meaning | Terminal? | What to do |
|---|---|---|---|
| `"00"` | Approved | Yes | Success screen + receipt (`result.reference` → `transactions.receipt(forReference:)`). |
| `"05"` | Declined by the issuer/server | Yes | Show decline; try another card. A stale customer QR also surfaces as `"05"` on the CPM rail — if the customer's code sat on screen a while, ask them to regenerate and rescan. |
| `"06"` | Failed before reaching the issuer — validation, cancellation, merchant not active, wrong mode, read failure after the online boundary | Yes (no money moved) | Fix the input/config and re-initiate; `message` says which check failed. |
| `"99"` | Pending — sent to the issuer, no response received (timeout/network) | Outcome unresolved | **Do not charge again.** The SDK stores the transaction as `PENDING` and keeps polling; show "processing" and let the history row resolve. |
| `"91"` | Issuer unavailable | Same as `"99"` | Same — poll, don't retry-charge. |
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

Exactly three values on both eligibility and digitise responses:

| Code | Meaning | What to do |
|---|---|---|
| `"APPROVED"` | Eligible / provisioned and active | Card is ready — show it in the wallet. |
| `"APPROVE_REQUIRE_AUTH"` | Provisioned, needs activation | Run the activation flow with the returned `activationMethods`. |
| `"DECLINED"` | Refused | Show `message` (it carries the reason — e.g. the account falls outside your configured provision-context allow-lists). Flow ends. |

### Activation — `status` + failure messages

`ActivationCodeResponse.status` / `ActivateResponse.status` are `"SUCCESS"` / `"FAILURE"` — **check `status` even when the call itself succeeds.** On failure the reason is in `message`. Known server messages (observable strings — the SDK adds no codes):

| Message | Meaning | What to do |
|---|---|---|
| *"Activation code expired. Request a new activation code."* | Code lapsed; attempts may remain | Offer "resend code". |
| *"Maximum activation code attempts exceeded."* | The 3-attempt limit for this code is exhausted | The code is dead — request a fresh one; warn the user to check the contact carefully. |
| *"Too many activation code requests for this token. Try again later."* | Re-request rate cap (per token, per hour) | Disable "resend" with a cool-down message. |
| *"No pending activation for this token. Request an activation code first."* | No live code (never requested, or the pending window lapsed) | Request a code first. |
| *"Activation is locked for this token after repeated failed attempts. Contact your issuer."* | Locked after repeated exhausted cycles | Stop the flow — the issuer must unlock; direct the user to their bank. |

### Card lifecycle statuses

The wallet syncs each card's server status automatically (foreground sweeps and around payments). What your app observes:

| Server status | Effect in the SDK | What to do |
|---|---|---|
| `ACTIVE` | Card pays normally | — |
| `SUSPENDED` / `EXPIRED` / `PENDING_ACTIVATION` | Card refuses to pay (`.tokenNotActive`); `StoredCard.status` shows the status | Render the card as unavailable. **Not sticky** — a later sync unfreezes it automatically. |
| `DEACTIVATED` | The card and all its material are wiped and it disappears from `tokens()` | Refresh your card list; the user re-adds the card if needed. |

### Merchant statuses

`ACTIVE` / `INACTIVE` / `SUSPENDED` / `DEACTIVATED` (on registration results, `status()` responses and every payment response's `merchantStatus`). Payments are refused client-side unless the merchant is `ACTIVE` — gate your get-paid entry on `merchant.isRegistered` and the stored merchant's last known status, and call `status(merchantID:)` while awaiting activation.

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
| Code `"99"` / `"91"` / status `PENDING` | Merchant tap | **No — never re-charge** | Outcome unknown at the issuer. Show "processing"; the SDK polls and resolves the history row. Re-charging risks a double charge. |
| Code `"96"` | Any rail | **No — not yet** | Ambiguous: may have succeeded with the response lost. Poll briefly (context status / transaction status / reconcile) before reporting failure. |
| `EXPIRED` context / `onExpired` fired | Get-paid QR | Yes | The QR died unpaid (never recorded). Blank it, offer a fresh one. |
| `inspectCustomerQr` throws | Merchant CPM scan | Yes | Not a payment QR — transient hint, stay armed for another scan. |
| `"05"` on a customer-QR charge | Merchant CPM | Yes (fresh QR) | Could be a stale/hoarded QR: ask the customer to regenerate and rescan before treating it as a funds decline. |
| Scan rejected (`.expired` / `.badSignature` / …) | Wallet MPM scan | Yes (fresh scan) | End the flow; ask the merchant for a fresh code. Never show a rejected payment on a confirm screen. |
| `.authenticationFailed` | Wallet payments | Yes | Nothing was sent. Stay on the confirm screen; let the user retry the biometric. |
| `.onlineRequired` | Wallet payments | After going online | Prompt to connect; the SDK refreshes the card itself. Pre-empt with `requiresOnline` (grey the card out). |
| `.tokenNotActive` | Wallet payments | No (until active) | Card is suspended/inactive server-side. Show why; it unfreezes automatically when a sync sees it active. Don't build retry loops. |
| Digitise `"DECLINED"` | Add card | Per `message` | Show the server's message; the flow ends. Common cause: the account falls outside your provision-context allow-lists. |
| Activation `"FAILURE"` | Activation | Per `message` | Branch on the [known messages](#activation--status--failure-messages): resend on expiry, cool-down on the rate cap, stop entirely on lockout ("contact your issuer"). |
| `.tapRefused` | Combined apps | Yes (after mode settles) | The other mode's payment is mid-flight — prompt to finish/cancel it. |

---

## Data models

Reference for the public models. All are immutable value types; fields not listed here are not public API.

```swift
public struct StoredCard {                  // wallet card display record
    let tokenUniqueReference: String        // identity for activation/removal/status
    let panLastFour: String
    let maskedPAN: String                   // "•••• •••• •••• 1112"
    let expiry: String                      // "MM/YY"
    let accountHolderName: String
    let bankName: String?
    let status: String                      // e.g. "APPROVED", "APPROVE_REQUIRE_AUTH", "SUSPENDED"
    let requiresActivation: Bool
    let isActive: Bool                      // the card payments use
    let requiresOnline: Bool                // grey out + prompt to connect
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
public struct PaymentOutcome { let approved: Bool; let responseCode: String?; let message: String? }
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
    let merchantName: String; let amountInMinorUnit: Int; let transactionCurrencyCode: String?
    let authorizationStatus: String?        // PENDING / APPROVED / DECLINED / FAILED / nil
    let entryMethod: String?                // "TAP" / "QR_GENERATED" / "QR_SCANNED" / nil
    let merchantLocation: String?; let transactionHash: String?
    let atEpochMillis: Int64?; let merchantTransactionReference: String?; let merchantId: String?
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
public enum TapPaymentEvent { case cardDetected, unsupportedTarget, ended(outcome: String), result(TapPaymentResult) }
public struct TapPaymentResult { let status: String; let pan: String?; let errorMessage: String?; let reference: String? }
public struct PaymentContextQR { let txRef: String; let expiry: String?; let kid: String?; let mpmPayload: String }
public struct PaymentContextState { let txRef: String; let state: String; let responseCode: String?; var isSettled: Bool; var isApproved: Bool }
public struct ScannedCustomerQr { let maskedCard: String; let amountMinorUnits: Int64; let currencyNumeric: String }
public struct CustomerQrChargeOutcome { let approved: Bool; let responseCode: String?; let transactionID: String?; let reference: String }
public struct MerchantTransaction { let reference: String; let rail: String; let amountMinorUnits: Int64; let currencyNumeric: String?; let status: String; let responseCode: String?; let transactionTime: String?; let transactionID: String?; let maskedTokenLast4: String; let transactionHash: String? }
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
        │                                       ├─ .unsupportedTarget / contact lost:
        │                                       │    transient hint, stays armed
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
                          authenticateForScannedPayment (Face ID / biometric)
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
