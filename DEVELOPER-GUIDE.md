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

Everything the SDK keeps on the device belongs to **one customer** — the one your app has signed in. You tell the SDK who that is every time you configure it, and call `signOut()` when they log out; see [Customers: signing in, signing out, switching](#customers-signing-in-signing-out-switching).

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
    .package(url: "https://github.com/Iventure-Tech/veyra-sdk-ios", from: "3.0.0"),
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
let sdk = try VeyraSDK.configure(
    customerID: signedInCustomer,
    config: VeyraSDKConfiguration(softpos: softposConfig, wallet: walletConfig),
    provider: provider)
let wallet = try sdk.wallet       // VeyraWallet.shared
let softpos = try sdk.softpos     // VeyraSoftPOS.shared

// when the customer logs out:
VeyraSDK.signOut()
```

**Members:**

| Member | Parameters | Description |
|--------|------------|-------------|
| `configure(customerID:config:provider:)` | The signed-in customer's id, both member configurations as a `VeyraSDKConfiguration(softpos:wallet:)`, and your one provider (shared by both SDKs — see [Connecting to Veyra](#connecting-to-veyra)). Same order as Android and React Native | Returns `VeyraSDK.shared` (`@discardableResult`). **Throws** (`.invalidConfiguration(message:)` when the provider is unusable). Configures both SDKs for that customer, plus the exclusive-mode arbiter. **Call at every launch** — the SDK never remembers who is signed in. The process starts **inert**; safe to call again (reconfigures, stays inert). A different customer stops the previous customer's work in both SDKs. `customerID` must not be blank (a blank one throws `.invalidConfiguration`). The wallet sends it to Veyra on its card requests (add card, eligibility, activation) so support can find the customer; SoftPOS never sends it, and device logs only ever show it masked. |
| `signOut()` | — | Static. The customer has logged out: both member SDKs stop everything they run for them and drop every observer registration. Their cards, merchant and history stay on the device for when they sign in again. |
| `shared` | — | The singleton. |
| `wallet` / `softpos` | — | The member SDKs (`VeyraWallet.shared` / `VeyraSoftPOS.shared`), as Android's `VeyraSdk.wallet` / `.softpos` and RN's `Veyra.wallet` / `.softpos`. Throwing properties: `VeyraSDKError.notConfigured` before `configure`. |
| `currentMode()` | — | The current exclusive mode (`VeyraMode.none` / `.softpos` / `.wallet`). Read-only observation for UI state — the mode itself is entirely SDK-managed. **Throws** `VeyraSDKError.notConfigured` before `VeyraSDK.configure(...)`. The sample reads it as `(try? VeyraSDK.shared.currentMode()) ?? .none`. |

In a standalone single-product app (only `VeyraSoftPOS` *or* only `VeyraWallet`), configure that product directly and skip `VeyraSDK` entirely.

### `VeyraSoftPOS` (merchant features)

```swift
// standalone; combined apps configure via VeyraSDK
try VeyraSoftPOS.configure(customerID: signedInCustomer, config: configuration, provider: provider)
let merchant = VeyraSoftPOS.shared.merchant
```

**Members:**

| Member | Description |
|--------|-------------|
| `configure(customerID:config:provider:)` | Configure the SDK for the customer your app has signed in, reaching Veyra through `provider`. Returns `VeyraSoftPOS.shared` (`@discardableResult`). **Throws** `VeyraSoftPOSError.invalidConfiguration` when the provider is unusable or is of a different kind from the one already in use. **Call at every launch**, before any service use (subsequent calls reconfigure). The merchant and its transactions are kept per customer: the same customer again changes nothing; a different customer stops the previous customer's watches and opens the new customer's merchant. `customerID` must not be blank (a blank one throws `.invalidConfiguration`); SoftPOS never sends it off the device. |
| `signOut()` | Static. The customer has logged out: stops every merchant watch and drops every observer registration. Their merchant and transactions stay on the device. Until the next `configure` every call throws `VeyraSoftPOSError.notSignedIn`. |
| `shared` | The singleton. |
| `merchant` | Merchant lifecycle — registration, status, activate/deactivate, profile update, banks, stored merchant, and `onMerchantStatusChanged` (the SDK watches the merchant's backend status for you). |
| `tap` | Contactless tap acceptance — the customer's Android Veyra wallet taps this iPhone. |
| `payments` | QR payments — create/poll a get-paid QR (merchant-presented) and inspect/charge a customer QR (consumer-presented) — and `cancelPayment(merchantOrderID:)`, which cancels any merchant payment (tap, charge or QR create) while it is still on the phone (see [Cancelling a call](#cancelling-a-call)). |
| `transactions` | Transaction queries — local history, receipts, status polling — and the two deferred-answer observers (`onTransactionResolved`, `onCreditConfirmation`). |

### `VeyraWallet` (wallet features)

```swift
// standalone; combined apps configure via VeyraSDK
let wallet = try VeyraWallet.configure(customerID: signedInCustomer, config: configuration, provider: provider)
```

**Members:**

| Member | Description |
|--------|-------------|
| `configure(customerID:config:provider:)` | Configure the SDK for the customer your app has signed in, reaching Veyra through `provider`. Returns `VeyraWallet.shared` (`@discardableResult`). **Throws** `VeyraWalletError.invalidConfiguration` when the provider is unusable or is of a different kind from the one already in use. **Call at every launch**, before any service use (subsequent calls reconfigure). Cards, keys, history and receipts are kept per customer: the same customer again changes nothing and downloads nothing; a different customer stops the previous customer's work and opens the new customer's cards. `customerID` must not be blank (a blank one throws `.invalidConfiguration`). It is sent to Veyra on the wallet's card requests (add card, eligibility, activation) so support can find the customer; device logs only ever show it masked. |
| `signOut()` | Static. The customer has logged out: stops everything the wallet runs for them (key top-ups, status syncs, history sweeps) and drops every observer registration. Their cards, keys, history and receipts stay on the device. Until the next `configure` every call throws `VeyraWalletError.notSignedIn`. |
| `shared` | The singleton. |
| *wallet operations* | Every wallet operation is a method on `VeyraWallet.shared` — bank lookup, eligibility, digitise, activation, tokens, payments, history, receipts, observers — plus `cancelDigitise(clientRequestID:)` and `cancelPayment(merchantOrderID:)` (scan to pay), which cancel a call while it is still on the phone (see [Cancelling a call](#cancelling-a-call)). The guide's examples hold it as `let wallet = VeyraWallet.shared`. The same operations, on the same owner, as Android's `VeyraWalletSdk` and React Native's `wallet`; Swift drops the `get` prefix (`tokens()` where the others say `getTokens()`). |
| `transactions(tokenUniqueReference:limit:)` | The card's transaction history, most recent first (`limit` default 50). Local read. See [`transactions`](#transactions). |
| `openPaySession()` / `closePaySession()` / `isPaySessionOpen()` | The tap-to-pay pay session — the same three calls as Android and React Native, so one integration runs everywhere. iPhone cannot pay by tap, so `openPaySession()` always answers `PaySessionResult` `FAILED` / `NFC_UNAVAILABLE` (the same answer an Android phone without NFC gives — offer QR), `closePaySession()` does nothing, and `isPaySessionOpen()` returns `false`. |
| `paymentApplicationInstanceID()` | This install's SDK-generated `payment_application_instance_id` (`VYRA` + 32 hex chars): minted on first use, persisted install-scoped (never backed up), new on reinstall. Read-only. |

---

## Connecting to Veyra

You pass **one provider** to `configure`, and it says how the SDK reaches the Veyra backend. The
same provider serves both SDKs. There is **no default**: which kind you implement is your decision
as the payment app provider. `VeyraProvider`, `VeyraAssertionProvider`, `VeyraProxyProvider`,
`VeyraProviderType` and `VeyraRelayError` come with `import VeyraWallet` / `import VeyraSoftPOS`.

### Choosing a provider

| Provider | `providerType` | The SDK… | Choose it when |
|---|---|---|---|
| `VeyraAssertionProvider` | `.authentication` | calls Veyra itself, with a token it obtains by exchanging a short-lived **assertion your backend signs** for the signed-in user | your backend can sign a JWT for the logged-in user (recommended) |
| `VeyraProxyProvider` | `.proxy` | calls **nothing** itself: every call is handed to your provider, which forwards it through **your backend** | you want all traffic through your own backend, or cannot run a signer |

**The protocol you conform to is the method.** Each protocol supplies its `providerType` by default,
so you never set a mode: the SDK reads it from the provider you pass.

Rules that hold for every provider:

- **One provider for both SDKs.** `VeyraSDK.configure` passes it to both; a standalone app passes
  it to the one SDK it uses. Each SDK still keeps its own token cache and device key.
- **`configure` throws** `.invalidConfiguration(message:)`, naming the problem, for: a type that
  conforms to both protocols; a `providerType` that contradicts the protocol it conforms to; and a
  blank `clientId` — never at the first payment. (Swift also makes a type that conforms to both
  pick its own `providerType`, because the two defaults clash.)
- **One kind per process, with no fallback.** A `VeyraAssertionProvider` whose `assertion` returns `nil`
  ends the call with reason `NOT_AUTHENTICATED` (`NOT_SENT` on a payment or an add-card, `FAILED` on any other call); the SDK never tries another method. Configuring again with the
  other kind throws `.invalidConfiguration`.
- **Every `configure` re-binds the provider** — the one you pass is the one the SDK uses from then
  on, including from its own background work.
- **A call is never sent without credentials.** When the SDK cannot obtain a token, the call ends
  with reason `NOT_AUTHENTICATED` and nothing is sent — `NOT_SENT` on a payment or an add-card,
  `FAILED` on any other call.
- Every backend call (token requests included) carries `X-Veyra-Sdk-Version` and
  `X-Veyra-Provider-Type` (your provider's `providerType`: `AUTHENTICATION` or `PROXY`).

### Implementing a provider

**`VeyraAssertionProvider`** — your client id, and one function that gets an assertion from your
backend. The SDK calls it only when it needs a new token:

```swift
struct MyAssertionProvider: VeyraAssertionProvider {
    let clientId = "your-client-id"                    // public, issued at onboarding
    let bank: MyBankAPI

    /// A JWT from your backend for the signed-in user, or nil when nobody is signed in.
    func assertion(audience: String, jkt: String) async throws -> String? {
        try await bank.sdkAssertion(audience: audience, jkt: jkt)   // e.g. a token exchange at your authorization server
    }
}
```

**`VeyraProxyProvider`** — one function, `send`. The SDK calls it for every backend call; the
envelope it passes names the HTTP method:

```swift
struct MyProxyProvider: VeyraProxyProvider {
    let bank: MyBankAPI
    func send(_ request: String) async throws -> String { try await bank.veyraProxy(request) }
}
```

`bank.veyraProxy` sends the envelope to `POST {your API gateway}/issuertokengateway/v1/proxy` and returns
Veyra's body unchanged. On failure it throws `VeyraRelayError`, saying whether the request was sent
— see [the failure contract](#the-proxy-providers-failure-contract).

**Proxy flow.** For the proxy provider, **deploy the Veyra Issuer Token Gateway (ITG): it supports
proxying all SDK requests.** It obtains an access token from the Veyra token endpoint and calls the
Veyra API for you, so you write no proxy code of your own on the server:

```
Your app ── VeyraProxyProvider.send(envelope)
  │
  ├─▶ Your (issuer) API gateway / authorisation server
  │     POST /issuertokengateway/v1/proxy — checks your app's session,
  │     removes the /issuertokengateway/v1 context
  │
  ├─▶ Veyra Issuer Token Gateway (ITG)          POST /proxy
  │     ├─▶ Veyra token endpoint                 client-credentials grant (the ITG's own
  │     │                                        credentials) → access token, cached until expiry
  │     └─▶ Veyra API                            method + service path, query, headers, body,
  │                                              with Authorization
  │
  ◀── Veyra's status and body, unchanged (or 200 PROXY_FAILED from the ITG itself)
```

### Configuring with your provider

```swift
let provider = MyAssertionProvider(bank: bankAPI)          // or MyProxyProvider(bank: bankAPI)

do {
    try VeyraSDK.configure(
        customerID: signedInCustomer,
        config: VeyraSDKConfiguration(
            softpos: .init(environment: .test, paymentAppProviderID: providerID),
            wallet: .init(environment: .test, paymentAppProviderID: providerID,
                          tokenRequestorID: requestorID, appleTeamID: teamID)),
        provider: provider)
} catch {
    // .invalidConfiguration(message:) names the problem — a setup error, fix the provider.
}
// …or standalone: try VeyraSoftPOS.configure(customerID:, config: softposConfig, provider:)
//                  try VeyraWallet.configure(customerID:, config: walletConfig, provider:)
```

The sample has no mode setting either: `AppProvider.provider()` in
`VeyraBank/AppProvider.swift` returns one provider, and to switch you return a different one —
exactly what your own app does. Its two backend providers, `BankBackendAssertionProvider` and
`BankBackendRelay`, are short and meant to be copied; each reads only its own values from
`Config/Veyra.xcconfig` (the assertion provider: `VEYRA_CLIENT_ID`, which is all the SDK receives,
plus `VEYRA_BANK_BACKEND_BASE_URL` and your bank's own client `VEYRA_BANK_CLIENT_ID` /
`VEYRA_BANK_CLIENT_SECRET` for the token exchange; the proxy provider: `VEYRA_BANK_BACKEND_BASE_URL`
and the same bank client; both also log the user in with `VEYRA_USERNAME` / `VEYRA_PASSWORD`). The
sample ships returning the proxy provider (`BankBackendRelay`), so the app holds no Veyra secret. The
deprecated `ClientSecretCredentials` — a `VeyraClientSecretProvider` **for testing only** that needs
just `VEYRA_CLIENT_ID` and `VEYRA_CLIENT_SECRET` — is still there for testing before your backend
has either endpoint.

### Your bank backend — the two endpoints the sample calls

> **Signing the user in to your bank is your app's responsibility, not the SDK's.** The SDK never
> authenticates with your bank or its backend. It doesn't collect credentials, it doesn't obtain,
> refresh or end a bank session, and it doesn't call your login or token endpoints. It only asks your
> provider for what it needs: an assertion (`VeyraAssertionProvider`), or to send a request
> (`VeyraProxyProvider`). Your provider gets those using the session your app already holds. How the
> user signs in (password, biometrics, single sign-on, multi-factor), and how that session is stored,
> refreshed and revoked, is your app's own design. The sample's password-grant login, with credentials
> read from local config, is a demo stand-in only — not a pattern to ship.

`VeyraAssertionProvider` and `VeyraProxyProvider` each need one endpoint on **your** side. Both
carry your app's **own** session: the sample logs in with `VEYRA_USERNAME`/`VEYRA_PASSWORD` from `Config/Veyra.xcconfig` — a password
grant at `{bankBackendBaseUrl}/oauth2/token` — and uses the returned access token; replace that with
your own login. Neither is a Veyra credential.

```
POST {your backend}/oauth2/token                           (VeyraAssertionProvider)
     RFC 8693 token exchange, application/x-www-form-urlencoded,
     Authorization: Basic base64(<bank client id>:<bank client secret>)
     grant_type=urn:ietf:params:oauth:grant-type:token-exchange
     subject_token=<the user's session>
     subject_token_type=urn:ietf:params:oauth:token-type:access_token
     requested_token_type=urn:ietf:params:oauth:token-type:jwt
     audience=<audience>
  →  200 {"access_token": "<compact JWT>", …}   401 when no user is signed in (the provider returns nil)

POST {your API gateway}/issuertokengateway/v1/proxy (VeyraProxyProvider)
     body: the SDK's envelope, unchanged, for every method
  →  your gateway checks the app's session, removes the `/issuertokengateway/v1` context and
     forwards the envelope to the Veyra Issuer Token Gateway (ITG) as `POST /proxy`
  →  the ITG gets an access token from the Veyra token endpoint with its own OAuth
     client credentials (held server-side; an API key is not accepted), calls the
     Veyra API (`service` + `path` with `method`, `query`, `headers` and `body`),
     and answers with Veyra's status and body unchanged
```

**Your authorization server signs** the exchanged token — a compact JWT, with the signing key held in an HSM or KMS:

**Required by Veyra — the minimum.** How you produce the assertion is up to you: your own
endpoint, your authorization server's token exchange (RFC 8693), or any identity provider. Veyra
checks only the following. An assertion that is missing any of them, or fails a check, is refused,
and the SDK reports `NOT_AUTHENTICATED`.

| Part | What to put in it | Why Veyra needs it |
|---|---|---|
| Signature (`alg`) | `ES256`, `ES384`, `PS256` or `RS256` (the ones agreed for your issuer), signed with a private key held in an HSM or KMS. Never `none` or an HMAC (`HS…`) algorithm | Veyra verifies it with your **public** key (your JWKS URI, or keys you registered). That proves the assertion came from you, and Veyra can never create one itself |
| `kid` (header) | The id of the signing key in your JWKS. It can be left out only if you publish exactly one key | Picks the key to verify with, so you can rotate: publish the new key, then start signing with it |
| `iss` | Exactly the issuer identifier registered with Veyra, character for character | Tells Veyra whose keys and rules apply. An unknown or disabled issuer is refused |
| `sub` | A stable, pairwise identifier for the signed-in user: the same value every time for that user. Never an account number, customer id, phone number or email | Veyra derives its own user id from `iss` + `sub`, so the same person is recognised across sessions and devices without you sharing who they are |
| `aud` | The `audience` the SDK passed to your provider (the Veyra API base URL: `https://api.uat.veyra.co` on `TEST`, `https://api.veyra.co` on `LIVE`), or the alias agreed at onboarding | Addresses the assertion to Veyra only, so no other service that trusts your key can accept it |
| `iat` | When you issued it, in seconds since the epoch | Must not be in the future (Veyra allows 60 seconds of clock difference). Together with `exp`, it bounds the assertion's life |
| `exp` | The expiry: at most your agreed maximum after `iat`, which is **5 minutes** unless agreed otherwise | Limits how long a leaked assertion could be used. An expired one is refused |
| `jti` | A new unique id for every assertion, e.g. a UUID | Veyra accepts each `iss` + `jti` only once, so a captured assertion can't be replayed |

**Optional:**

| Claim | What to put in it | Why |
|---|---|---|
| `cnf.jkt` *(recommended)* | Exactly the `jkt` the SDK passed to your provider | Binds the assertion to this device's key. If it's present, Veyra refuses the assertion unless it matches the key the SDK proves it holds, so a leaked assertion is useless on any other device. Veyra can make it mandatory for your issuer if you agree to that |
| `acr` | The authentication level of the user's session, from the values agreed at onboarding | Needed only if Veyra sets a minimum level for your issuer, e.g. to require multi-factor sign-in. Below the minimum, the assertion is refused |
| `nbf` | A not-before time | Honoured if present |

**Only the required claims above are mandatory.** `cnf.jkt`, `acr` and `nbf` are optional: include
`acr` only if Veyra has agreed a minimum sign-in level for your issuer. Any other claim is ignored.

**Device binding between your app and your backend is optional.** You don't have to bind the
assertion to the device, either with `cnf.jkt` or by using DPoP on your own token
endpoint. Veyra accepts an unbound assertion that meets the minimum above. Either way, the SDK
always uses DPoP with Veyra: the access token it gets is bound to a key generated on this device
that cannot be exported. **What binding adds:** without it, an assertion that leaks in its few
minutes of life could be redeemed once by another device. With it, it can't be redeemed anywhere
else.

Issue it only for an authenticated session of the user it names, and rate-limit the endpoint. The
SDK calls the provider only when it holds no valid token (first call, expiry, or a token the server
refused), never more than once at a time. `jkt` is the thumbprint of this install's
proof-of-possession key; the access token is bound to that key, which is generated on the device
and cannot be exported (Secure Enclave). Returning `nil` or throwing ends the call with reason
`NOT_AUTHENTICATED` and sends nothing (`NOT_SENT` on a payment or an add-card, `FAILED` on any other call). `signOut()` drops cached tokens but keeps the per-install key.

`audience` is the base URL of the Veyra API the SDK will redeem the assertion at
(`https://api.uat.veyra.co` on `TEST`, `https://api.veyra.co` on `LIVE`). **Check it before you
sign:** copy it into `aud` only when it is a Veyra base URL you expect for that environment, and
refuse anything else, so an assertion your backend signs can never be redeemed anywhere but Veyra.

**`/issuertokengateway/v1/proxy` receives the envelope (version 1, public API).** Each `request` your
proxy provider receives is one JSON string that says everything about the call:

```json
{ "version": 1,
  "service": "SOFTPOS",
  "method": "POST",
  "path": "/payment",
  "query": { "merchant_id": "…" },
  "headers": { "Content-Type": "application/json",
               "X-Veyra-Sdk-Version": "3.0.0",
               "X-Veyra-Provider-Type": "PROXY" },
  "body": "<the request JSON, as a string>" }
```

- `service` is the Veyra API the call is for: `WALLET` or `SOFTPOS`. It names the API, not your
  SDK — a wallet call to the payment API is `SOFTPOS`. Your proxy backend routes on it.
- `method` is the HTTP method the ITG uses towards Veyra. Because the envelope names it, the
  provider has a single `send` and every call goes to one endpoint.
- `path` is relative to that service — never a full URL, and without any API prefix.
- `query` is omitted when there is none (values are decoded). `body` is absent on `GET` and `DELETE`.
- New fields may be added under the same `version`; a breaking change bumps `version`.
- When your proxy backend itself cannot complete a call it answers `200` with
  `{"response_status": "PROXY_FAILED", "response_status_reason": "…", "never_sent": true|false}`.
  Return that body unchanged like any other: the SDK recognises it. `never_sent: true` ends the
  call as a refused connection does (below); `false` or absent, as a timeout does.
- **Return Veyra's response body exactly as Veyra returned it.** If Veyra answered with a non-200
  status, throw `VeyraRelayError(kind: .other, neverSent: false, httpStatus: status)` rather than
  inventing a body — the SDK treats it exactly as that status on a direct connection.

### The proxy provider's failure contract

A proxy provider signals failure by throwing `VeyraRelayError(kind:neverSent:httpStatus:)`, and **must say
whether the request was sent**:

- `neverSent: true` **only** when the request provably never left the device — no network, or the
  connection was refused before anything was written. A payment or a digitisation then ends
  `NOT_SENT` / `SDK_UNABLE_TO_CONNECT` (retry with the same order ID); any other call ends `FAILED` /
  `SDK_UNABLE_TO_CONNECT`. When the kind is `.noNetwork` the reason is `NO_NETWORK_CONNECTION` instead.
- `neverSent: false` when it may have been delivered — a timeout, a lost connection, a non-2xx
  answer, or whenever you cannot tell. The payment stays `PENDING` and the SDK reconciles it. **When
  in doubt, `false`**: it is the safe direction.
- `httpStatus` when your backend answered with a non-2xx status.
- **Any other error** counts as `neverSent: false`, and so does a call that outlives the SDK's
  own timeout.

The sample's `BankBackendRelay.classify` is the reference: `.notConnectedToInternet`,
`.cannotFindHost`, `.dnsLookupFailed`, `.dataNotAllowed`, `.internationalRoamingOff` → `.noNetwork`,
never sent; `.cannotConnectToHost` → `.connectionRefused`, never sent; `.timedOut` → `.timeout`, may
have been sent; anything else → `.other`, may have been sent.

**Your proxy provider is called from background work too** — status polling, payment-key refresh and credit
confirmations run on the SDK's app-scoped loops — so it must not depend on a screen being up (the
sample's is a plain struct with no view reference). Before your app has configured the SDK
there is no provider, and those cycles skip without failing.

**What your backend can see.** Request and response bodies pass through your app and backend. Key
material is end-to-end encrypted to the device and payment proofs are MACed, so your backend cannot
read or forge either; it **can** read account and identity fields, and it could alter plain answers
such as a transaction status. That is acceptable only because you, the provider, already hold that
data. **Forward the bytes unmodified.** The SDK's log export does not go through your provider.

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
    paymentAppProviderID: "your-payment-app-provider-id"
)
```

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `environment` | **Mandatory** | `.test` or `.live`. Endpoints resolve from the SDK's defaults — no URLs to supply. |
| `paymentAppProviderID` | **Mandatory** | Your payment app provider id, issued at onboarding (the same identifier as the wallet configuration's). Sent on merchant registration/update; the gateway resolves your acquirer id and MCC from it. |

### `VeyraWalletConfiguration`

```swift
let walletConfig = VeyraWalletConfiguration(
    environment: .test,
    paymentAppProviderID: "your-provider-id",
    tokenRequestorID: "50100000001",
    appVersion: "1.2.0",
    appleTeamID: "YOURTEAMID1",            // your Apple Developer Team ID
    allowedAcquirerIDs: ["ACQ001"],
    allowedMerchantIDs: ["MERCHANT01"]
)
```

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `environment` | **Mandatory** | `.test` or `.live`. Endpoints resolve from the SDK's defaults. |
| `paymentAppProviderID` | **Mandatory for wallet operations** | Your payment-app provider identifier (eligibility/digitise fail without it). |
| `tokenRequestorID` | **Mandatory for wallet operations** | Scheme-assigned token requestor ID. |
| `appleTeamID` | **Mandatory** | Your app's Apple Developer Team ID (e.g. `"ABCDE12345"`). Together with the bundle ID it forms the App Attest app ID (`teamID.bundleID`) that device attestation binds to and the backend verifies — it attests **your** app, so this is your team, not Veyra's. Digitise fails fast if missing. |
| `bundleID` | Optional | Override for the app's bundle ID (the attestation binding suffix). Normally leave `nil` — auto-detected from `Bundle.main`. |
| `appVersion` | Optional | App version reported during digitise. Default `"1.0.0"`. |
| `allowedAcquirerIDs` / `allowedMerchantIDs` | Optional | Provision-context allow-lists your app decides. |

> There is **no** `paymentApplicationInstanceID` parameter — the SDK mints and persists an install-scoped one and sends it on every eligibility/digitise request; read it via `VeyraWallet.shared.paymentApplicationInstanceID()`. A restricted provision-context dimension that a payment then falls outside of is declined by the server.

### `Environment`

One shared enum for both products (nested `Environment` on each configuration).

| Value | Description |
|-------|-------------|
| `.test` | Test / staging servers. A provider is required at `configure`. |
| `.live` | Production servers. A provider is required at `configure`. |

Server hosts and endpoint paths are resolved by the SDK from the environment — you never supply URLs.

### Device type

**Detected, not configured** — the SDK reports `TABLET` on iPad and `MOBILE` otherwise.
There is no configuration parameter for it.

---

## Exclusive mode (combined apps)

A combined app is always in exactly one mode: **none**, **receiving** (SoftPOS) or **paying** (Wallet). The SDK manages this for you:

- **Claims are automatic.** The SDK claims a mode at the point of use — starting a tap session claims receiving, executing a wallet payment claims paying — and releases it when the session ends or the payment completes. Backgrounding the app drops it to inert. There is no mode API to call and no `.onAppear`/`.onDisappear` choreography; `currentMode()` is available read-only for UI state.
- **Starts inert, never persisted.** The mode follows your payment activity, not your screens; the app always starts with no mode active — even after being killed mid-payment.
- **Atomic.** The outgoing capability is fully torn down before the incoming one arms. A merely-armed (untapped) tap payment is cancelled automatically on a switch; a genuinely mid-flight payment refuses the switch instead.

**Cross-mode refusals.** If a tap session is armed while a wallet payment is genuinely mid-flight (or vice versa), the claim is refused — the payment ends `NOT_SENT` with reason `MODE_REFUSED`. Treat it as "finish or cancel the current payment first" and prompt the user. **This never occurs in a standalone single-product app.**

---

## Customers: signing in, signing out, switching

The SDK keeps **everything per customer**: the wallet's cards, payment keys, history and receipts, and the SoftPOS merchant and its transactions. Two people sharing one phone — or one person with two accounts in your app — each see only their own. The customer is whoever **your app** has authenticated; the SDK does not log anyone in and never remembers who is signed in.

```swift
// At every launch, once your app knows who is logged in:
try VeyraSDK.configure(customerID: session.customerID,
                       config: VeyraSDKConfiguration(softpos: softposConfig, wallet: walletConfig),
                       provider: provider)
registerObservers()            // observers belong to the signed-in customer

// When the customer logs out:
VeyraSDK.signOut()
```

- **Pass the id every launch.** `customerID` is required on every `configure` — there is no "last customer" the SDK falls back to. If nobody is logged in, don't configure; call `configure` when they sign in. Use a stable identifier for the customer from your own system. On the device, only a one-way hash of it names the files and Keychain entries the SDK writes; the wallet sends it to Veyra on its card requests (add card, eligibility, activation) so support can find the customer, and device logs only ever show it masked.
- **Same customer again** — nothing is stopped and nothing is downloaded; calling `configure` at every launch is free.
- **A different customer** — the previous customer's work (key top-ups, status syncs, history sweeps, merchant watches) is stopped, and the new customer's cards and merchant are opened. Nothing of the previous customer's is deleted: it is waiting for them when they sign in again.
- **`signOut()`** stops every loop, sweep, watch and observer the SDK runs for the customer. Their cards, **payment keys**, history, receipts, merchant and transactions all **stay on the device**. Signing the same customer back in downloads nothing for cards that still have keys; a card that has none gets them in the background.
- **Register observers again after `configure`.** Observer registrations (`observeTokenStatusChanged`, `observeCardKeyStateChanged`, `observePaymentRefusals`, `observeTransactionResolved`, `merchant.onMerchantStatusChanged`, `transactions.onTransactionResolved`, `transactions.onCreditConfirmation`, …) are dropped on a customer switch and on sign-out, so one customer's events can never reach another's screens. Register them again after every `configure`.
- **After `signOut()`**, every call throws `VeyraWalletError.notSignedIn` / `VeyraSoftPOSError.notSignedIn` until the next `configure`. (`.notConfigured` still means `configure` was never called in this process.) Gate your wallet and get-paid entry points on your own logged-in state.
- **Uninstalling the app** removes every customer's data. There is no API to wipe the device for all customers.

The sample app shows the pattern on its Home screen: a customer bar with **Switch** (signs in the other demo customer), **Sign out** and **Sign in**, with the wallet and get-paid tiles disabled while signed out.

---

## SoftPOS — accepting payments

Service accessors: `VeyraSoftPOS.shared.merchant`, `.tap`, `.payments`, `.transactions`. All async methods throw `VeyraSoftPOSError` only for setup mistakes — everything else comes back as an outcome (see [Errors and outcomes](#errors-and-outcomes)) — and deliver events on the main queue.

### Merchant registration & profile

A device must have a **registered, active merchant** before it can accept payments. Registration persists the merchant on the device for the signed-in customer (SDK-owned storage, cleared on uninstall; a later successful registration overwrites it); the backend assigns the merchant ID, terminal ID and category code.

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
        bvn: "12345678901",                // optional for both merchant types
        cacNumber: nil,                    // .business only
        accountNumber: "1234567890",       // settlement NUBAN account
        institutionCode: "000000",         // from merchant.banks()
        walletAccountID: nil               // optional
    )
)
switch result.responseStatus {
case VeyraResponseStatus.approved:
    // SDK persisted the merchant (backend-assigned fields win); unlock Get paid
    unlockGetPaid(result.merchantID)
case VeyraResponseStatus.notSent:
    // Never reached Veyra (offline, NOT_AUTHENTICATED…): fix the reason and submit again
    showError("Not sent (\(result.responseStatusReason ?? "?"))")
case VeyraResponseStatus.pending:
    // Sent, no usable answer: read merchant.status(merchantID:) before registering again
    showChecking()
default:
    // FAILED: the reason names the field or rule, e.g. ACCOUNT_NUMBER_REQUIRED
    showError("Registration refused (\(result.responseStatusReason ?? result.responseStatus))")
}
```

`MerchantRegistrationResult`: `responseStatus` (`APPROVED` · `FAILED` · `PENDING`; a registration that never reached Veyra is `FAILED` with the reason, e.g. `NO_NETWORK_CONNECTION`), `responseStatusReason`, `success: Bool` (the same fact as `responseStatus == "APPROVED"`), `merchantID: String?` (set on `APPROVED`), `terminalID: String?`, `merchantStatus: String?`, `message: String?`. Every registration ends with an outcome — validation problems come back as `FAILED` with the field named in `responseStatusReason`; nothing throws but a [setup error](#setup-errors--thrown). A `PENDING` registration may have been made: check `merchant.status(merchantID:)` before registering again.

---

#### `merchant.banks`

Fetch the NUBAN settlement banks for the registration/update bank picker. A read: it returns a `SettlementBankList` outcome — `APPROVED` with the banks, or `FAILED` with the reason there are none (`NO_NETWORK_CONNECTION` when the phone is offline). Never `PENDING`; retrying as is is always safe.

```swift
let list = try await VeyraSoftPOS.shared.merchant.banks()   // SettlementBankList
guard list.responseStatus == VeyraResponseStatus.approved else {
    errorText = list.responseStatusReason == "NO_NETWORK_CONNECTION"
        ? "No internet connection — connect and try again."
        : "Could not load settlement banks (\(list.responseStatusReason ?? list.responseStatus))."
    return
}
let banks = list.banks   // [SettlementBank]: slug, name, institutionCode
```

`SettlementBankList`: `banks`, `responseStatus`, `responseStatusReason`, `message`. Pass the chosen bank's `institutionCode` to registration.

---

#### Merchant status — `merchant.status` / `activate` / `deactivate`

| Member | Description |
|-----|-------------|
| `merchant.isRegistered: Bool` | `true` when a complete merchant (ID, terminal, name, acquirer, MCC, country) is stored on this device. Gate your Get-paid entry on it. |
| `merchant.stored: StoredMerchant?` | The persisted merchant, or `nil`. |
| `merchant.status(merchantID:)` | Current backend status → `MerchantStatus`; on `APPROVED`, `status` is set (e.g. `"ACTIVE"`, `"DEACTIVATED"`) and the stored merchant's status is refreshed. A read — never `PENDING`. |
| `merchant.activate(merchantID:)` / `deactivate(merchantID:)` | Backend activate/deactivate → `MerchantStatus`. |

`MerchantStatus` is an outcome: `responseStatus`, `responseStatusReason`, `message`, plus `merchantID: String?` and `status: String?` when the gateway answered. Branch on `responseStatus`:

| `responseStatus` | Meaning | What to do |
|---|---|---|
| `APPROVED` | Answered — `status` is the merchant's state | Render it |
| `FAILED` | Refused, e.g. `MERCHANT_NOT_FOUND`, or `INVALID_REQUEST` (the change isn't allowed from the current state) — or it never reached Veyra (`NO_NETWORK_CONNECTION`, `NOT_AUTHENTICATED`, …), so nothing was done | Show the reason; fix it and try again |
| `PENDING` | Activate / deactivate / update sent with no usable answer | Read `status(merchantID:)` before trying again |

```swift
let status = try await VeyraSoftPOS.shared.merchant.activate(merchantID: merchantID)
message = status.responseStatus == VeyraResponseStatus.approved
    ? "Merchant activated (\(status.status ?? "?"))"
    : "Could not activate (\(status.responseStatus) · \(status.responseStatusReason ?? "?"))"
```

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
if status.responseStatus != VeyraResponseStatus.approved {
    showError(status.responseStatusReason ?? status.responseStatus)   // FAILED / PENDING
}
```

Returns `MerchantStatus` — the same outcome as `status`/`activate`/`deactivate` above. Only an answered update (`merchantID` set) is folded into the stored merchant.

---

### Tap acceptance

#### `tap.session`

Arm the reader for one sale and wait for the customer's tap. **Non-terminal events keep the reader armed** — mirror a physical terminal: an unsupported card or lost contact shows a transient hint on the same waiting screen; only real outcomes (approved / declined / failed / pending / retry / not sent) end the payment.

**The screen stays awake while a payment is live.** From the moment a tap payment starts until its
result arrives, or the reader ends without a card, the SDK keeps the iPhone from auto-locking. A screen
that locks ends the card-reading session. It does this with the app's idle timer
(`UIApplication.isIdleTimerDisabled`), and shares it carefully:
- It switches the idle timer off only if it was on, and turns it back on only if it was the one that
  switched it off. An app that keeps its own screen on is left alone.
- Overlapping taps never release each other's hold.
- If your app manages the idle timer itself, set it before starting a tap. A change your app makes
  during a tap can't be told apart from the SDK's own.

```swift
let session = VeyraSoftPOS.shared.tap.session(
    amountMinorUnits: 32500,
    merchantOrderID: "ORDER-1042"   // required — your own order id, never a key
) { event in
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
        // terminal outcome: result.responseStatus APPROVED / DECLINED / FAILED / PENDING / RETRY / NOT_SENT
        // NOT_SENT / CANCELLED: your cancel stopped it before it was sent — go back to amount entry
        lastPaymentReference = result.reference   // for the receipt afterwards
        // NOT_SENT / RETRY: nothing was charged — retry this order with the same order id
        retryOrderID = [VeyraResponseStatus.notSent, VeyraResponseStatus.retry]
            .contains(result.responseStatus) ? orderID : nil
        state = .result(result)
    }
}
do {
    try session.start()      // arms the reader (claims receiving mode at the point of use)
} catch {
    // Only a setup error throws here (e.g. .invalidConfiguration when both SDKs are in the app
    // without VeyraSDK). A refused mode claim (MODE_REFUSED) or a blank order id
    // (INVALID_REQUEST) arrives as a NOT_SENT .result instead.
}
// Cancel button, and when the screen leaves: cancel by the order ID (see Cancelling a call).
// Before the request is sent this stops the reader; after it, the payment runs to its result.
let answer = VeyraSoftPOS.shared.payments.cancelPayment(merchantOrderID: "ORDER-1042")
```

`session(amountMinorUnits:currencyCode:merchantOrderID:onEvent:)` — `currencyCode` is ISO 4217 numeric (`Int32`, default `566`); `merchantOrderID` is your own order id — **required** and non-blank (a blank one ends the payment `NOT_SENT` / `INVALID_REQUEST` before the reader arms) — stored with the transaction and returned on both sides' history. Create one session per waiting screen; on Cancel and when the screen leaves, call `payments.cancelPayment(merchantOrderID:)` with the session's order ID ([Cancelling a call](#cancelling-a-call)). `TapPaymentResult` carries the outcome in full: the triple `responseStatus` (`"APPROVED"` / `"DECLINED"` / `"FAILED"` / `"PENDING"` / `"RETRY"` / `"NOT_SENT"`) / `responseStatusReason` / `responseCode`, `status` (the same value as `responseStatus`), `reference` (pass to `transactions.receipt(forReference:)`), `pan`, `cardholderName` (EMV tag `5F20` as the card presented it), `errorMessage`, `sdkErrorCode` (**deprecated** — kept for one release; read `responseStatusReason`), plus `creditTransactionID` + `isCreditConfirmationSupported` on an approved sale — the cue to show the "confirming credit" wait and flip it from `transactions.onCreditConfirmation`.

**Branch on `responseStatus`, display `responseCode`.** `APPROVED` / `DECLINED` / `FAILED` / `RETRY` are final; `PENDING` means the SDK is still resolving the payment — never charge again; `NOT_SENT` means the payment never reached the gateway (`NO_NETWORK_CONNECTION`, `SDK_UNABLE_TO_CONNECT`, `NOT_AUTHENTICATED`, `CARD_READ_FAILED`, `MODE_REFUSED`, `INVALID_REQUEST`), and `RETRY` means it reached Veyra but was never sent to the bank (`NAME_ENQUIRY_FAILED`, `ISSUER_SWITCH_NOT_AVAILABLE`, …) — either way nothing was charged, so fix the reason and retry with the **same** `merchantOrderID`. `NOT_SENT` never carries a `responseCode`; `RETRY` carries the code Veyra stated. `responseStatus` is `"Unknown"` for a value newer than this build (and `nil` only if nothing could be stated) — treat either as unresolved, never as a refusal. `responseStatusReason` is a plain string to display and log, never to parse.

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
| `merchantOrderID` | **Mandatory** | Your own order id for the sale, non-blank. A blank one ends `NOT_SENT` / `INVALID_REQUEST`; one whose order is already paid or still being confirmed ends `FAILED` / `DUPLICATE_MERCHANT_ORDER_ID`. Otherwise it can be reused — see [The merchant order ID](#the-merchant-order-id). |

Returns `PaymentContextQR` — an outcome. Branch on `responseStatus`:

| `responseStatus` | Meaning | What to do |
|---|---|---|
| `APPROVED` | The QR was created — `txRef` (poll key), `mpmPayload` (**render this string verbatim as the QR**), `expiry` (ISO-8601) and `kid` are set | Render and poll |
| `FAILED` | The gateway refused it — `responseStatusReason`, e.g. `DUPLICATE_MERCHANT_ORDER_ID`, `MERCHANT_NOT_FOUND` (see [Table D](#table-d--veyra-payment-gateway-non-payment-calls-softpos)) | `DUPLICATE_MERCHANT_ORDER_ID`: the order is already paid or being confirmed — don't take another payment for it. Otherwise fix the reason and create the QR again for the same order |
| `PENDING` | Sent, no usable answer | Create a new QR |
| `NOT_SENT` | Never reached the gateway (`NO_NETWORK_CONNECTION`, `INVALID_REQUEST`, `CANCELLED` after [`cancelPayment`](#cancelling-a-call), …) | Fix the reason; retry with the **same** order ID |

`txRef`, `mpmPayload`, `expiry` and `kid` are optional and set only on `APPROVED`.

#### `contextStatus`

Poll `contextStatus(txRef:)` on a short interval (the sample uses 2.5 s). It is a read and returns `VeyraLookup<PaymentContextState>`: `value` is the context's state, or `nil` with a `failureReason` when the poll could not be made — just ask again; a failed poll changes nothing. States: `PENDING` (QR live) → `IN_FLIGHT` (wallet push settling) → `APPROVED` / `DECLINED` (settled — `responseCode` carries the rail outcome) or `EXPIRED`. Convenience: `isSettled` (`APPROVED || DECLINED`), `isApproved`. On settlement the payment is also recorded in the merchant's local history under the same `txRef`, so receipts work like any other rail.

```swift
let context = try await VeyraSoftPOS.shared.payments.createContext(
    merchantID: merchantID,
    amountMinorUnits: amount,
    currency: "566",
    onExpired: { qrState = .failed("This payment code has expired — start a new payment") },
    merchantOrderID: orderID           // required: YOUR order id for the sale
)
// NOT_SENT / RETRY: nothing was charged — retry this order with the same order id
retryOrderID = [VeyraResponseStatus.notSent, VeyraResponseStatus.retry]
    .contains(context.responseStatus) ? orderID : nil
guard context.responseStatus == VeyraResponseStatus.approved,
      let txRef = context.txRef, let payload = context.mpmPayload else {
    showFailed(context.responseStatusReason ?? context.responseStatus)
    return
}
// render payload verbatim as the QR, then poll:
while !Task.isCancelled {
    try await Task.sleep(nanoseconds: 2_500_000_000)
    // A poll that could not be made carries a failureReason and no value: just ask again.
    guard let status = try? await VeyraSoftPOS.shared.payments.contextStatus(txRef: txRef).value else { continue }
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

Decode and validate a scanned payload. Nothing is sent. Returns a `CustomerQrInspection` outcome: `APPROVED` with `qr` set, or `FAILED` / `INVALID_REQUEST` (`qr` is `nil`) when the payload is not a Veyra payment QR — show a transient hint and stay armed for another scan; it is not a terminal failure.

`CustomerQrInspection`: `qr: ScannedCustomerQr?`, `responseStatus`, `responseStatusReason`, `message`. `ScannedCustomerQr`: `maskedCard` (last 4 for display), `amountMinorUnits` (the QR's own amount — confirm, never re-key), `currencyNumeric`, `cardholderName` (the paying card's display name, e.g. `AFRIGO ****1234` — the same value a tap presents; **display only**, it rides outside the QR's cryptogram, so never branch a payment decision on it; `nil` when the QR carries none).

#### `payments.chargeCustomerQr`

Charge the confirmed QR synchronously over the standard payment rail. A tampered payload or altered amount declines at the server.

```swift
// FAILED / INVALID_REQUEST means "not a payment QR": transient hint, stay armed.
guard let inspection = try? await VeyraSoftPOS.shared.payments.inspectCustomerQr(payload),
      let scanned = inspection.qr else {
    showHint("Not a payment code — try again")     // stay armed for another scan
    return
}
confirm(scanned.amountMinorUnits, card: scanned.maskedCard)   // merchant confirms the QR's amount

let outcome = try await VeyraSoftPOS.shared.payments.chargeCustomerQr(
    scanned,
    merchantOrderID: orderID                       // required: YOUR order id for the sale
)
// NOT_SENT / RETRY: nothing was charged — retry this order with the same order id
retryOrderID = [VeyraResponseStatus.notSent, VeyraResponseStatus.retry]
    .contains(outcome.responseStatus) ? orderID : nil
lastPaymentReference = outcome.reference.isEmpty ? nil : outcome.reference   // SDK-minted — for the receipt
showResult(status: outcome.responseStatus, reason: outcome.responseStatusReason, code: outcome.responseCode)
```

`CustomerQrChargeOutcome`: `responseStatus` (`APPROVED` · `DECLINED` · `FAILED` · `PENDING` · `RETRY` · `NOT_SENT` — branch on this), `responseStatusReason` (`INSUFFICIENT_FUNDS`, `NO_RESPONSE_RECEIVED`, `NO_NETWORK_CONNECTION`…; show and log it), `responseCode` (the wire code — for receipts and support, never to branch on; `nil` on `NOT_SENT`), `approved: Bool` (true only when `responseStatus == "APPROVED"` — never worked out from the code), `transactionID`, `reference`, plus `creditTransactionID` + `isCreditConfirmationSupported` (populated on approved charges — the cue to wait for credit confirmation, see `transactions.creditConfirmation`). A `PENDING` charge may have gone through: never charge again — the SDK resolves it in the background.

> **Who mints the reference.** `reference` is minted by the **SDK** (`{terminalId}-YYYYMMDDHHmmssSSS`) so the gateway can guarantee it is unique per merchant — your app does not supply it, and it is the key for receipts, status lookups and credit confirmation. `merchantOrderID` is the field for **your** identifier: **required** on every merchant payment and echoed back. An order can take several attempts, and the same order ID is used for each of them **until the order is paid or possibly paid**: a new attempt is refused `94` / `FAILED` / `DUPLICATE_MERCHANT_ORDER_ID` (and `createContext` ends `FAILED` / `DUPLICATE_MERCHANT_ORDER_ID` with no QR created) only while the order is `APPROVED` or `PENDING`. The refusal carries the attempt that decided it as `originalPayment` (on `TapPaymentResult`, `CustomerQrChargeOutcome` and `PaymentContextQR`) — its `responseStatus` says whether the order is already paid (`APPROVED`) or still being confirmed (`PENDING`), so tell the merchant which and do not take another payment for it. After `DECLINED`, `FAILED`, `RETRY` or `NOT_SENT`, try again under the **same** order ID. `createContext`, `chargeCustomerQr` and `tap.session` all require it: omitting it does not compile, and a blank (or over-255-character) value ends the call `NOT_SENT` / `INVALID_REQUEST` before anything is sent. See [The merchant order ID](#the-merchant-order-id).

---

### Merchant transactions & receipts

The SDK records every payment it takes — tap, get-paid QR and customer-QR charge — locally at its terminal outcome, so history needs no backend round trip.

#### `transactions.history`

```swift
let transactions = try await VeyraSoftPOS.shared.transactions.history(limit: 50)
// MerchantTransaction: reference, rail ("TAP" / "QR_MPM" / "QR_CPM"),
// railLabel ("Tap" / "QR" / "Scan"), amountMinorUnits,
// currencyNumeric, status ("APPROVED"/"DECLINED"/"PENDING"/"FAILED"/"RETRY"), responseCode,
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

`PENDING` means the outcome is not yet known (the SDK keeps polling and updates the stored row); `FAILED` means the gateway received the payment and could not perform it; `RETRY` means the gateway received it but never sent it to the bank — nothing was charged. Hide receipt affordances while a row is `PENDING`.

**Every attempt is its own row.** An order paid on the second try shows two rows with the same `merchantOrderID` — for example a `RETRY` row followed by an `APPROVED` one, each with its own `reference`. Group rows by `merchantOrderID` if your screen shows orders rather than attempts, and decide what the order is with the rule in [The merchant order ID](#the-merchant-order-id), never by taking the newest row.

**How the SDK waits for a `PENDING` row.** You do not have to poll, schedule anything, or keep a screen open — the SDK asks on its own, with **exponential backoff**: the first re-checks come within seconds (most payments settle at once) and the interval doubles to a steady state of roughly **once an hour**. It keeps that up for **30 days** from the transaction date, and then stops asking.

**Stopping is not an outcome.** When the 30 days elapse the row keeps whatever status it has — still `PENDING`, which is still true — and the SDK simply takes it off the poll list. It never writes `FAILED`, `DECLINED` or any other verdict of its own: only the backend decides what a payment was. So treat a long-`PENDING` row as *unresolved*, not as failed, however old it is.

**Let the merchant ask on demand — `transactions.refreshStatus(reference:)`.** The SDK polls a pending transaction for you with **exponential backoff**, and **stops after 30 days**. Polling never invents an outcome — a row that ages out simply stops being asked about and stays `PENDING`. Expose **`refreshStatus`** in your UI so the merchant can ask on demand, which is the route for anything still pending after the window closes.

A failed poll — device offline, gateway unreachable, an unreadable answer — changes nothing at all: the SDK backs off and asks again, and the row is left exactly as it was. "We could not reach the server" is never recorded as "the payment failed".

#### `transactions.refreshStatus(reference:)`

```swift
// A check that could not be made is not thrown: it says why, and the row is unchanged.
let lookup = try await VeyraSoftPOS.shared.transactions.refreshStatus(reference: reference)
if let reason = lookup.failureReason {
    note = reason == "NO_NETWORK_CONNECTION"
        ? "No internet connection — connect and try again."
        : "Could not check right now (\(reason))."
} else if let updated = lookup.value {          // nil if this device has no such reference
    render(updated)
}
```

Returns `VeyraLookup<MerchantTransaction>` — see [`VeyraLookup`](#veyralookup--the-answer-to-a-read).

The on-demand counterpart to `history(limit:)`, which only reads what the device already knows. It
asks the gateway about that one transaction now and writes the answer into the same local store the
background sweep writes, so an on-demand check and a background check can never disagree.

- **Show it only while the row is `PENDING`.** A settled row has nothing to ask, and offering the
  action implies the outcome might still change. Hide it the moment the row is terminal.
- **It works past the 30-day window**, and on a row the sweep never had on its list — that is what it
  is for.
- **It is not a way to force an outcome.** A payment that is still unsettled answers `PENDING` again.
  Show a brief "still processing" note; do not retry in a loop.
- **A failed lookup changes nothing** — the row stays as it was, and `failureReason` says why (an
  offline phone reports `NO_NETWORK_CONNECTION`). Show it and leave the row pending.
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

Backend status query by reference: `status(merchantID:merchantTransactionReference:transactionDate:)` (date `YYYY-MM-DD`) → `VeyraLookup<[TransactionStatus]>`: `value` is the gateway's rows (`responseCode`, `amount`, `transactionID`, `merchantStatus`, `creditTransactionID`, `isCreditConfirmationSupported`), or `nil` with a `failureReason` when the query could not be made. It writes nothing. Use the local history for everyday listing; this is for reconciliation against the backend.

#### `transactions.creditConfirmation`

Beneficiary credit confirmation: has the merchant's bank actually **received the funds** of an approved sale? Settlement confirmation only — it never changes the sale's payment outcome.

```swift
let lookup = try await VeyraSoftPOS.shared.transactions.creditConfirmation(
    merchantID: merchantID,
    creditTransactionID: tx.creditTransactionID!,   // from the history row / payment response
    amountMinorUnits: tx.amountMinorUnits           // cross-checked by the merchant's bank
)
guard let confirmation = lookup.value else {
    return show(lookup.failureReason)               // the check could not be made — ask again later
}
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
let lookup = try await VeyraSoftPOS.shared.transactions
    .refreshCreditConfirmation(reference: tx.reference)   // VeyraLookup<MerchantTransaction>
if let reason = lookup.failureReason { showNote(reason) } // the row is unchanged
else if let updated = lookup.value { render(updated) }    // nil if unknown here
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
- **A failed lookup changes nothing** — the row stays as it was, and `failureReason` says why (an
  offline phone reports `NO_NETWORK_CONNECTION`). Show it and leave the credit line reading "not
  confirmed yet".
- **No SDK-side throttle.** Disable your button while a call is in flight, as the sample does.

**Holding the result screen (your app's decision, never the SDK's).** A terminal outcome is a destination, not a notification. The sample holds its result view for **60 seconds** — approved, declined, failed, pending and not sent alike — with **Done** visible for the whole hold and dismissing immediately; when the hold expires the view returns Home on its own. The single exception is an approved sale whose `isCreditConfirmationSupported` is (or later becomes) `true`: **cancel** the hold so the view cannot vanish while the merchant's bank is still being asked, show "Confirming credit with merchant bank…", and start a **fresh 60 seconds** once the confirmation is on screen (the merchant-QR rail learns the flag moments after the settle, so the cancel can happen while the hold is already running). Non-terminal tap events (`.unsupportedTarget`, lost contact) are not results — they hold nothing and dismiss nothing: the waiting screen stays up, armed for a re-tap. How long a result stays up and what dismisses it are app concerns end to end — the SDK has no concept of a screen and supplies no duration, and dismissing a view never stops its app-scoped credit polling.

### Retrying a payment safely

`merchantOrderID` is **your** reference for the sale — the order, basket or invoice in your POS —
and it is required on every SoftPOS rail that takes payment: `tap.session`, `payments.createContext`
and `payments.chargeCustomerQr`. The SDK mints a new `reference` for each attempt; the order ID is
what ties the attempts of one sale together, and it is what lets you retry without charging twice.

| Outcome of the attempt | Money moved? | Next payment for the order |
|---|---|---|
| `NOT_SENT` | No — it never reached Veyra | Allowed — fix the reason, use the **same** order ID |
| `RETRY` | No — Veyra did not send it to the bank | Allowed — the **same** order ID |
| `DECLINED` | No — the issuer or bank refused | Allowed — another card or method, the **same** order ID |
| `FAILED` | No | Allowed — fix the reason, the **same** order ID (not after `94`, below) |
| `PENDING` | Maybe | **Refused** — `94` / `FAILED` / `DUPLICATE_MERCHANT_ORDER_ID`, with `originalPayment`. Don't take another payment; wait for the SDK to resolve it |
| `APPROVED` | Yes — the order is paid | **Refused** the same way. Don't take another payment; a new sale gets a new order ID |

Keep the order ID for the life of the sale and drop it only when the order is paid or might be:

```swift
@State private var retryOrderID: String?        // kept from an attempt that moved no money

func takeOrderID() -> String { retryOrderID ?? newOrderIDFromYourPOS() }

func settleOrderID(_ orderID: String, responseStatus: String?) {
    // No money moved: the retry carries the SAME order ID. APPROVED, PENDING or a status this
    // build doesn't know (treat it as pending): the order is paid or may be — never pay it again.
    let reusable = [VeyraResponseStatus.notSent, VeyraResponseStatus.retry,
                    VeyraResponseStatus.declined, VeyraResponseStatus.failed]
    retryOrderID = responseStatus.map(reusable.contains) == true ? orderID : nil
}

func charge(_ scanned: ScannedCustomerQr) async throws {
    let orderID = takeOrderID()
    let outcome = try await VeyraSoftPOS.shared.payments.chargeCustomerQr(scanned, merchantOrderID: orderID)
    settleOrderID(orderID, responseStatus: outcome.responseStatus)
    show(outcome)                                // "Try again" simply calls charge again
}
```

The gateway enforces the rule, so reusing an order ID is always safe: the worst case is a `94`
whose `originalPayment` tells you the order is already paid (`APPROVED`) or still being confirmed
(`PENDING`). The full rule, with the order-status precedence behind it, is in
[The merchant order ID](#the-merchant-order-id). The sample does exactly this in `GetPaidView`
(`takeOrderID` / `settleOrderID`).

### Looking up a payment

"What happened to this order?" — one call, by **your** order ID, for every SoftPOS rail. You don't
say which rail took it.

```swift
// A read: only a setup mistake throws.
let lookup = try await VeyraSoftPOS.shared.transactions.paymentStatus(merchantOrderID: orderID)
// VeyraLookup<OrderPaymentStatus>
if let reason = lookup.failureReason { showNote("Couldn't ask the gateway (\(reason))") }  // value = what this phone holds
guard let order = lookup.value else { return showNothingKnown() }   // no record here, and the gateway was not asked
switch order.responseStatus {
case VeyraResponseStatus.approved: showPaid(order)                   // never take another payment
case VeyraResponseStatus.pending:  showStillConfirming(order)        // never retry; the SDK resolves it
default:                           offerPayment(sameOrderID: orderID) // DECLINED / FAILED / RETRY: no money moved
}
```

**When to use it.** Whenever you hold an order ID but not a settled outcome: a payment that ended
`PENDING`, or your app restarting (or being killed, or losing the screen) before the result arrived.
It covers the card tap, the merchant QR (`payments.createContext`) and the customer-QR charge — the
same order ID, whichever rail was used, so your POS never needs to remember the rail.

**The result — `OrderPaymentStatus`.** `responseStatus` is the **order's** status, decided by
precedence over all its attempts:

| Rank | Rule | `responseStatus` | What to do |
|---|---|---|---|
| 1 | any attempt `APPROVED` | `APPROVED` | Paid. Never take another payment for it |
| 2 | otherwise, any attempt `PENDING` | `PENDING` | It may have moved money. **Never retry**; the SDK keeps checking |
| 3 | otherwise, the **latest** attempt | `DECLINED`, `FAILED` or `RETRY` | No money moved. Pay again with the **same** order ID |
| 4 | no attempts | `RETRY`, `responseCode` `25`, reason `UNABLE_TO_LOCATE_RECORD` | Nothing was charged. Pay with the same order ID |

The other top-level fields — `responseStatusReason`, `responseCode`, `reference`, `transactionID`,
`amountMinorUnits` — are the **deciding attempt**'s (the approved one, else the pending one, else the
latest). `attempts` lists every attempt, newest first (`OrderPaymentAttempt`: `reference`,
`transactionID`, `amountMinorUnits`, `responseCode`, `responseStatus`, `responseStatusReason`).
`answeredBy` says who answered: `"DEVICE"` or `"GATEWAY"`.

**Who answers.** When this phone's own record of the order is final (`APPROVED`, `DECLINED` or
`FAILED`) the SDK answers from it, with no network call. Otherwise — a local `PENDING`, only `RETRY`
attempts, or no record at all (another phone took it, or the app was reinstalled) — it asks the
gateway, because an attempt this phone never recorded can outrank its own.

**A payment still on its way counts.** A tap or customer-QR charge is on the history as `PENDING` before its request leaves, and the gateway's answer is combined with this phone's own attempts — so while a payment is in flight the lookup answers `PENDING` (don't take another payment), even when the gateway has no record of it yet.

**A merchant QR that has not been paid yet** answers `PENDING` on the phone that created it — the QR is
on its history from creation, as an open attempt — until the customer pays it. That is not a failure,
and it means the same thing: don't take another payment for the order while the QR can still be paid.
Asked from a phone with no record of the QR (another phone, or after a reinstall), the gateway has no
attempt to report, so it answers rank 4 — `RETRY` / `25` / `UNABLE_TO_LOCATE_RECORD`.

**It is a read** ([`VeyraLookup`](#veyralookup--the-answer-to-a-read)). It changes nothing, so asking
again is always safe, and it never answers with an outcome of its own. When the gateway could not be
asked, `failureReason` says why (`NO_NETWORK_CONNECTION`, `SDK_UNABLE_TO_CONNECT`,
`NO_RESPONSE_RECEIVED`, `UPSTREAM_ERROR`, …) and `value` is what this phone already holds for the
order, if anything — so a `nil` value with a `failureReason` means "not known here", **not** "not
paid". A blank order ID answers `failureReason = INVALID_REQUEST`; a device with no registered
merchant answers `MISSING_MANDATORY_CONFIG` (with the local value, if any). The wallet has no lookup
by order ID — order IDs belong to the merchant side.

The sample has a **Look up** field on its merchant Transactions view (`MerchantTransactionsView.lookUpOrder`).

---

## Wallet — making payments

Everything hangs off `VeyraWallet.shared` — the examples below hold it as `let wallet = VeyraWallet.shared`; methods are `async throws`, but they throw `VeyraWalletError` only for setup mistakes; everything that happens while processing comes back as an outcome — see [Errors and outcomes](#errors-and-outcomes).

### Add token

| Call | What it does | Returns |
|---|---|---|
| `banks(accountNumber:)` | The banks a card can be added from, optionally filtered by account number | `BankList` |
| `verifyAccount(_:)` | Checks the account can be tokenised (`VerifyAccountParams`) | `VerifyAccountResponse` |
| `digitise(_:)` | Adds the token: tokenises the account and stores the payment material on the phone (`DigitiseParams`) | `DigitiseResult` |
| `cancelDigitise(clientRequestID:)` | Cancels an add-token still on the phone | `CancelResult` |

Flow: `banks` → `verifyAccount` → `digitise`. On success the SDK receives, decrypts and stores the payment material on-device — the card can pay immediately (`APPROVED`) or after activation (`APPROVE_REQUIRE_AUTH`).

---

#### `banks`

Fetch the supported NUBAN banks, optionally filtered by account number. Call as soon as the user finishes entering their account number so the list is ready for the bank picker.

| Parameter | Required | Description |
|-----------|----------|-------------|
| `accountNumber` | No | 10-digit NUBAN. When supplied, returns only banks linked to that account; `nil`/blank returns all supported banks (use as the "can't find my bank" fallback). |

```swift
let list = try await wallet.banks(accountNumber: "1234567890")   // BankList
guard list.responseStatus == VeyraResponseStatus.approved else {
    banksState = .failed(list.responseStatusReason == "NO_NETWORK_CONNECTION"
        ? "No internet connection — connect and try again."
        : "Could not load banks (\(list.responseStatusReason ?? list.responseStatus)).")
    return
}
let banks = list.banks   // [Bank]: slug, name, institutionCode
```

`BankList`: `banks`, `responseStatus`, `responseStatusReason`, `message`. A read — `APPROVED` with the banks, or the reason there are none (`NO_NETWORK_CONNECTION`, `INVALID_ACCOUNT_NUMBER`, …). Never `PENDING`; retrying as is is always safe.

---

#### `verifyAccount`

Check whether an account can be tokenised before digitising. Eligible when `responseCode == "APPROVED"`.

```swift
let response = try await wallet.verifyAccount(VerifyAccountParams(
    accountNumber: "1234567890",
    institutionCode: "000000",
    walletAccountID: "ada@example.com",
    accountHolderName: "Ada Obi",                 // optional
    accountNumberSource: "MANUAL"                 // optional
))
if response.isApproved { proceedToDigitise() }
```

`VerifyAccountParams` carries the same fields as Android's and React Native's: `accountNumber`, `institutionCode` and `walletAccountID` are required; `accountHolderName` and `accountNumberSource` are optional.

`walletAccountID` is the customer's **registered email address or phone number** — a value the issuer already holds for this account, not an internal id of your own. The SDK derives a hash from it; it is not sent raw. The issuer checks that hash against its own records, so a value it does not know never matches.

`VerifyAccountResponse`: `responseCode` (`"APPROVED"` = eligible), `responseStatus` (what the call did — `"APPROVED"`; `"DECLINED"`, the check ran and the answer is no; `"FAILED"`, it could not be run — including when it never reached Veyra: `NO_NETWORK_CONNECTION`, `NOT_AUTHENTICATED`, …), `responseStatusReason` (the symbolic cause — branch on this), `message` (+ convenience `isApproved`). An eligibility check is a read: it is never `PENDING`, and retrying as is is always safe. See [Table C — Veyra token service](#table-c--veyra-token-service-wallet).

---

#### `digitise`

Tokenise the account: the SDK attests the device, sends the request, and on success decrypts and stores the token material on-device. The **tokenisation recommendation is your app's business decision** — the SDK never assumes one.

```swift
let r = try await wallet.digitise(DigitiseParams(
    accountNumber: accountNumber,
    institutionCode: institutionCode,
    accountHolderName: "Ada Obi",
    walletAccountID: "ada@example.com",
    emailAddress: "ada@example.com",
    recommendation: .approve,                    // your app's risk decision — required
    consumerIdentifier: customerID,              // your stable id for this customer
    bvn: bvn,
    accountHolderAddress: address,
    mobileNumber: mobileNumber,
    clientRequestID: requestID,                  // optional: your reference, to cancel with cancelDigitise
    accountNumberSource: "MANUAL",
    deviceScore: .trusted,
    accountScore: .highlyTrusted,
    recommendationReasons: [.goodActivityHistory],
    bankName: selectedBankName                   // shown on the stored card
))
// Every digitise ends with an outcome. Digitise is never PENDING: an answer that never
// arrived is FAILED (NO_RESPONSE_RECEIVED / UPSTREAM_ERROR) — add the card again.
switch r.responseStatus {
case VeyraResponseStatus.approved:
    if r.requiresActivation { showActivationMethods(r.tokenUniqueReference, r.activationMethods) }
    else { showCardAdded() }                     // r.isApproved
case VeyraResponseStatus.declined:
    showDeclined(r.message, r.responseStatusReason)   // the issuer refused; the flow ends
case VeyraResponseStatus.notSent:
    showRetry(r.responseStatusReason)            // nothing was sent: fix it (connect…) and digitise again
default:                                         // FAILED, or a status newer than this build
    showError(r.message ?? r.responseStatusReason ?? "Could not add card")   // digitise again
}
```

`DigitiseParams` carries the same fields, and the same required ones, as Android's and React Native's: `accountNumber`, `institutionCode`, `accountHolderName`, `walletAccountID`, `emailAddress` and `recommendation` are required; everything else is optional.

`DigitiseResult`: `tokenUniqueReference`, `responseCode` (the issuer's decision: `APPROVED`, `APPROVE_REQUIRE_AUTH`, `DECLINED`), `responseStatus` (`APPROVED` · `DECLINED` · `FAILED` · `NOT_SENT` — **never `PENDING`**), `responseStatusReason` (the cause — present on `APPROVE_REQUIRE_AUTH` too, where it says why step-up is needed), `message`, `activationMethods` (`medium` + masked `contact`), `tokenStored` (provisioning material decrypted and stored), `isApproved`, `requiresActivation`. Add-card has no reference of its own: after `FAILED` or `NOT_SENT` simply digitise again. `clientRequestID` (optional) is your reference for one attempt: pass one and `cancelDigitise(clientRequestID:)` can cancel the add-card while it is still on the phone ([Cancelling a call](#cancelling-a-call)); a cancelled attempt ends `NOT_SENT` / `CANCELLED`.

#### `cancelDigitise`

Set `clientRequestID` in `DigitiseParams`, then `cancelDigitise(clientRequestID:)` with the same value cancels the add-token while it is still on the phone. It answers at once with a `CancelResult` and never throws; a cancelled `digitise` ends `NOT_SENT` / `CANCELLED`. See [Cancelling a call](#cancelling-a-call).

---

### Activation

| Call | What it does | Returns |
|---|---|---|
| `requestActivationCode(tokenUniqueReference:medium:reason:)` | Sends an activation code to the masked email or phone | `ActivationCodeResponse` |
| `activate(tokenUniqueReference:activationCode:)` | Submits the code the customer received | `ActivateResponse` |
| `observeActivation(tokenUniqueReference:onActivated:onTimeout:onError:)` | Watches an out-of-band activation (polls every 10 s, up to 5 minutes) | — (callbacks, on the main thread) |
| `pauseActivationObserver` / `resumeActivationObserver` / `stopActivationObserver(tokenUniqueReference:)` | Pauses on background, resumes on return, stops when the screen goes | — |
| `hasActivationObserver(tokenUniqueReference:)` | Whether an activation observer is still running for the token | `Bool` |

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
| `medium` | **Mandatory** | The chosen `ActivationMedium`: `.maskedEmail` / `.maskedMobilePhone`. |
| `reason` | **Mandatory** (default `.addCard`) | `.addCard`, `.checkAccountEligibility` or `.other`. |

```swift
let response = try await wallet.requestActivationCode(
    tokenUniqueReference: ref, medium: .maskedMobilePhone, reason: .addCard)
```

`ActivationCodeResponse`: `responseStatus`, `responseStatusReason`, `tokenUniqueReference`, `expirationDateTime` (ISO-8601 — drive your countdown from it), `status` (`SUCCESS` / `FAILURE`), `message`, `failureCode` (typed `ActivationFailureCode`, nil on success) + `failureCodeRaw`. **Branch on `responseStatus` first:**

| `responseStatus` | Meaning | What to do |
|---|---|---|
| `APPROVED` | The code was sent | Show OTP entry with the countdown |
| `FAILED` | Refused — `responseStatusReason` is the failure code (e.g. `CODE_REQUEST_RATE_LIMITED`), and `failureCode` carries it typed | Branch on `failureCode`, never on `message`: `.codeRequestRateLimited` — disable "resend" until later but keep the flow open; `.activationLocked` — terminal, end the flow and point the user at their issuer |
| `PENDING` | Sent, no usable answer — a code may be on its way | Wait before asking again |

A request that never reached Veyra is `FAILED` with that reason (`NO_NETWORK_CONNECTION`, `NOT_AUTHENTICATED`, …) and no `failureCode`: fix the reason and ask again.

Codes are limited-attempt and rate-limited — see [Activation — `failureCode`](#activation--failurecode).

#### `activate`

Submit the code the customer received. Activated when `responseStatus == "APPROVED"`.

```swift
let response = try await wallet.activate(
    tokenUniqueReference: ref, activationCode: code)
switch response.responseStatus {
case VeyraResponseStatus.approved: navigateToWallet()
case VeyraResponseStatus.notSent:                  // never reached Veyra — retry with the same code
    showRetry(response.responseStatusReason)
case VeyraResponseStatus.pending:                  // may have activated — read the token status first
    checkTokenStatusThenDecide()
default:                                           // FAILED: responseStatusReason is the failure code
    switch response.failureCode {
    case .codeInvalid: showError("Wrong code — \(response.attemptsRemaining ?? 0) attempts left")
    case .maxAttemptsExceeded:
        // The cycle is closed. On .must delete the token and restart the add-card flow;
        // on .may, deletion is advisory.
        endActivationCycle(response.recommendDelete)
    case .activationLocked: showLockedTerminal()   // hide both retry and resend
    case .codeExpired: offerResend()
    default: showError(response.message ?? "Activation failed")
    }
}
```

`ActivateResponse`: `responseStatus` (`APPROVED` activated · `FAILED` refused, with the failure code as `responseStatusReason` · `PENDING` sent with no usable answer — read the token status before trying again · a request that never reached Veyra is `FAILED` too, with the reason (`NO_NETWORK_CONNECTION`, …) and no `failureCode` — fix it and try the same code again), `responseStatusReason`, `tokenUniqueReference`, `status` (`SUCCESS` / `FAILURE`), `message`. Failure fields (all nil unless `FAILED`): `failureCode` — typed `ActivationFailureCode` (`.tokenNotFound`, `.tokenNotActivatable`, `.activationLocked`, `.noPendingActivation`, `.codeExpired`, `.codeInvalid`, `.maxAttemptsExceeded`, `.codeRequestRateLimited`, `.invalidRequest`, `.activationFailed`, or `.unknown(raw:)` for a code newer than this SDK); `attemptsRemaining` — code attempts left where a cap applies (0 when exhausted/locked); `recommendDelete` — `.must` / `.may` after an exhausted cycle (delete the dead token rather than leaving it in the card list), nil otherwise (raw values in `failureCodeRaw` / `recommendDeleteRaw`).

#### `observeActivation` (+ pause / resume / stop)

For the out-of-band methods (call centre / website / issuer app) the activation happens elsewhere — observe the token until it activates. The SDK polls every 10 s for up to 5 minutes; callbacks arrive on the main thread; observing the same token again replaces the previous observer.

| Parameter | Description |
|-----------|-------------|
| `tokenUniqueReference` | The card being activated. |
| `onActivated` | Fires exactly once when the token becomes active — navigate to the wallet. |
| `onTimeout` | After 5 minutes without activation — show a fallback message (the SDK keeps checking in the background thereafter). |
| `onError` | Optional — each failed check (polling continues). |

Wire the lifecycle: `pauseActivationObserver(ref)` when the screen backgrounds, `resumeActivationObserver(ref)` on return (the timeout clock keeps running while paused — if it lapsed, `onTimeout` fires immediately), `stopActivationObserver(ref)` when the screen is dismissed. `hasActivationObserver(tokenUniqueReference:)` says whether one is still running for the card — `true` from `observeActivation` until it activates, times out or is stopped (a paused observer is still running).

```swift
try wallet.observeActivation(
    tokenUniqueReference: ref,
    onActivated: { Task { await reload() } },
    onTimeout:   { hint = "Still pending — we'll keep checking" }
)
// scene background/foreground → pauseActivationObserver / resumeActivationObserver
// screen dismissed → stopActivationObserver
```

---

### Tokens

| Call | What it does | Returns |
|---|---|---|
| `tokens()` | Every token in this wallet — local read | `[StoredCard]` |
| `activeToken()` | The token payments use, or `nil` | `StoredCard?` |
| `setActiveToken(_:)` | Selects the token payments use | `CardSelection` |
| `token(_:)` | One token by its `tokenUniqueReference`, or `nil` when it is not in this wallet | `StoredCard?` |
| `tokenStatus(tokenUniqueReference:)` | The token's status at the token service | `TokenStatusResult` |
| `deactivateToken(_:)` | Removes the token — at the backend first, then from the phone | `TokenStatusUpdateResponse` |
| `paymentApplicationInstanceID()` | This install's SDK-generated instance id | `String` |

#### `tokens` / `activeToken` / `token`

The wallet's cards, from the SDK's local registry — no network call.

```swift
let cards = try await wallet.tokens()                       // [StoredCard]
let active = try await wallet.activeToken()                 // StoredCard? — the one payments use
let card = try await wallet.token(tokenUniqueReference)     // StoredCard? — nil when not in this wallet
```

`StoredCard`: `tokenUniqueReference`, `panLastFour`, `maskedPAN`, `expiry` (`MM/YY`), `cardHolderName` (the card's display name — scheme label + masked last four, e.g. `AFRIGO ****1234`; not a person's name, and the same value the card presents in EMV tag `5F20`), `accountHolderName`, `bankName`, `status`, `requiresActivation`, `isActive`, `requiresOnline`, `deviceNotBound`.

**`requiresOnline`** — `true` when the card cannot pay until the wallet has been **online** to refresh it. Render the card greyed-out and non-tappable and prompt the user to connect; the flag derives fresh on every read and clears on its own once the SDK's automatic refresh succeeds. There is no manual "refresh keys" call — key management is entirely SDK-owned.

**`deviceNotBound`** — `true` (default `false`) when the backend refused this card's payment keys because the card was added on a **different device** — or on this phone before the app was reinstalled. Payment keys are issued for a card only to the device it was added on; on this refusal the SDK remembers it for that card, stops all automatic key requests for it (top-up, refresh, maintenance), and `requiresOnline` is always `false` while it is set. Going online does not help, and neither does a smaller amount. Render the card unavailable and tell the user to **add this card again on this phone** — not to connect. The flag clears only when the card is removed.

#### Handling token states in your UI

A card is not simply "there or not" — it can be awaiting activation, frozen for a refresh, or suspended server-side. Derive one display state per card, in this precedence order, every time you render the wallet:

| Precedence | State | How you observe it | UI treatment | What unblocks it |
|---|---|---|---|---|
| 1 | **Needs activation** | `card.requiresActivation` | Show the card with an **"Activate"** badge/button that launches the [activation flow](#activation). Pay actions hidden. | `activate` succeeding, or `observeActivation` firing `onActivated`. |
| 2 | **Not bound to this device** | `card.deviceNotBound == true` — and a pay attempt ends `NOT_SENT` / `DEVICE_NOT_BOUND` | **Grey the card out and make it non-tappable**; overlay an **"Add this card again on this phone"** hint; disable every pay affordance. Don't prompt to connect — going online cannot fix it. | Only the user removing the card (`deactivateToken`) and adding it again on this phone. **Sticky** until then. |
| 3 | **Requires online** | `card.requiresOnline == true` | **Grey the card out and make it non-tappable**; overlay a "Connect to the internet" hint; disable every pay affordance (scan-to-pay, show-QR buttons). | Nothing you call — the SDK refreshes the card itself the next time the device is online. Re-read the list and the flag has cleared. |
| 4 | **Inactive server-side** (suspended, expired) | `card.status` (e.g. `"SUSPENDED"`) — and a pay attempt ends `NOT_SENT` / `TOKEN_NOT_ACTIVE` | Grey the card out with an **"Unavailable — contact your bank"** indicator; disable pay affordances. Don't offer retry — the state is issuer-controlled. | A later automatic status sync seeing the card active again. |
| 5 | **Payable** | None of the above | Normal rendering; pay affordances enabled for the active card. | — |

Two rules make this robust:

- **Derive, don't cache.** Every state above is computed fresh on each read and clears itself (except **Not bound to this device**, which clears only when the card is removed) — re-read the card list whenever your wallet screen (re)appears and after any payment attempt, rather than storing state.
- **Gate the affordances, not just the card face.** Disabling only the card image but leaving a "Scan to pay" button live produces the refusals at pay time; disable the actions too, and treat the `NOT_SENT` refusals (`ONLINE_REQUIRED` / `DEVICE_NOT_BOUND` / `TOKEN_NOT_ACTIVE`) as the backstop, not the primary UX.

The sample's card stack + gating:

```swift
let cards = try await wallet.tokens()

// Per-card rendering:
@ViewBuilder func cardFace(_ card: StoredCard) -> some View {
    if card.requiresActivation {                          // 1. needs activation
        CardView(card).overlay(alignment: .bottom) {
            Button("Activate") { activate(card) }
        }
    } else if card.deviceNotBound {                       // 2. added on another device
        CardView(card)
            .opacity(0.4)
            .allowsHitTesting(false)
            .overlay(Text("Add this card again on this phone to use it"))
    } else if card.requiresOnline {                       // 3. frozen until online
        CardView(card)
            .opacity(0.4)                                 // greyed out
            .allowsHitTesting(false)                      // non-tappable
            .overlay(Text("Connect to the internet to use this card"))
    } else if card.status.uppercased() == "SUSPENDED" {   // 4. suspended server-side
        CardView(card)
            .opacity(0.4)
            .allowsHitTesting(false)
            .overlay(Text("Card unavailable — contact your bank"))
    } else {
        CardView(card)                                    // 5. payable
    }
}

// Screen-level gating:
func activeCardBlocked(_ cards: [StoredCard]) -> Bool {
    guard let active = cards.first(where: { $0.isActive }) else { return true }
    return active.deviceNotBound || active.requiresOnline || active.status.uppercased() == "SUSPENDED"
}
// Re-derive on every appearance and scene-activation (statuses sync in the background):
.onAppear { Task { await reload() } }
.onChange(of: scenePhase) { if $0 == .active { Task { await reload() } } }
```

A deactivated card needs no rendering rule — the SDK removes it from the list entirely (the wipe happens automatically when a status sync sees `DEACTIVATED`).

#### `setActiveToken`

Select the card payments use (at most one card is active). The selection happens on the phone —
nothing is sent — and it answers a `CardSelection`: `APPROVED` (the card is now the one payments
use), or `FAILED` / `CARD_NOT_FOUND` when no card with that reference is in this wallet. Only a
[setup error](#setup-errors--thrown) throws.

```swift
let selection = try await wallet.setActiveToken(tokenUniqueReference)
if !selection.selected {                          // FAILED / CARD_NOT_FOUND
    actionError = selection.message ?? selection.responseStatusReason
}
```

`CardSelection`: `responseStatus`, `responseStatusReason`, `message`, plus `selected: Bool` (the same
fact as `responseStatus == "APPROVED"`). The result is `@discardableResult`.


#### `deactivateToken`

| Method | Behaviour |
|---|---|
| `deactivateToken(ref)` | Deactivates on the backend, then wipes every on-device artefact for the card and promotes the next card to active. Returns `TokenStatusUpdateResponse` — `responseStatus` (`APPROVED` · `FAILED` · `PENDING`; a removal that never reached Veyra is `FAILED` with the reason, e.g. `NO_NETWORK_CONNECTION`), `responseStatusReason`, `status` (the token's state after the call, e.g. `"DEACTIVATED"`, when the server answered), `tokenUniqueReference`, `message`. **Only `APPROVED` removes the card locally**; on any other outcome nothing local changes. Named to match Android and React Native, which call the same operation the same way. |

There is no call to wipe every card: when a customer logs out, call `signOut()` — their cards stay
on the device for when they sign in again (see [Customers](#customers-signing-in-signing-out-switching)).

Use `deactivateToken` for the user's "remove card" action. Check the outcome: if it is not
`APPROVED`, **show the reason and let the customer try again** — don't wipe the card locally anyway.

```swift
let r = try await wallet.deactivateToken(tokenUniqueReference)
if r.responseStatus == VeyraResponseStatus.approved {
    await reload()                                   // card gone, next one promoted
} else {
    // FAILED (e.g. NO_NETWORK_CONNECTION) / PENDING — the card is still on the device
    actionError = r.message ?? r.responseStatusReason ?? r.responseStatus
}
```
 A device-only wipe
leaves the token live at the backend with nothing on the device to show for it, and the customer
sees a card they can no longer manage.

#### `tokenStatus` · token status sync

`tokenStatus(tokenUniqueReference:)` returns a `TokenStatusResult` — a read, never `PENDING`: `APPROVED` with `tokenStatus` (`"ACTIVE"`, `"SUSPENDED"`…), or the reason the check could not be made (`responseStatusReason`, e.g. `NO_NETWORK_CONNECTION`, `TOKEN_NOT_FOUND`), plus `message`. You rarely need it: the SDK syncs each card's server status automatically (on scene-active and around payments) — a suspended card becomes non-payable until a later sync sees it active again, and a deactivated card is removed from the wallet. Reflect it in UI from `StoredCard.status` / payment refusals rather than polling yourself.

#### `paymentApplicationInstanceID`

This install's SDK-generated `payment_application_instance_id` (`VYRA` + 32 hex chars): minted on first use, persisted install-scoped (never backed up), new on reinstall. Read-only — the app cannot set or regenerate it. Throws only a setup error.

---

### Tap to pay

| Call | What it does | Returns |
|---|---|---|
| `openPaySession()` | Arms tap-to-pay — on iOS always answers `FAILED` / `NFC_UNAVAILABLE` | `PaySessionResult` |
| `closePaySession()` | Disarms tap-to-pay — does nothing on iOS | — |
| `isPaySessionOpen()` | Whether tap-to-pay is armed — always `false` on iOS | `Bool` |

**Wallet tap-to-pay is not available on iOS.** Apple restricts card emulation, so an iPhone wallet pays by QR only (see [QR pay](#qr-pay)). The three calls exist so one integration runs on every platform: on Android the same calls arm and disarm the phone for a tap.

Shared code needs no platform check: handle `openPaySession()`'s `FAILED` / `NFC_UNAVAILABLE` as on
an Android phone without NFC — show the QR rails.

---

### QR pay

| Call | What it does | Returns |
|---|---|---|
| `showQrToPay(amountMinorUnits:onExpired:)` | Renders a payment QR for the active token; `onExpired` fires once when it lapses | `PaymentQr` |
| `cancelQrExpiry()` | Stops the shown QR's expiry watch | — |
| `inspectScannedQr(_:)` | Verifies a scanned merchant QR on the phone | `ScanInspection` |
| `payScannedContext(_:)` | Pays a verified merchant QR with the active token | `PaymentOutcome` |
| `cancelPayment(merchantOrderID:)` | Cancels a scan-to-pay still on the phone | `CancelResult` |

#### Show QR to pay (customer-presented)

The customer keys nothing at the till: your app asks the amount first (the merchant states it) and renders a **dynamic payment QR** — the SDK handles the authentication with the amount cryptographically bound inside. Fully offline — the merchant's SoftPOS submits the payment; the outcome lands in history via reconciliation.

##### `showQrToPay` + `cancelQrExpiry`

| Parameter | Required | Description |
|-----------|----------|-------------|
| `amountMinorUnits` | **Mandatory** | The merchant-stated amount — bound into the QR's cryptogram; the merchant's scan charges exactly this or fails. |
| `onExpired` | Optional | Fired **once, on the main thread**, when the QR lapses — blank or replace the code (a dimmed QR is still scannable). A new render supersedes the watch; `cancelQrExpiry()` stops it (call on screen teardown). |

The SDK presents the authentication sheet itself — **one gesture per QR**; regenerating after expiry is a fresh payment attempt and asks again.

```swift
let qr = try await wallet.showQrToPay(amountMinorUnits: amount) {
    expired = true       // blank the code
}
// APPROVED (a QR was made) or NOT_SENT with the reason none could be made. Nothing is sent either way.
guard qr.responseStatus == VeyraResponseStatus.approved, let payload = qr.payload else {
    switch qr.responseStatusReason {
    case "AUTH_CANCELLED": break                 // dismissed the sheet — back to amount entry, no banner
    case "DEVICE_NOT_BOUND": errorMessage = "Remove this card and add it again on this phone"
    default: errorMessage = qr.message ?? qr.responseStatusReason   // ONLINE_REQUIRED, AMOUNT_EXCEEDS_CARD_LIMIT, …
    }
    return
}
renderQr(payload)
// .onDisappear: wallet.cancelQrExpiry()
```

The result (`PaymentQr`): `responseStatus` — `APPROVED` or `NOT_SENT` (showing a QR sends nothing, so there is no other status), `responseStatusReason` on `NOT_SENT` (`AUTH_CANCELLED`, `AUTH_FAILED`, `AUTH_UNAVAILABLE`, `ONLINE_REQUIRED`, `AMOUNT_EXCEEDS_CARD_LIMIT`, `TOKEN_NOT_ACTIVE`, `DEVICE_NOT_BOUND`, `NO_ACTIVE_CARD`, `CARD_CANNOT_SHOW_QR`, `INVALID_REQUEST`), `message`, `payload` (**render as the QR**; `nil` unless `APPROVED`), `tokenUniqueReference`, `amountMinorUnits`, `currencyNumeric`, `expiresAtEpochMillis`, `transactionHash` — this render's unique hash. The payment's own outcome arrives later, on the history row. To show "paid ✓" on the customer's screen, check **this QR's own payment** while the QR is up: call [`refreshTransactionStatus`](#refreshtransactionstatus) with its `transactionHash` — one request per check — and stop on a final status:

```swift
guard let hash = qr.transactionHash else { return }
while !Task.isCancelled {
    try? await Task.sleep(nanoseconds: 3_000_000_000)
    // failureReason set when the check could not be made (offline, throttled…): just ask again next time
    let row = try? await wallet
        .refreshTransactionStatus(transactionHash: hash).value
    switch row?.authorizationStatus {
    case "APPROVED": onSettled(approved: true); return
    case "DECLINED", "FAILED": onSettled(approved: false); return
    default: continue   // PENDING (the QR's own row exists from the moment it is shown), RETRY, or not found yet: keep the QR up
    }
}
```

The QR's history row is created `PENDING` as soon as the QR is shown, so finding the row is not
the answer — only a final status is. **Don't loop `reconcilePendingTransactions` here:** it asks
about every open payment on the device back-to-back, so on a short loop it gets the wallet
throttled (`429`) by the gateway.

#### Scan to pay (merchant QR)

The customer scans a merchant's get-paid QR: **inspect** (on-device verification) → confirm screen → **authenticate** (biometric) → **pay**.

##### `inspectScannedQr`

Synchronous, on-device verification of the scanned payload — gateway signature against the SDK's pinned keys, plus expiry. **Only a verified result may reach your confirm screen; every rejection must end the flow.**

```swift
switch try wallet.inspectScannedQr(payload) {
case .verified(let payment): showConfirm(payment)            // VerifiedPayment
case .rejected(let reason, _): showRejected(reason)          // .malformed/.missingSignature/.unknownKey/.badSignature/.expired
}
```

The verified context carries `merchantName`, `merchantCity`, `amount` (display string), `amountMinorUnits`, `currencyNumeric`, `txRef`, `expiryEpochSeconds` — render these on the confirm screen; the customer never keys an amount — and `merchantOrderID`, the merchant's order ID signed into the QR, which `cancelPayment(merchantOrderID:)` names to cancel the payment while it is still on the phone (`nil` on a QR that carries none: disable Cancel while it is paying).

##### Device authentication (CDCVM) — the SDK asks, you don't

**There is no authentication method to call.** `payScannedContext` and `showQrToPay` present the
system `LocalAuthentication` sheet themselves — Face ID or Touch ID, falling back to the device
passcode — before building the payment. You cannot build a QR payment flow that skips it, and you
cannot forget to sequence it.

The SDK composes the sheet's text from the payment it is about to make, so the gesture is visibly
bound to what it authorises: *"Pay ₦5,000.00 to Ada's Store"*. It asks **once per payment
attempt** — a retry, or regenerating an expired QR, asks again.

Three outcomes can come back from the sheet, all `NOT_SENT` (nothing was sent), and they need
different UI:

| `responseStatusReason` | What happened | What to do |
|---|---|---|
| `AUTH_CANCELLED` | The customer dismissed the sheet | Stay put and let them try again — nothing was sent |
| `AUTH_FAILED` | They tried and it did not succeed | Offer a retry |
| `AUTH_UNAVAILABLE` | This device has **no** enrolled biometry *and* **no** passcode | Send them to Settings; a retry can never succeed |

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

##### `payScannedContext`

Pay the verified context with the wallet's **active card**. The SDK presents the authentication
sheet itself first (above). Whatever the gateway states — approved, declined, failed or still pending — also lands in the card's history.

**Branch on `responseStatus`, not on `approved` or the response code.** The push is a synchronous call, but its *outcome* can still be unknown: the gateway answers `PENDING` when a hop below it timed out (`68`), errored (`06`/`96`) or is still settling (`09`), and the SDK itself ends it `PENDING` when the request left but no answer came back. That is not a refusal — the SDK records the payment as unresolved and keeps polling it until the gateway states a final outcome, which then shows on the history row. Never pay again. `approved` is a convenience for the happy path only (`responseStatus == "APPROVED"`); it is `false` for a pending payment as well as a declined one.

**`NOT_SENT` means nothing was sent** — pay the same QR again once the reason is fixed: `AUTH_CANCELLED` (the customer dismissed the sheet), `AUTH_FAILED`, `AUTH_UNAVAILABLE` (no passcode or biometry), `ONLINE_REQUIRED`, `AMOUNT_EXCEEDS_CARD_LIMIT`, `TOKEN_NOT_ACTIVE`, `DEVICE_NOT_BOUND`, `NO_ACTIVE_CARD`, `CARD_CANNOT_PAY`, `NO_NETWORK_CONNECTION`, `SDK_UNABLE_TO_CONNECT`, `NOT_AUTHENTICATED`, `SDK_INTERNAL_ERROR`, `CANCELLED` (your [`cancelPayment`](#cancelling-a-call) stopped it — go back).

**`RETRY` also means nothing was charged** — the gateway received the payment but never sent it to the bank. Show the reason: for `QR_EXPIRED` or `AMOUNT_MISMATCH` ask the merchant for a fresh code; otherwise (`NAME_ENQUIRY_FAILED`, `ISSUER_SWITCH_NOT_AVAILABLE`, …) the customer can try again.

```swift
let outcome = try await wallet.payScannedContext(payment)
switch outcome.responseStatus {
case VeyraResponseStatus.approved: showApproved(outcome.message)
case VeyraResponseStatus.declined, VeyraResponseStatus.failed:
    showDeclined(outcome.message, outcome.responseStatusReason)
case VeyraResponseStatus.notSent:
    // Nothing was sent — stay on the confirm screen: AUTH_CANCELLED → no error; ONLINE_REQUIRED
    // → prompt to connect; DEVICE_NOT_BOUND → "add this card again on this phone", never "go online".
    handleNotSent(outcome.responseStatusReason, outcome.message)
// PENDING, absent or anything else: not yet known. Say so, and point at history —
// never show a refusal for a payment that may still settle.
default: showPending(outcome.responseStatusReason ?? outcome.responseCode)
}
```

##### `cancelPayment`

`cancelPayment(merchantOrderID:)` with the verified payment's `merchantOrderID` cancels a scan-to-pay while it is still on the phone, and answers at once with a `CancelResult`. A QR that carries no order ID cannot be cancelled. A shown QR has nothing to cancel on the wallet side — the merchant's charge is the payment. See [Cancelling a call](#cancelling-a-call).

---

### History, receipts and reconciliation

| Call | What it does | Returns |
|---|---|---|
| `transactions(tokenUniqueReference:limit:)` | A token's payments, most recent first — local read | `[TransactionSummary]` |
| `reconcilePendingTransactions()` | Asks the backend about every open payment now | `ReconcileResult` |
| `refreshTransactionStatus(transactionHash:)` | Asks the backend about one payment now | `VeyraLookup<TransactionSummary>` |
| `refreshCreditConfirmation(transactionHash:)` | Asks now whether the merchant's bank was credited | `VeyraLookup<TransactionSummary>` |
| `processReceipt(_:expectedTransactionHash:)` | Verifies and stores a scanned merchant receipt | `ReceiptScan` |
| `receipts(limit:)` | Stored receipts, most recent first | `[TransactionReceipt]` |
| `receiptForTransaction(_:)` | The receipt linked to a payment, or `nil` | `TransactionReceipt?` |

#### `transactions`

The card's full local history across every rail iOS has (scanned QR, shown QR), most recent first. No network call. Empty when no card on this device has that reference, or the card has no payments yet. Android's and React Native's `getTransactions`, with the same default (`limit: 50`).

```swift
let history = try await wallet.transactions(tokenUniqueReference: ref)          // last 50
let lastFive = try await wallet.transactions(tokenUniqueReference: ref, limit: 5)
```

`TransactionSummary` fields: `merchantName`, `amountInMinorUnit`, `transactionCurrencyCode` (4-digit ISO 4217, e.g. `"0566"`), `authorizationStatus` (`PENDING` / `APPROVED` / `DECLINED` / `FAILED` / `RETRY`; `nil` on legacy rows — treat as indeterminate), `responseCode` (the outcome's code, e.g. `"00"`, `"51"` — verbatim from the rail that resolved the row; `nil` until resolved; quote this literal in support conversations), `responseStatusReason` (the outcome's stated cause, e.g. `"INSUFFICIENT_FUNDS"` — a plain string to display, never parse; `nil` until resolved), `entryMethod` (`"TAP"`, `"QR_GENERATED"` — showed a QR, `"QR_SCANNED"` — scanned a merchant QR; `nil` legacy — show nothing rather than guess), `merchantLocation`, `transactionHash` (join key to a receipt), `atEpochMillis`, `merchantTransactionReference`, `merchantId`, `merchantOrderID` (the merchant's own order/basket id for the sale — the id the merchant's systems know it by, so a customer can quote it at the counter; a scanned-QR row carries it from payment time, generated-QR rows learn it from the status poll, so `nil` on a still-open row means "not learned yet", not "no order id"; for display and reconciliation — receipts and status refreshes key off `transactionHash` / `merchantTransactionReference`), plus the five beneficiary-credit fields below.

#### `reconcilePendingTransactions`

Reconcile still-`PENDING` rows against the backend **right now**. The SDK's own app-scoped sweep (above) already resolves them without you, so this is the explicit "check again" rather than the mechanism: call it on an occasion — pull-to-refresh, returning to the foreground, opening history — **never on a loop**. It asks about **every** open row on the device, so a screen waiting for one payment (a [shown QR](#show-qr-to-pay-customer-presented), say) calls [`refreshTransactionStatus`](#refreshtransactionstatus) with that payment's hash instead: one request rather than one per open row. If the gateway throttles (`429`), the pass stops there and the remaining rows wait for the SDK's next sweep.

Unlike the scheduled sweep it ignores both the backoff and the 30-day window — an explicit ask always reaches the backend, and it is the supported way to check a row the sweep has stopped polling. A row whose own check fails is left exactly as it was.

It is a read, so it states no status of its own: it answers a `ReconcileResult` whose `failureReason` is set only when the reconcile itself could not run (`NO_NETWORK_CONNECTION`, `NOT_AUTHENTICATED`, …) — `checked` is `true` when it ran. Read the updated rows from `transactions(tokenUniqueReference:limit:)` either way. Only a [setup error](#setup-errors--thrown) throws.

```swift
let reconcile = try await wallet.reconcilePendingTransactions()
if let reason = reconcile.failureReason {         // the reconcile could not run
    note = reason == "NO_NETWORK_CONNECTION" ? "No internet connection." : "Could not check right now (\(reason))."
}
let rows = try await wallet.transactions(tokenUniqueReference: card)   // read the updated rows
```

#### `refreshTransactionStatus`

```swift
// A check that could not be made is not thrown: it says why, and the row is unchanged.
let lookup = try await wallet
    .refreshTransactionStatus(transactionHash: hash)    // VeyraLookup<TransactionSummary>
if let reason = lookup.failureReason {
    note = reason == "NO_NETWORK_CONNECTION"
        ? "No internet connection — connect and try again."
        : "Could not check right now (\(reason))."
} else if let updated = lookup.value {                  // nil if no row carries that hash
    live = updated
}
```

The **per-transaction** counterpart to `reconcilePendingTransactions`, which asks about every open
row and answers only whether it ran (`ReconcileResult`) — this one answers about the row the customer is actually looking at, keyed
by its `transactionHash`.

The SDK polls a pending transaction for you with **exponential backoff**, and **stops after 30
days**. Polling never invents an outcome — a row that ages out simply stops being asked about and
stays `PENDING`. Expose this in your UI so the customer can ask on demand, which is the only route
to an answer once the window has closed.

Show it **only while the row is `PENDING`**: a settled row has nothing to ask about. An offline
phone reports `failureReason` `NO_NETWORK_CONNECTION` rather than a `nil` value — a `nil` `value`
with no `failureReason` means "no row on this device carries that hash", which is a different answer
and must not be shown as a network problem.

#### Merchant credit confirmation (wallet side)

Did the money actually reach the merchant's bank? The wallet asks the same question the merchant's own SDK asks about that sale, from the payer's side — **settlement confirmation only**, it never changes or restates the payment outcome.

**The SDK does the polling; your view renders the stored row.** Once a payment is approved, a sweep started at `configure(customerID:config:provider:)` for the signed-in customer asks the gateway on an exponential backoff for up to **30 days**, across every screen — no view starts or stops it. There is deliberately **no wallet callback** for this: the stored row is the whole surface. Read it when a transaction detail view appears, and re-read (`transactions(...)`) every few seconds while it is up if you want the line to flip live, as the sample's `TransactionDetailView` does.

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
let lookup = try await wallet
    .refreshCreditConfirmation(transactionHash: hash)   // VeyraLookup<TransactionSummary>
if let reason = lookup.failureReason { showNote(reason) } // the row is unchanged
else if let updated = lookup.value { live = updated }     // nil if unknown here
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
- **A failed lookup changes nothing** — the row stays as it was, and `failureReason` says why (an
  offline phone reports `NO_NETWORK_CONNECTION`). Show it and leave the credit line reading "not
  confirmed yet".

#### `processReceipt` / `receipts` / `receiptForTransaction`

Scan a merchant's **receipt QR** to store the customer's copy. The SDK decodes, validates that the receipt matches a payment this wallet actually made, de-duplicates and stores it.

| Parameter | Required | Description |
|-----------|----------|-------------|
| `qrPayload` | **Mandatory** | The scanned contents — raw JSON or base64. |
| `expectedTransactionHash` | Optional | Set it when the scan is launched **from a specific transaction's screen** — a receipt for a different transaction is refused (`RECEIPT_FOR_ANOTHER_TRANSACTION`) instead of silently attaching elsewhere. `nil` = unscoped. |

The receipt is checked and stored **on the phone** — nothing is sent. `processReceipt` answers a `ReceiptScan`; only a [setup error](#setup-errors--thrown) throws:

| `responseStatus` | `responseStatusReason` | Meaning | What to do |
|---|---|---|---|
| `APPROVED` | — | The receipt belongs to a payment this wallet made, agrees with it, and is stored in `receipt` | Show it |
| `FAILED` | `INVALID_RECEIPT` | Not a Veyra receipt QR, or one with a missing or unreadable field | "Not a receipt" — let them scan again |
| `FAILED` | `RECEIPT_NOT_FROM_THIS_WALLET` | No payment made by this wallet matches it | Tell the customer it isn't theirs |
| `FAILED` | `RECEIPT_MISMATCH` | It matches a payment, but its amount, currency, date, merchant or reference disagree with this wallet's record | Show the reason; don't store it |
| `FAILED` | `PAYMENT_NOT_CONFIRMED` | The matching payment's outcome is not confirmed yet | Ask them to scan again shortly |
| `FAILED` | `RECEIPT_FOR_ANOTHER_TRANSACTION` | A scoped scan (`expectedTransactionHash` set) read a receipt for another transaction | Open the right transaction, or scan unscoped |
| `FAILED` | `SDK_INTERNAL_ERROR` | The SDK failed inside itself | Report to support |

`ReceiptScan`: `receipt: TransactionReceipt?` (set only on `APPROVED`), `responseStatus`, `responseStatusReason`, `message`, plus `stored: Bool` (`APPROVED` with a receipt). The result is `@discardableResult`.

```swift
let base64 = Data(payload.utf8).base64EncodedString()
let scan = try await wallet.processReceipt(
    base64, expectedTransactionHash: tx.transactionHash)
if let receipt = scan.receipt {
    show(receipt)
} else {
    scanError = scan.message ?? scan.responseStatusReason   // FAILED / RECEIPT_MISMATCH, …
}

let receipts = try await wallet.receipts(limit: 100)
let linked   = try await wallet.receiptForTransaction(hash)
```

#### Wallet maintenance — automatic

The SDK maintains its own cards — no app wiring required. At `configure`, whenever the app becomes active, and every 15 minutes while the app runs, it syncs each stored card's server status (a suspended card becomes non-payable until polled active again; a deactivated one is removed), self-heals cards the server marks as needing refresh, and tops up the active card's payment keys if they are running low (the key check also runs automatically before every payment). iOS suspends timers while the app is suspended, so nothing runs in the background — the next foreground or launch catches everything up.

There is nothing to call for any of it. What your app may still do on foreground is settle open payments — that is a history call, not maintenance:

```swift
Task { _ = try? await wallet.reconcilePendingTransactions() }
```

There is deliberately no manual refresh call and no key count to read — the SDK owns the payment keys. What your app shows is whether a card can pay: `StoredCard.requiresOnline` and `deviceNotBound` from `tokens()`, kept current by [`observeCardKeyStateChanged`](#observecardkeystatechanged--a-token-ran-out-of-payment-keys-or-got-them-back).

---

### Observers

| Call | What it does | Returns |
|---|---|---|
| `observeTokenStatusChanged(onTokenStatusChanged:)` / `stopObservingTokenStatusChanged()` | The issuer changed a token's status | `TokenStatusChange` to the callback |
| `observeTransactionResolved(onTransactionResolved:)` / `stopObservingTransactionResolved()` | A `PENDING` payment reached its outcome | `WalletTransactionResolution` to the callback |
| `observeCardKeyStateChanged(onKeyStateChanged:onDeviceNotBound:)` / `stopObservingCardKeyStateChanged()` | A token ran out of payment keys, got them back, or can never be re-keyed on this phone | `tokenUniqueReference`, `requiresOnline` to the callback |
| `observePaymentRefusals(forTokenUniqueReference:onRequireOnline:onAmountExceedCardLimit:onDeviceNotBound:)` / `stopObservingPaymentRefusals(forTokenUniqueReference:)` | A payment with this token was refused before anything was sent | the refusal to the matching callback |

Callbacks arrive on the main thread. Each registration is dropped on sign-out and on a customer switch — register again after every `configure` (see [Customers](#customers-signing-in-signing-out-switching)).

#### `observeTokenStatusChanged` — the SDK tells you when a token's status changes

The sweep can apply `SUSPENDED` while the customer is *looking at* a card screen. Subscribe and you
are told the moment it is applied:

```swift
try wallet.observeTokenStatusChanged { change in
    // change.tokenUniqueReference — which card (it fires for any stored card)
    // change.status               — ACTIVE / SUSPENDED / EXPIRED / DEACTIVATED /
    //                               PENDING_ACTIVATION / UNKNOWN
    // change.rawStatus            — the literal as stored; log this one
    // change.canPay               — whether the card can pay right now
    // change.previousStatus       — what it held before, or nil if this is its first status
}
```

- **Branch on `canPay`, not on `status`.** It is the same predicate the SDK's own payment gates use,
  so a status added after your build shipped is correctly reported as *not* payable.
- **Register once, at start-up** — not per card screen.
- **It does not replay.** Read `tokens()` when a screen appears; keep the read path.
- **Only genuine changes fire.** A sweep re-applying the status a card already had wakes nothing.
- **Last registration wins**; `stopObservingTokenStatusChanged()` clears it. Delivered on the main thread.

#### `observeTransactionResolved` — a `PENDING` payment reached its outcome

A wallet payment that gets no immediate answer is stored and polled by the SDK until the backend
settles it — seconds, or days. Unresolved rows are visible in history, so the customer can be
looking at the row at the moment it settles. This is how your app hears it without polling:

```swift
try wallet.observeTransactionResolved { resolution in
    // resolution.transactionHash      — which payment (match your row on this)
    // resolution.tokenUniqueReference — the card that paid
    // resolution.status               — APPROVED / DECLINED / FAILED / RETRY (never PENDING)
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

#### `observeCardKeyStateChanged` — a token ran out of payment keys, or got them back

`StoredCard.requiresOnline` tells you a card cannot pay until the SDK refreshes its keys. This is the
push version of that same value, read from the same function, so a callback can never contradict the
list you are about to draw.

```swift
try wallet.observeCardKeyStateChanged(
    onKeyStateChanged: { tokenUniqueReference, requiresOnline in
        // grey the card, or un-grey it
    },
    onDeviceNotBound: { tokenUniqueReference in   // optional — defaults to nil
        // "add this card again on this phone" — going online will not help
    }
)
```

When a card becomes not-bound to this device and you supply `onDeviceNotBound`, it fires **instead
of** `onKeyStateChanged` for that change. Without it, `onKeyStateChanged` reports
`requiresOnline == false` for that card — so read `deviceNotBound` from the card list rather than
un-greying it.

**Read this limit before you word your UI.** It fires from the two moments the SDK is actually
running: a payment using a key, and a refresh delivering new ones. Payment keys *also* expire by
clock, with no SDK code running — **nothing fires for that**, and such a card simply reads as
`requiresOnline` on your next `tokens()`. The first evaluation of a card after launch is a silent
baseline for the same reason. Keep reading the card list when a screen appears.

There is deliberately no API to trigger a key refresh — the SDK owns when keys are replenished.
`stopObservingCardKeyStateChanged()` clears the observer.

#### `observePaymentRefusals` — card refusals, per card

The wallet's card refusals (`ONLINE_REQUIRED`, `AMOUNT_EXCEEDS_CARD_LIMIT`, `DEVICE_NOT_BOUND`) are
also available as an observer, registered **per card**:

```swift
try wallet.observePaymentRefusals(
    forTokenUniqueReference: card.tokenUniqueReference,
    onRequireOnline: { _, amountMinorUnits, rail in
        promptToConnect(amountMinorUnits)
    },
    onAmountExceedCardLimit: { _, amountMinorUnits, cardLimitMinorUnits, rail in
        offerSmallerAmount(cardLimitMinorUnits)   // never "go online" — the cap does not move
    },
    onDeviceNotBound: { _, amountMinorUnits, rail in   // optional — defaults to nil
        promptToReAddCard()                       // "add this card again on this phone"
    }
)

// when the view goes:
try wallet.stopObservingPaymentRefusals(
    forTokenUniqueReference: card.tokenUniqueReference
)
```

A handler registered for one card **never hears about another's**. Registering the same card again
replaces its handlers; other cards are unaffected. The pay call still returns its `NOT_SENT`
outcome, so this observer is additional — for apps that would rather handle refusals in one place
than at every call site.

`onDeviceNotBound` is an optional trailing parameter
(`((_ tokenUniqueReference: String?, _ amountMinorUnits: Int64, _ rail: String) -> Void)? = nil`).
Unlike the other two, it is also a **card state**: the same card reads `deviceNotBound == true` in
`tokens()` from then on, until it is removed.

**A refusal the SDK could not attribute to a card** — the callback's `tokenUniqueReference` is
`nil` — reaches **every** registered handler rather than none. iOS fires these from the QR rails
only (`rail` is `"CPM_QR"` or `"MPM_QR"`), having no tap-to-pay.

---

## Cancelling a call

A payment or an add-card can be cancelled **only while its request is still on the phone**. Each
call has one point of no return: the moment its request is handed to the network. Before it, a
cancel stops the call and nothing is sent. After it, the cancel is refused and the call carries on
to its normal result: an approved, declined or pending payment cannot be taken back from the phone.

Every cancel names the call by a **reference you already hold**:

| Call | Cancel with | Reference |
|---|---|---|
| Card tap (`tap.session`), customer-QR charge (`payments.chargeCustomerQr`), get-paid QR create (`payments.createContext`) | `VeyraSoftPOS.shared.payments.cancelPayment(merchantOrderID:)` | The `merchantOrderID` the payment was started with. You don't say which rail: the order ID identifies the payment |
| Scan to pay (`wallet.payScannedContext`) | `wallet.cancelPayment(merchantOrderID:)` | `VerifiedPayment.merchantOrderID` — the order ID signed into the scanned QR. `nil` on a QR that carries none: that payment cannot be cancelled (disable your Cancel button while it is paying) |
| Add a card (`wallet.digitise`) | `wallet.cancelDigitise(clientRequestID:)` | The `clientRequestID` you passed to `digitise`. Pass none and the SDK generates one, and that add-card cannot be cancelled by reference |

The merchant's and the wallet's payments are kept apart: in a combined app the wallet's
`cancelPayment(merchantOrderID: "ORDER-1")` can never cancel the merchant's own payment with the same
order ID.

### API

| Member | Returns | Description |
|---|---|---|
| `VeyraSoftPOS.shared.payments.cancelPayment(merchantOrderID:)` | `CancelResult` | Cancel the merchant payment started with this order ID — tap, customer-QR charge or get-paid QR create — while it is still on the phone. Synchronous; answers at once |
| `wallet.cancelPayment(merchantOrderID:)` | `CancelResult` | Cancel the scan-to-pay of the QR carrying this order ID while it is still on the phone. Synchronous; answers at once |
| `wallet.cancelDigitise(clientRequestID:)` | `CancelResult` | Cancel the add-card started with this `clientRequestID` while it is still on the phone. Synchronous; answers at once |
| `wallet.digitise(DigitiseParams(..., clientRequestID:))` | `DigitiseResult` | Optional, default `nil`: your reference for this add-card attempt, the one `cancelDigitise` names |
| `CancelResult` | — | The answer to a cancel (`VeyraCommon`, re-exported by both products): `.cancelled`, `.tooLateToCancelRequestAlreadySent`, `.tooLateToCancelTaskAlreadyProcessed`, `.noPaymentInProgressForOrderID`, `.noDigitisationInProgressForClientRequestID`. `rawValue` is the wire string (`"CANCELLED"`, …) for logs |

### What the cancel answers, and what to show

The cancel answers at once with a `CancelResult`. **That is the answer to the cancel, never the
call's outcome**: the call still delivers its own result to its `await` (or to the tap's `.result`
event), exactly once.

| `CancelResult` | What happened | What your app shows |
|---|---|---|
| `.cancelled` | The call was stopped before anything was sent. Its result arrives as `NOT_SENT` / `CANCELLED` | Go back to the previous screen when that result arrives. The same order ID or `clientRequestID` can be used again |
| `.tooLateToCancelRequestAlreadySent` | The request has already left the phone. The call carries on | "This can no longer be cancelled" — keep waiting, and show the call's own result (approved, declined, pending…) when it arrives |
| `.tooLateToCancelTaskAlreadyProcessed` | The call had already finished | No message: keep waiting for (or keep showing) the result it delivered |
| `.noPaymentInProgressForOrderID` | No payment with that order ID is armed or running on this phone (wrong ID, never started, already finished, or a scanned QR with no order ID) | Just go back |
| `.noDigitisationInProgressForClientRequestID` | No add-card with that `clientRequestID` is running (wrong ID, started without one, or already finished) | Just go back |

```swift
// Merchant: the Cancel button on the tap / charge / QR waiting screen.
switch VeyraSoftPOS.shared.payments.cancelPayment(merchantOrderID: orderID) {
case .cancelled:
    break                                    // the payment's own result is NOT_SENT / CANCELLED → go back there
case .tooLateToCancelRequestAlreadySent:
    hint = "This can no longer be cancelled" // keep waiting for the result
case .tooLateToCancelTaskAlreadyProcessed:
    break                                    // already finished: keep waiting for its result, no message
case .noPaymentInProgressForOrderID, .noDigitisationInProgressForClientRequestID:
    goBack()                                 // nothing in flight
}

// …and where the result arrives (tap .result, chargeCustomerQr, createContext):
if result.responseStatus == VeyraResponseStatus.notSent && result.responseStatusReason == "CANCELLED" {
    goBack()                                 // nothing was charged; the order ID is still unused
}

// Wallet add-card: pass your own clientRequestID so the attempt can be cancelled.
let requestID = UUID().uuidString
let r = try await wallet.digitise(DigitiseParams(/* … */, clientRequestID: requestID))
// Cancel button, while that await is running:
let answer = wallet.cancelDigitise(clientRequestID: requestID)

// Wallet scan-to-pay: cancel by the order ID in the QR (hide Cancel when it is nil).
if let orderID = payment.merchantOrderID {
    let answer = wallet.cancelPayment(merchantOrderID: orderID)
}
```

**Swift `Task` cancellation is honoured too.** Cancelling the `Task` that awaits `digitise`,
`payScannedContext`, `chargeCustomerQr` or `createContext` cancels the call the same way, with no
reference needed (for `digitise` this works even without a `clientRequestID`). It cannot return a
`CancelResult`: before the point of no return the `await` returns `NOT_SENT` / `CANCELLED`; after
it, the `Task` cancellation is ignored and the `await` returns the call's normal result. Use the
explicit cancel when you need to tell the user which happened.

### Which steps can be cancelled

Everything **before sending** can be cancelled; **once the request is sent, nothing can**.

| Rail | Cancellable (still on the phone) | Not cancellable (sent) |
|---|---|---|
| Card tap (merchant) | Arming the reader and waiting for a tap; reading the card; the window after the card is read (`.cardReadingComplete`) until the request is sent — the card's cryptogram is discarded and never sent later | From `.sendingRequestOnline` on |
| Customer-QR charge (merchant) | Building the charge | Once the charge is sent |
| Get-paid QR create (merchant) | Building the create request | Once it is sent. A QR that is already showing has nothing in flight on the phone: no cancel to call — just leave the screen (and call `cancelQrExpiry()`) |
| Scan to pay (wallet) | Checking the card and its keys; the key top-up beforehand; the Face ID / Touch ID / passcode sheet; building the payment | Once the payment is sent |
| Add a card (wallet) | Device attestation; preparing the device key | Once the request is sent to the token service |
| Show QR to pay (wallet) | — no wallet-side cancel | The wallet sends nothing: the **merchant's** charge is the request, under an order ID the merchant assigns. Only the merchant can cancel it, with `payments.cancelPayment(merchantOrderID:)`. Taking the QR off the screen does not stop a merchant who has already scanned it |

**Leaving a screen.** When a waiting screen goes away, cancel what it started by its reference
(`cancelPayment(merchantOrderID:)` on the tap and charge screens, and on the get-paid QR screen while the QR is still being created). A payment that has
already been sent is not cancelled: it runs to its result, which the SDK records in history.

### A cancelled call ends `NOT_SENT` / `CANCELLED`

A cancel that wins ends the call with `responseStatus` `NOT_SENT`, `responseStatusReason`
`CANCELLED` and no `responseCode`. It is an ordinary `NOT_SENT` outcome — nothing reached Veyra, the
order ID (or `clientRequestID`) is still unused and may be used again. See
[Handling outcomes](#handling-outcomes--the-response-triple).

### Migrating from 2.x

| 2.x | 3.0.0 |
|---|---|
| `TapPaymentSession.cancel()` | **Removed.** It stopped the tap at any point — even after the payment had been sent to the bank, dropping an answer that was still coming. Call `VeyraSoftPOS.shared.payments.cancelPayment(merchantOrderID:)` with the session's order ID, on Cancel and when the screen leaves. Before sending it stops the reader and the tap's `.result` carries `NOT_SENT` / `CANCELLED`; after sending the payment runs to its normal result |
| No way to cancel a customer-QR charge, a get-paid QR create, a scan to pay or an add-card | `payments.cancelPayment(merchantOrderID:)` (merchant), `wallet.cancelPayment(merchantOrderID:)` and `wallet.cancelDigitise(clientRequestID:)` (wallet), or cancel the awaiting `Task` |
| `digitise(...)` had no reference you could pass | `digitise(..., clientRequestID:)` — optional; pass one to make the add-card cancellable |

## Errors and outcomes

Every SDK call ends in one of two ways:

1. **It throws** — only when your app has not set the SDK up correctly. These are bugs in your
   integration, found during development. You fix the code; you never show them to a user. See
   [Setup errors](#setup-errors--thrown).
2. **It returns an outcome** — for everything that happens while processing a request: approved,
   declined, failed, still pending, not sent to the bank (retry), or never sent. The outcome is always the same three fields:
   `responseCode` (payments only), `responseStatus`, `responseStatusReason`. See
   [Handling outcomes](#handling-outcomes--the-response-triple). A **read** (a status or credit
   check, a context poll) returns a [`VeyraLookup`](#veyralookup--the-answer-to-a-read) instead.

So a `do`/`catch` around an SDK call catches integration mistakes, and nothing else. A decline, a
lost connection or a dismissed Face ID sheet is never thrown: it comes back in the result.

### Setup errors — thrown

**What they mean:** the SDK cannot run the call at all, because of how the app called it. Nothing
was sent. Retrying will never help until the code changes.

**How to use them:** let them surface in development (crash, log, `assertionFailure`). Fix the
integration. Do not build user-facing screens for them, and do not offer the user a retry.

The same five cases exist on `VeyraWalletError` and `VeyraSoftPOSError` — the same five setup
errors as on Android (`VeyraSetupException`) and React Native (`VeyraError.code`). The combined
facade's `VeyraSDKError` has one case, `.notConfigured`.

| Error | When it happens | Fix |
|---|---|---|
| `.notConfigured` | Any call before `VeyraWallet.configure(customerID:config:provider:)` / `VeyraSoftPOS.configure(customerID:config:provider:)`. In a combined app, `VeyraSDKError.notConfigured` is thrown by `VeyraSDK.shared.currentMode()`, `.wallet` and `.softpos` before `VeyraSDK.configure(customerID:config:provider:)` | Configure the SDK first, at app start. |
| `.notSignedIn` | Any call with no customer — after `signOut()`, before the next `configure` | Call `configure` with the customer before using the SDK. Don't call wallet or merchant APIs from screens reachable while signed out. |
| `.invalidConfiguration(message:)` | Thrown by `configure`: a provider it can't use (both kinds at once, a `providerType` that contradicts its protocol, a blank `clientId`); a provider of a different kind from an earlier `configure` in this process; a blank `customerID`. `VeyraSDK.configure` throws the member SDK's case. Thrown by the call that needs it: a missing required wallet setting (payment app provider ID, token requestor ID, Apple Team ID) on `verifyAccount` / `digitise`; and `TapPaymentSession.start()` when both SDKs are in one app without `VeyraSDK` | Fix the configuration. `message` names the exact problem. |
| `.sessionRequired` | A payment call made without its screen session | Declared for parity with React Native, which raises it. On iOS the SDK follows the screen lifecycle itself, so you should never see it. |
| `.unsupportedOnPlatform` | A method this platform can't perform | Declared for parity with Android and React Native. The iOS SDK exposes no wallet tap-to-pay method at all (iOS does not allow card emulation), so no current iOS call throws it — the wallet pays by QR. |

Every case conforms to `LocalizedError`, so `error.localizedDescription` carries the message for your
logs.

### Handling outcomes — the response triple

**What they mean:** the SDK ran the call. The outcome tells you what happened and, through the
status, whether to retry and under which order ID.

**How to use them:** **branch on `responseStatus` first, then on `responseStatusReason`.** Use
`responseCode` only for receipts, disputes and support. Never branch on the message text — it is for
display and logs. Treat a reason you don't recognise as a failure you can't classify (show the
message), never as a parse error: new reasons are added without notice.

On iOS all three fields are plain strings (`String`, or `String?` where a result predates the
field), so a status or reason added after your build still reaches you. Compare `responseStatus`
with the `VeyraResponseStatus` constants (or the string literals) and always keep a `default`
branch:

```swift
public enum VeyraResponseStatus {           // import VeyraWallet / VeyraSoftPOS
    static let approved = "APPROVED"
    static let declined = "DECLINED"
    static let failed   = "FAILED"
    static let pending  = "PENDING"
    static let notSent  = "NOT_SENT"         // the SDK's own: no service ever states it
    static let retry    = "RETRY"            // stated by Veyra: reached it, never sent to the bank
}
```

#### The six statuses

| `responseStatus` | What it means | Did the request reach Veyra? | Merchant order ID reusable? (payments) | What your app does |
|---|---|---|---|---|
| `"APPROVED"` | It was done | Yes | **No** — the order is paid | Complete the sale / show the card |
| `"DECLINED"` | It was done, and someone with authority refused (issuer, bank, risk rules). No money moved | Yes | Yes | Show the reason. Don't retry automatically; another card or method can be tried under the **same** order ID |
| `"FAILED"` | Veyra received it and didn't perform it, and retrying with the same reference won't help. On a call that is not a payment or add-card, also: it never reached Veyra, or the phone refused it (the reason says which) | Yes — or, on a non-payment call, maybe not | Yes — except after `94`, where the order is already paid or still being confirmed | Fix what the reason names, then try again |
| `"PENDING"` | It may have been done; the outcome is not known yet | Maybe | **No** — it might be paid | **Never retry.** The SDK keeps checking and tells you when it's final; you can also find the sale's row by its merchant order ID in history and refresh it |
| `"RETRY"` | It reached Veyra, but the debit was never requested. Nothing was charged | Yes | Yes | Fix what the reason names, then retry with the **same** order ID |
| `"NOT_SENT"` | A payment or add-card never reached Veyra (the phone stopped it). Nothing was done | No | Yes | Fix what the reason names (connect, authenticate, …), then retry with the **same** order ID |

**Only payments and add-card answer `NOT_SENT`.** It exists to tell you that a payment or a
digitisation never happened, so its reference is still unused and a retry cannot double-charge. The
calls that can answer it are the card tap (`tap.session`), `payments.chargeCustomerQr`,
`payments.createContext`, the wallet's `payScannedContext` and `showQrToPay`, and `digitise`.
**Every other call answers `FAILED` with the same reason** — `NO_NETWORK_CONNECTION`,
`SDK_UNABLE_TO_CONNECT`, `NOT_AUTHENTICATED`, `INVALID_REQUEST`, `MISSING_MANDATORY_CONFIG`, … keep
their names: merchant registration, activate / deactivate / update / status and settlement banks;
wallet banks, `verifyAccount`, `requestActivationCode`, `activate`, `tokenStatus`,
`deactivateToken`; and the on-phone calls `inspectCustomerQr`, `processReceipt` and `setActiveToken`
(which never contact Veyra, so can never be "not sent"). Reads that return a `VeyraLookup` carry
only `failureReason`.

**`NOT_SENT` and `RETRY` are handled the same way:** nothing was charged, so fix the reason and try
again with the same order ID. The difference is only where it stopped — on the phone (`NOT_SENT`) or
inside Veyra before the bank was asked (`RETRY`) — and `responseStatusReason` tells you which step.

**The retry rule, in one line per status:**

- `NOT_SENT` / `RETRY` → fix the reason, retry with the **same** merchant order ID (or, for add-card, the same request).
- `DECLINED` → show the reason; another card or method can be tried under the **same** order ID.
- `FAILED` → fix what the reason names. On a call that is not a payment or add-card, that is
  all — no reference to keep: fix the reason (connect, sign in, …) and try again. For a payment this is mainly `94` /
  `DUPLICATE_MERCHANT_ORDER_ID`: the order is already paid or still being confirmed, so take no
  further payment for it.
- `PENDING` → **never retry**; the SDK resolves it and tells you. It is the only status where the
  outcome is unknown.
- Add-card has no order ID: a `FAILED` or `NOT_SENT` digitisation is simply tried again.

Four rules follow from it:

- **`NOT_SENT` never has a `responseCode`.** A code only ever means something on the network
  answered or failed to. `RETRY` does carry one — the code Veyra stated (`21`, `91`, …).
- **`PENDING` is never a failure.** Never show it as failed and never charge again. Show "We're
  checking this payment" and wait for the SDK's update — see
  [Waiting for a `PENDING` payment](#waiting-for-a-pending-payment).
- **Add-card (digitisation) is different.** There is no reference and no lookup. A digitisation that
  gets no answer ends `FAILED` (never `PENDING`), because the card's keys can never be delivered
  later. Start a new digitisation.
- **An order ID is reused until the order is paid or possibly paid.** The order ID is the
  `merchantOrderID` you pass to `tap.session`, `payments.chargeCustomerQr` and
  `payments.createContext`. Only an `APPROVED` or `PENDING` order refuses a new attempt — see
  [The merchant order ID](#the-merchant-order-id).

A wallet payment, handled the recommended way — `responseStatus` first, then `responseStatusReason`:

```swift
let outcome = try await wallet.payScannedContext(payment)
// Only a setup error can throw here. Everything below is an outcome.

switch outcome.responseStatus {
case VeyraResponseStatus.approved:
    showReceipt(outcome)
case VeyraResponseStatus.declined:
    showDeclined(outcome.message)                 // a new attempt is a new payment
case VeyraResponseStatus.pending:
    showChecking()                                // never pay again; the SDK resolves it
case VeyraResponseStatus.retry:                   // reached Veyra, not sent to the bank — nothing charged
    switch outcome.responseStatusReason {
    case "QR_EXPIRED", "AMOUNT_MISMATCH": askMerchantForNewCode()
    default: showTryAgain(outcome.message)
    }
case VeyraResponseStatus.notSent:                 // nothing was sent — the same QR can be paid again
    switch outcome.responseStatusReason {
    case "NO_NETWORK_CONNECTION": askToConnect()
    case "AUTH_CANCELLED", "AUTH_FAILED": stayOnConfirmScreen()
    case "AUTH_UNAVAILABLE": sendToSettings()
    case "ONLINE_REQUIRED": askToGoOnline()       // the SDK refreshes the card itself
    case "DEVICE_NOT_BOUND": askToReAddCard()
    default: showMessage(outcome.message)
    }
default:                                          // FAILED, or a status newer than this build
    showMessage(outcome.message)
}
```

A merchant sale, keeping the order ID for the next attempt until the order is paid (the sample's `GetPaidView` keeps it after `NOT_SENT`, `RETRY`, `DECLINED` and `FAILED` — see [Retrying a payment safely](#retrying-a-payment-safely)):

```swift
let outcome = try await VeyraSoftPOS.shared.payments.chargeCustomerQr(scanned, merchantOrderID: orderID)
switch outcome.responseStatus {
case VeyraResponseStatus.approved:
    showApproved(outcome.reference)                        // the order is paid
case VeyraResponseStatus.pending:
    showChecking()                                         // never charge again
case VeyraResponseStatus.notSent, VeyraResponseStatus.retry:
    retryOrderID = orderID                                 // nothing charged: same order ID
    showRetry(outcome.responseStatusReason)                // suggested copy below
case VeyraResponseStatus.failed where outcome.responseStatusReason == "DUPLICATE_MERCHANT_ORDER_ID":
    showAlreadyPaid(outcome.originalPayment?.responseStatus)   // APPROVED: paid; PENDING: being confirmed
default:
    retryOrderID = orderID                                 // DECLINED / FAILED: no money moved
    showRefused(outcome.responseStatusReason)
}
```

Suggested copy for `NOT_SENT` and `RETRY`, the sentence Veyra uses on every platform: "Payment not
sent to the bank - retry with the same order ID".

#### The merchant order ID

Your `merchantOrderID` names the **order**, not the attempt. An order can have several attempts — a
card that was declined, then another card; a name enquiry that failed, then a retry — and every
attempt is recorded under the same order ID, each with its own SDK-minted `reference`.

- **Use the same order ID again until the order is paid or possibly paid.** A new attempt is refused
  `94` / `FAILED` / `DUPLICATE_MERCHANT_ORDER_ID` only when the order is `APPROVED` or `PENDING`
  (including an attempt still in flight). The refusal carries the attempt that decided it as
  `originalPayment`: `responseStatus` `APPROVED` means "This order is already paid", `PENDING` "A
  payment for this order is still being confirmed". Take no further payment for the order either way.
- **After `DECLINED`, `FAILED`, `RETRY` or `NOT_SENT`, try again under the same order ID** — another
  card after a decline; fix the reason first after `FAILED`, `RETRY` or `NOT_SENT`.

**What an order's status is, from all its attempts.** Veyra decides it with a precedence rule, never
"the latest attempt wins" — a later attempt must never hide one that was paid or might be:

| Rank | If… | The order is… |
|---|---|---|
| 1 | any attempt is `APPROVED` | `APPROVED` — paid |
| 2 | otherwise, any attempt is `PENDING` (including one still in flight) | `PENDING` |
| 3 | otherwise | the status of the **latest** attempt: `DECLINED`, `FAILED` or `RETRY` — none moved money, so the newest is the current state |
| 4 | there are no attempts | nothing was charged; the order can be paid |

The attempt that sets the order's status (the approved one; else the pending one; else the latest) is
the one `originalPayment` describes on a `94`. When your app asks "what happened to order X?", call
`transactions.paymentStatus(merchantOrderID:)`: it applies this rule for you — including to attempts
this phone never recorded — and returns the deciding attempt plus every attempt. See
[Looking up a payment](#looking-up-a-payment).

#### Worked example — a `RETRY`, then the same order is paid

The first attempt stops before the bank is asked: the merchant's account lookup failed. Nothing was
charged, so the app keeps the order ID and the second attempt, under the **same** order ID, is
approved.

```swift
let orderID = "ORDER-1042"

// Attempt 1
var outcome = try await VeyraSoftPOS.shared.payments.chargeCustomerQr(scanned, merchantOrderID: orderID)
// outcome.responseCode         == "21"
// outcome.responseStatus       == "RETRY"
// outcome.responseStatusReason == "NAME_ENQUIRY_FAILED"
// Nothing was charged. The attempt is recorded in history under ORDER-1042 with status RETRY.
showRetry("Payment not sent to the bank — try again", outcome.responseStatusReason)

// The merchant taps "Try again", the customer shows their payment code again, and it is
// charged under the SAME order ID.
outcome = try await VeyraSoftPOS.shared.payments.chargeCustomerQr(rescanned, merchantOrderID: orderID)
// outcome.responseCode   == "00"
// outcome.responseStatus == "APPROVED"
showApproved(outcome.reference)

// History now has two rows for ORDER-1042 (RETRY, then APPROVED); the order is APPROVED.
// A third attempt under ORDER-1042 would be refused 94 / FAILED / DUPLICATE_MERCHANT_ORDER_ID,
// with originalPayment describing the approved attempt.
```

The same holds on every rail: a tap that ends `RETRY` re-arms `tap.session` with the same
`merchantOrderID`, and a QR whose push ended `RETRY` (`QR_EXPIRED`, say) is replaced by
`payments.createContext` for the same order.

#### `VeyraLookup` — the answer to a read

A read about a payment — a status check, a credit check, a context poll — does not carry a status of
its own: when it is about a payment, the payment's status is inside the value. It returns
`VeyraLookup<Value>`:

| Field | Meaning |
|---|---|
| `value: Value?` | The answer; for a refresh, the stored row as it now stands. `nil` when there is none (e.g. no row on this device has that reference) |
| `failureReason: String?` | Why the check could not be made (`NO_NETWORK_CONNECTION`, `SDK_UNABLE_TO_CONNECT`, `NOT_AUTHENTICATED`, `NO_RESPONSE_RECEIVED`, `UPSTREAM_ERROR`, …); `nil` when it was made |
| `message: String?` | A human-readable description of the failure, for logs and error text |
| `checked: Bool` | `true` when the check was made and answered (`failureReason == nil`) |

A check that could not be made never changes the stored row, and a read changes nothing, so
retrying it as is is always safe. Returned by `transactions.status(...)`,
`transactions.refreshStatus(reference:)`, `transactions.paymentStatus(merchantOrderID:)`, `transactions.creditConfirmation(...)`,
`transactions.refreshCreditConfirmation(reference:)`, `payments.contextStatus(txRef:)`,
`wallet.refreshTransactionStatus(transactionHash:)` and
`wallet.refreshCreditConfirmation(transactionHash:)`.

The other reads — the bank lists, `merchant.status`, `tokenStatus`, `verifyAccount` — return the
triple like any call, but are **never `PENDING`**: a read that got no usable answer is `FAILED`
with the reason, and is always safe to retry as is.

#### Where the triple lives on each call

| Call | Result type | Fields |
|---|---|---|
| `tap.session(...)` → `.result(_:)` | `TapPaymentResult` | `responseStatus`, `responseStatusReason`, `responseCode`, plus `reference` for the receipt |
| `payments.chargeCustomerQr(_:merchantOrderID:)` | `CustomerQrChargeOutcome` | `responseStatus`, `responseStatusReason`, `responseCode`; `approved` is `responseStatus == "APPROVED"` |
| `payments.createContext(...)` | `PaymentContextQR` | `responseStatus`, `responseStatusReason`, `message`; `txRef` / `mpmPayload` / `expiry` / `kid` only on `APPROVED` |
| `payments.inspectCustomerQr(_:)` | `CustomerQrInspection` | `responseStatus` (`APPROVED`, or `FAILED` / `INVALID_REQUEST` for "not a payment QR"), `responseStatusReason`, `message`, `qr` |
| `payments.contextStatus(txRef:)` | `VeyraLookup<PaymentContextState>` | `value.state` (the QR's lifecycle — see [QR context states](#qr-context-states)) and `value.responseCode` once settled, or `failureReason`. For the stated status and reason, read the sale's row with `transactions.refreshStatus(reference:)` |
| `transactions.history(limit:)` | `[MerchantTransaction]` | `status`, `responseCode`, `responseStatusReason` |
| `transactions.refreshStatus(reference:)` / `refreshCreditConfirmation(reference:)` | `VeyraLookup<MerchantTransaction>` | the row (`status`, `responseCode`, `responseStatusReason`), or `failureReason` |
| `transactions.paymentStatus(merchantOrderID:)` | `VeyraLookup<OrderPaymentStatus>` | `value.responseStatus` (the **order's**), with the deciding attempt's `responseCode` and `responseStatusReason`; `failureReason` when the gateway could not be asked |
| `transactions.status(...)` / `creditConfirmation(...)` | `VeyraLookup<[TransactionStatus]>` / `VeyraLookup<CreditConfirmation>` | the gateway's answer, or `failureReason` |
| `transactions.onTransactionResolved { }` | `TransactionResolution` | `status`, `responseCode`, `reason` |
| `merchant.register(_:)` | `MerchantRegistrationResult` | `responseStatus`, `responseStatusReason`, `message`; no `responseCode` |
| `merchant.status` / `activate` / `deactivate` / `update` | `MerchantStatus` | `responseStatus`, `responseStatusReason`, `message`; no `responseCode` |
| `merchant.banks()` | `SettlementBankList` | `responseStatus`, `responseStatusReason`, `message`; never `PENDING` |
| `wallet.payScannedContext(_:)` | `PaymentOutcome` | `responseStatus`, `responseStatusReason`, `responseCode`, `message`; `approved` is `responseStatus == "APPROVED"` |
| `wallet.showQrToPay(amountMinorUnits:onExpired:)` | `PaymentQr` | `responseStatus` (`APPROVED` or `NOT_SENT` only — nothing is sent), `responseStatusReason`, `message`. The merchant submits the payment; its outcome lands on the history row |
| `transactions(...)` | `[TransactionSummary]` | `authorizationStatus`, `responseCode`, `responseStatusReason` |
| `wallet.refreshTransactionStatus(transactionHash:)` / `refreshCreditConfirmation(transactionHash:)` | `VeyraLookup<TransactionSummary>` | the row, or `failureReason` |
| `wallet.observeTransactionResolved { }` | `WalletTransactionResolution` | `status`, `responseCode`, `reason` |
| `wallet.digitise(...)` / `verifyAccount(...)` | `DigitiseResult` / `VerifyAccountResponse` | `responseCode` (the issuer's decision — see [Table C](#table-c--veyra-token-service-wallet)), `responseStatus`, `responseStatusReason`, `message`. Never `PENDING` |
| `wallet.requestActivationCode(...)` / `activate(...)` | `ActivationCodeResponse` / `ActivateResponse` | `responseStatus`, `responseStatusReason` (on `FAILED`, the failure code), plus `status` (`"SUCCESS"` / `"FAILURE"`) and the typed `failureCode` — see [Activation](#activation--failurecode) |
| `wallet.deactivateToken(_:)` | `TokenStatusUpdateResponse` | `responseStatus`, `responseStatusReason`, `message`, `status`; only `APPROVED` removes the card |
| `wallet.tokenStatus(tokenUniqueReference:)` | `TokenStatusResult` | `tokenStatus`, `responseStatus`, `responseStatusReason`, `message`; never `PENDING` |
| `wallet.banks(accountNumber:)` | `BankList` | `responseStatus`, `responseStatusReason`, `message`; never `PENDING` |
| `wallet.setActiveToken(_:)` | `CardSelection` | `responseStatus` (`APPROVED`, or `FAILED` / `CARD_NOT_FOUND`), `responseStatusReason`, `message`, `selected` |
| `wallet.processReceipt(_:expectedTransactionHash:)` | `ReceiptScan` | `responseStatus` (`APPROVED` or `FAILED` — nothing is sent), `responseStatusReason`, `message`, `receipt` on `APPROVED` |
| `wallet.reconcilePendingTransactions()` | `ReconcileResult` | `failureReason` (only when the reconcile could not run), `message`, `checked`; no status — read the rows from history |

#### Table A — outcomes the SDK itself produces

The SDK only makes up an outcome when nothing on the network gave it one. These are the ones it can
produce on iOS. **`NOT_SENT` rows apply to payments and add-card only** (see
[The six statuses](#the-six-statuses)); on any other call the same reason arrives with `FAILED`.

| Status | Code | Reason | When | What your app does |
|---|---|---|---|---|
| `NOT_SENT` | — | `INVALID_REQUEST` | An argument is invalid (e.g. a blank `merchantOrderID`, amount ≤ 0) | Fix the call |
| `FAILED` | — | `INVALID_REQUEST` | `inspectCustomerQr` was given something that is not a Veyra payment QR, or a non-payment call got an invalid argument | For a scanned QR, show a hint and stay armed; otherwise fix the call |
| `NOT_SENT` | — | `NO_NETWORK_CONNECTION` | The phone has no internet connection | Ask the user to connect; retry with the same order ID |
| `NOT_SENT` | — | `SDK_UNABLE_TO_CONNECT` | The phone is online but could not connect to Veyra | Try again shortly with the same order ID |
| `NOT_SENT` | — | `NOT_AUTHENTICATED` | The SDK could not get credentials: your `VeyraAssertionProvider` returned `nil` or threw, your proxy reported a refusal, or the token endpoint refused | Check your provider. With an assertion provider this usually means nobody is signed in to your app — send the user to sign-in, then retry |
| `NOT_SENT` | — | `AUTH_CANCELLED` | Wallet: the customer dismissed the Face ID / Touch ID / passcode sheet | Stay on the confirm screen; let them try again |
| `NOT_SENT` | — | `AUTH_FAILED` | Wallet: device authentication did not succeed | Stay on the confirm screen |
| `NOT_SENT` | — | `AUTH_UNAVAILABLE` | Wallet: the device has no passcode and no biometrics | Send the customer to Settings — a retry can never succeed |
| `NOT_SENT` | — | `ONLINE_REQUIRED` | Wallet: the card has run out of payment keys | Ask the user to go online; the SDK refreshes the card. Pre-empt it: the card reads `requiresOnline == true` |
| `NOT_SENT` | — | `TOKEN_NOT_ACTIVE` | Wallet: the card is not active (e.g. suspended by the issuer) | Show the card's state. Payments resume by themselves once a status sync sees it active |
| `NOT_SENT` | — | `AMOUNT_EXCEEDS_CARD_LIMIT` | Wallet: the amount is larger than this card can pay in one go | Offer a smaller amount or another card. Going online does not help |
| `NOT_SENT` | — | `DEVICE_NOT_BOUND` | Wallet: the card was added on another device, or on this phone before the app was reinstalled | Remove the card and add it again on this phone — the only remedy. Pre-empt it: the card reads `deviceNotBound == true` |
| `NOT_SENT` / `FAILED` | — | `MISSING_MANDATORY_CONFIG` | SoftPOS: the call needs a registered merchant and none is stored on this device (`NOT_SENT` on a payment, `FAILED` on any other call) | Register the merchant (`merchant.register(_:)`) first |
| `NOT_SENT` | — | `MODE_REFUSED` | Combined apps: the other mode's payment is in progress | Wait for it to finish. Never happens in a single-product app |
| `NOT_SENT` | — | `CANCELLED` | Your cancel ([`cancelPayment`](#cancelling-a-call) / `cancelDigitise`, or a cancelled `Task`) stopped the call before it was sent | Go back to the previous screen; the same order ID / `clientRequestID` can be used again |
| `NOT_SENT` | — | `CARD_READ_FAILED` | Card tap: the card could not be read, so the payment ended before anything was sent | Ask the customer to tap again |
| `NOT_SENT` | — | `NO_ACTIVE_CARD` | Wallet: no card is set as active (scan-to-pay, show-QR-to-pay) | Ask the user to choose a card |
| `NOT_SENT` | — | `CARD_CANNOT_SHOW_QR` | Wallet: the active card can't produce a payment QR (show-to-pay) | Use another card |
| `NOT_SENT` | — | `CARD_CANNOT_PAY` | Wallet: the active card's material can't make a scan-to-pay payment | Remove the card and add it again |
| `NOT_SENT` | — | `SDK_INTERNAL_ERROR` | The SDK failed before sending | Report to support; retry with the same order ID |
| `FAILED` | — | `CARD_NOT_FOUND` | Wallet: `setActiveToken` was given a reference that is not in this wallet | Refresh the card list |
| `FAILED` | — | `NFC_UNAVAILABLE` | Wallet: `openPaySession()` — iPhone cannot pay by tap; always the answer on iOS | Offer the QR rails |
| `FAILED` | — | `INVALID_RECEIPT` / `RECEIPT_NOT_FROM_THIS_WALLET` / `RECEIPT_MISMATCH` / `PAYMENT_NOT_CONFIRMED` / `RECEIPT_FOR_ANOTHER_TRANSACTION` | Wallet: `processReceipt` refused the scanned receipt (see [`processReceipt`](#processreceipt--receipts--receiptfortransaction)) | Show the reason; for `PAYMENT_NOT_CONFIRMED`, scan again shortly |
| `PENDING` | `68` | `NO_RESPONSE_RECEIVED` | Payments: the request was sent but no answer came back (timeout, connection lost) | Wait; the SDK stores the payment and resolves it |
| `PENDING` | `06` | `UPSTREAM_ERROR` | Payments: Veyra answered with an error or something unreadable | Wait; the SDK stores the payment and resolves it |
| `PENDING` | — | `SDK_INTERNAL_ERROR` | Payments: the SDK failed after sending | Wait; the SDK still resolves the payment |
| `PENDING` | — | `NO_RESPONSE_RECEIVED` / `UPSTREAM_ERROR` / `SDK_INTERNAL_ERROR` | Calls that change state (merchant registration, activate, deactivate, update; QR creation; activation; card removal): sent, no usable answer | Don't repeat blindly: read the state first (`merchant.status`, `tokenStatus`); for a QR, create a new one |
| `FAILED` | — | `NO_RESPONSE_RECEIVED` / `UPSTREAM_ERROR` / `SDK_INTERNAL_ERROR` | Reads (bank lists, `merchant.status`, `tokenStatus`, `verifyAccount`): no usable answer. A read changes nothing, so it is never `PENDING` | Retry as is |
| `FAILED` | — | `NO_RESPONSE_RECEIVED` / `UPSTREAM_ERROR` / `SDK_INTERNAL_ERROR` | **Add-card only:** no usable answer after sending. Never `PENDING` — the card's keys can never be delivered later | Start a new digitisation |
| `FAILED` | — | `UNRECOGNISED_RESPONSE_CODE` | **Add-card only:** the token service answered with a code this SDK version doesn't know. The card was discarded and nothing was stored, even if the answer carried token data | Start a new add-card; update the SDK if it persists. `message` quotes the raw code |

**Only a refused connection proves nothing was sent.** A connect timeout or a connection lost
mid-exchange may have delivered the request and lost only the reply, so it is `PENDING`, never
`NOT_SENT`. Support logs show the SDK's internal name for what it saw (`ISSUER_CONNECTION_TIMEOUT`,
`ISSUER_HTTP_ERROR`, `ONLINE_PROCESSING_FAILED`, a `STATE_MACHINE_*` code, …); your app only ever sees
the reason in this table.

**Most card-read problems never end the sale.** When the target is a foreign card, a non-EMV
device, or the phone moves away, the tap session fires `.unsupportedTarget` or `.cardContactLost`,
the reader stays armed, and no result is delivered. Give the merchant one message, "Card not
supported — try another card", and keep the waiting screen up. Only when a read fails partway
through the card dialogue does the payment end, as `NOT_SENT` / `CARD_READ_FAILED`: nothing was
sent, so ask the customer to tap again. The internal codes support logs show for them are `NO_NFC_TAG`,
`NFC_CONNECTION_FAILED`, `APPLICATION_SELECTION_FAILED`, `NO_COMBINATION_RESULT`, `NO_AID_SELECTED`,
`NO_GPO_RESULT`, `GPO_FAILED`, `READ_RECORDS_FAILED`, `PROCESSING_RESTRICTIONS_FAILED`,
`CID_VALIDATION_FAILED`, `NO_FINAL_CID`, `GENERATE_AC_FAILED`, `NO_CRYPTOGRAM_RESULT`,
`CDA_FAILED_TC`, `CDA_FAILED_AAC`, `NO_TTQ_IN_PDOL` and `TC_NOT_SUPPORTED` (the card approved
offline; this product authorises online only).

**Three things end with "get online", and they are not the same thing:**

- **`NO_NETWORK_CONNECTION`** — the *phone* has no connection. Every call ends the same way until
  the user reconnects. The card is fine: don't grey it out.
- **`ONLINE_REQUIRED`** — the *card* has run out of payment keys. The phone is usually online
  already; the SDK refreshes the card itself, typically within seconds.
- **`SDK_UNABLE_TO_CONNECT`** — the phone is online but could not reach Veyra. Nothing was sent;
  try again shortly. This is not `91` (`ISSUER_SWITCH_NOT_AVAILABLE`), which is a `RETRY`: Veyra
  received the payment and could not reach the bank. Both are retried with the same order ID; the
  reason says where it stopped.

`AMOUNT_EXCEEDS_CARD_LIMIT` and `DEVICE_NOT_BOUND` do not resolve by connecting at all.

The same refusals are also delivered per token as they happen — see [`observePaymentRefusals`](#observepaymentrefusals--card-refusals-per-card).

#### The triple is the same on every Veyra service

The triple is not payment-only. Every Veyra service the SDK talks to (the Veyra payment gateway, the
Veyra token service, and through them the switch and the issuer's gateway) answers with the same
fields: `responseStatus` (`APPROVED` / `DECLINED` / `FAILED` / `PENDING`, and `RETRY` on payments) and
`responseStatusReason`, plus a human `message`. **Payments** also carry `responseCode`, an
ISO 8583-style code. **Add-card** carries its own decision in `responseCode`: `APPROVED`,
`APPROVE_REQUIRE_AUTH` or `DECLINED` (not an ISO number). Other non-payment calls carry no
`responseCode`. The SDK passes all of these to your app unchanged.

#### Table B — payments

From the Veyra payment gateway; the codes come from the bank, the issuer's gateway and the switch.
The same vocabulary is used on every rail — contactless tap, both QR rails, the settlement leg and
every status lookup. One code always means one reason.

| Code | Status | Reason | Meaning | What your app does |
|---|---|---|---|---|
| `00` | `APPROVED` | `APPROVED` | Approved | Complete; show the receipt |
| `05` | `DECLINED` | `DO_NOT_HONOR` | The bank refused without a specific reason | Show it; offer another payment method |
| `07` | `RETRY` | `ACCOUNT_VALIDATION_FAILED` | The beneficiary account failed validation before the bank was asked; nothing was charged | Check the merchant's account details, then retry with the same order ID |
| `14` | `DECLINED` | `INVALID_TOKEN` | The card token is not valid | The customer should re-add the card |
| `21` | `RETRY` | `NAME_ENQUIRY_FAILED` | The beneficiary account lookup could not be completed before the bank was asked; nothing was charged | Check the merchant's account details, then retry with the same order ID |
| `51` | `DECLINED` | `INSUFFICIENT_FUNDS` | Not enough funds | Offer another payment method |
| `54` | `DECLINED` | `EXPIRED_CARD_OR_TOKEN` | The card or token has expired | Re-add the card |
| `58` | `DECLINED` | `DOMAIN_RESTRICTION_FAILED` | The card can't be used this way (wrong channel / domain) | Offer another payment method |
| `61` | `DECLINED` | `LIMIT_EXCEEDED` | An amount limit was exceeded | Offer a smaller amount |
| `63` | `DECLINED` | `SUSPECTED_FRAUD` | Refused by risk checks | Don't retry |
| `65` | `DECLINED` | `VELOCITY_LIMIT_EXCEEDED` | Too many payments in a short time | Try later |
| `09` | `PENDING` | `TRANSACTION_IN_PROCESS` | Still being processed | Wait |
| `09` | `PENDING` | `TRANSACTION_IN_PROCESS_ESCALATED` | A person is reconciling it | Show "we're looking into this"; the SDK re-checks less often |
| `68` | `PENDING` | `NO_RESPONSE_RECEIVED` | A hop timed out | Wait |
| `06` | `PENDING` | `UPSTREAM_ERROR` | A hop answered with an error | Wait |
| `96` | `PENDING` | `SYSTEM_MALFUNCTION` | The Veyra payment gateway hit an internal error while processing | Wait; the SDK resolves it |
| `12` | `RETRY` | `QR_EXPIRED` | QR payments: the payment code expired; nothing was charged | Show a new QR for the same order |
| `13` | `RETRY` | `AMOUNT_MISMATCH` | QR payments: amount or currency doesn't match the code; nothing was charged | Show a new QR for the same order; never re-key the amount |
| `25` | `RETRY` | `UNABLE_TO_LOCATE_RECORD` | A status lookup found no such payment | Nothing was charged; the order can be paid, with the same order ID |
| `30` | `RETRY` | `INVALID_REQUEST` | The gateway refused the request before sending it on; nothing was charged | Fix the request, then retry the same order |
| `91` | `RETRY` | `ISSUER_SWITCH_NOT_AVAILABLE` | Veyra could not reach the bank; nothing was charged | Try again shortly with the same order ID |
| `94` | `FAILED` | `DUPLICATE_MERCHANT_ORDER_ID` | The order is already paid or still being confirmed; `originalPayment` carries the attempt that decided it | Do not take another payment for the order. `originalPayment.responseStatus` `PENDING`: "A payment for this order is still being confirmed"; otherwise "This order is already paid" |

**`FAILED` on a payment** now means Veyra received it, didn't perform it, and retrying with the same
reference won't help — in practice mainly `94`. It doesn't use up the order ID. Every code that used
to be `FAILED` because the payment stopped before the bank was asked (`07`, `12`, `13`, `21`, `30`,
`91`) is now `RETRY`, with the same code and reason.

**Payment status lookups** (`transactions.refreshStatus(reference:)`,
`wallet.refreshTransactionStatus(transactionHash:)`, and the rows `reconcilePendingTransactions()` updates) carry
the stored payment's triple from this table, or `25` / `RETRY` / `UNABLE_TO_LOCATE_RECORD` — no such
payment, so nothing was charged and the order can be paid. If the
lookup itself fails, the `VeyraLookup` (or `ReconcileResult`) carries a `failureReason` and the payment is left as it was
(the SDK's own sweep tries again) — a failed lookup is never the payment's outcome.

#### Table C — Veyra token service (wallet)

`VeyraWallet` only: add-card, activation, card lifecycle and keys.

| Call | Status | Code | Reason | Meaning / what your app does |
|---|---|---|---|---|
| Add card (`digitise`, `verifyAccount`) | `APPROVED` | `APPROVED` | — | The card is added and active (`isApproved`) |
| Add card | `APPROVED` | `APPROVE_REQUIRE_AUTH` | The cause, when there is one (e.g. `ACCOUNT_NAME_MISMATCH`) | Added, but the customer must activate it (`requiresActivation`); run [activation](#activation) with the returned `activationMethods` |
| Add card | `DECLINED` | `DECLINED` | The issuer's reason — see below | The issuer refused this account; show the reason. The flow ends |
| Add card | `FAILED` | — | `INTERNAL_ERROR` | The token service could not complete it; start a new add-card |
| Add card | `FAILED` | — | `NO_RESPONSE_RECEIVED` / `UPSTREAM_ERROR` | No answer ([Table A](#table-a--outcomes-the-sdk-itself-produces)); start a new add-card |
| Activation code request (`requestActivationCode`) | `FAILED` | — | The failure code, e.g. `TOKEN_NOT_FOUND`, `ACTIVATION_LOCKED`, `CODE_REQUEST_RATE_LIMITED`, `ACTIVATION_FAILED` (typed in `failureCode`) | Can't send a code now; locked or rate-limited → wait or contact the issuer |
| Activation code verify (`activate`) | `FAILED` | — | The failure code, e.g. `CODE_INVALID`, `CODE_EXPIRED`, `MAX_ATTEMPTS_EXCEEDED`, `NO_PENDING_ACTIVATION`, `TOKEN_NOT_ACTIVATABLE`, `ACTIVATION_LOCKED`, `TOKEN_NOT_FOUND`, `ACTIVATION_FAILED` (typed in `failureCode`) | Wrong or expired code → ask again (`attemptsRemaining` is included); max attempts or locked → remove the card and add it again |
| Card status / removal (`tokenStatus`, `deactivateToken`) | `FAILED` | — | `TOKEN_NOT_FOUND`, `TOKEN_STATE_CONFLICT`, `TOKEN_UNIQUE_REFERENCE_REQUIRED` | The card isn't known, or the change isn't allowed from its current state. A removal that is not `APPROVED` leaves the card on the device |
| Card key refresh (automatic) | — | — | — | The SDK refreshes keys itself, so you never see these reasons. An expired or inactive card is never refreshed — it reads `requiresOnline` or `deviceNotBound`, or its `status` shows why; add it again |
| Bank lookup (`banks(accountNumber:)`) | `FAILED` | — | `INVALID_ACCOUNT_NUMBER` | Check the account number |

**Two different fields on add-card.** `responseCode` is the issuer's **decision** about the account
and device. `responseStatus` is what the **call** did: `DECLINED` means it ran and the answer is no;
`FAILED` means nothing was decided about the account. Branch on `responseStatusReason` for the cause;
`message` is the same cause worded for display.

##### Add a card — the issuer's causes

The issuer states a symbolic cause for every non-approval, and you receive it as
**`responseStatusReason`**. `message` is the same cause worded for a human: display that, but never
match on it, because the wording can change while the code does not. Keep a default branch: the
vocabulary grows without an SDK release, and a cause added after your build reaches you unchanged.

**Identity did not match — these ask for step-up rather than refusing** (`APPROVE_REQUIRE_AUTH`, so
run the activation flow with the returned `activationMethods`):

| Cause | The `message` you receive |
|---|---|
| `ACCOUNT_NAME_MISMATCH` | "Account name does not match; step-up authentication required" — on the earlier availability check it is the plain "Account name does not match" |
| `BVN_MISMATCH` | "BVN does not match; step-up authentication required" |
| `ACCOUNT_NOT_LINKED_TO_BVN` | "Account is not linked to the supplied BVN; step-up authentication required" |
| `ACCOUNT_ADDRESS_MISMATCH` | "Account address does not match; step-up authentication required" |

A mismatch usually means the details your app sent do not match the bank's record. The account
holder name, address and BVN you pass are compared with core banking, so check what you collected
before telling the customer their bank has a problem.

**The account cannot be tokenised** (`DECLINED` — the flow ends):

| Cause | The `message` you receive |
|---|---|
| `ACCOUNT_TYPE_NOT_ALLOWED` | "Account type is not permitted for token digitisation" |
| `JOINT_ACCOUNT_NOT_ALLOWED` | "Joint accounts are not permitted for token digitisation" |
| `ACCOUNT_INACTIVE` | "Account is not active" |
| `ACCOUNT_BLOCKED` | "Account is blocked" |
| `ACCOUNT_CLOSED` | "Account is closed" |
| `ACCOUNT_DND` | "Account has a Do Not Digitise flag" |
| `ACCOUNT_DNC` | "Account has a Do Not Contact flag" |
| `UNKNOWN_ACCOUNT` | "Unable to retrieve account details" |

**This device, wallet or product is not permitted** (`DECLINED` — retrying the same way cannot help):

| Cause | The `message` you receive |
|---|---|
| `DEVICE_NOT_ALLOWED` | "Device type is not permitted" |
| `DEVICE_REGION_NOT_ALLOWED` | "Device region is not permitted" |
| `WALLET_NOT_ALLOWED` | "Wallet is not permitted" |
| `TOKEN_REQUESTOR_NOT_ALLOWED` | "Token requestor is not permitted" |
| `STORAGE_TECH_NOT_ALLOWED` | "Storage technology is not permitted" |
| `ACCOUNT_SOURCE_NOT_ALLOWED` | "Account number source is not permitted" |
| `PAYMENT_APPLICATION_NOT_ALLOWED` | "Payment application is not permitted" |
| `TOKEN_TYPE_NOT_ALLOWED` | "Token type is not permitted" |
| `CUSTOMER_ID_NOT_ALLOWED` | "Customer identifier is not permitted" |
| `MAX_ACTIVE_TOKENS_EXCEEDED` | "Maximum number of active tokens has been exceeded" — the customer must remove a card before adding another |
| `NO_VALID_ACTIVATION_METHOD` | "No valid activation method is available" — the issuer has no way to reach this customer for step-up |

**Risk refused it** (`DECLINED`):

| Cause | The `message` you receive |
|---|---|
| `RISK_SCORE_BELOW_THRESHOLD` | "Risk score exceeds the configured threshold" |
| `WALLET_PROVIDER_DEVICE_SCORE_TOO_LOW` | "Wallet provider device score is too low" |
| `WALLET_PROVIDER_ACCOUNT_SCORE_TOO_LOW` | "Wallet provider account score is too low" |
| `WALLET_PROVIDER_ACCOUNT_NOT_RECOGNISED` | "Wallet provider account could not be recognised" |

The last three are scored partly from what **your app** supplies — the device and account trust
scores, the recommendation and its reasons, and the wallet account identifier. Pass the account's
registered email or phone, never an internal id: the issuer hashes it and compares it with its own
record, so a value the bank does not hold matches nothing.

Anything else — including a cause added after your build — arrives as "Account is not eligible for
tokenisation" / "Account is not available for tokenisation". Show the message; never assume a
specific cause from a `DECLINED` alone.

##### Activation — `failureCode`

`ActivationCodeResponse` and `ActivateResponse` carry the outcome as `responseStatus` /
`responseStatusReason` like every other call. On `FAILED` the reason **is** the failure code, and the
typed `failureCode` (`ActivationFailureCode`) carries it with the wire value in `failureCodeRaw`;
`status` (`"SUCCESS"` / `"FAILURE"`) is still there. **Branch on `responseStatus` first** — a `FAILED`
that never reached Veyra (`NO_NETWORK_CONNECTION`, …: fix it and retry) and `PENDING` (no usable answer: wait, or read the token status) have no
`failureCode` — then, on `FAILED`, on `failureCode`, never on `message`:

| `failureCode` | Meaning | What to do |
|---|---|---|
| `.codeExpired` | Code lapsed; attempts may remain | Offer "resend code". |
| `.codeInvalid` | Wrong code, attempts remain | Stay on entry; show `attemptsRemaining`. |
| `.maxAttemptsExceeded` | The attempt limit for this code is used up | The cycle is closed; honour `recommendDelete` (`.must`: delete the card and restart add-card; `.may`: advisory). |
| `.codeRequestRateLimited` | Too many code requests for this card in the last hour | Disable "resend" with a cool-down message — do **not** end the flow. |
| `.noPendingActivation` | No live code (never requested, or the pending window lapsed) | Request a code first. |
| `.activationLocked` | Locked after repeated exhausted cycles | Terminal — hide both retry and resend; the issuer must unlock it. Direct the user to their bank. |
| `.tokenNotFound` / `.tokenNotActivatable` | No activatable card behind the reference | End the flow; add the card again or contact the issuer. |
| `.invalidRequest` / `.activationFailed` | Malformed request / server-side activation error | Show `message`; `.activationFailed` is safe to retry later. |
| `.unknown(raw:)` | A code newer than this SDK | Show `message`; log the raw value. |

#### Table D — Veyra payment gateway, non-payment calls (SoftPOS)

`VeyraSoftPOS` only: merchant and QR codes. Status is `FAILED` for every row; there is no
`responseCode`. A merchant call that never reached the gateway is `FAILED` too, with the SDK's own
reason (`NO_NETWORK_CONNECTION`, `SDK_UNABLE_TO_CONNECT`, `NOT_AUTHENTICATED`, …) — only QR creation,
a payment, says `NOT_SENT` for that.

| Call | Reasons | What your app does |
|---|---|---|
| Merchant registration (`merchant.register(_:)`) | `MERCHANT_TYPE_REQUIRED`, `MERCHANT_NAME_REQUIRED`, `EMAIL_ADDRESS_REQUIRED`, `PHONE_NUMBER_REQUIRED`, `ACCOUNT_NUMBER_REQUIRED`, `ADDRESS_LINE_1_REQUIRED`, `CITY_REQUIRED`, `BANK_INSTITUTION_CODE_REQUIRED`, `PAYMENT_APP_PROVIDER_ID_REQUIRED`, `CAC_NUMBER_REQUIRED` | Ask for the missing field |
| Merchant update / status / activate / deactivate (`merchant.update`, `status(merchantID:)`, `activate`, `deactivate`) | `MERCHANT_ID_REQUIRED`, `MERCHANT_NOT_FOUND`, `INVALID_REQUEST` (change not allowed from the current state) | Fix the request / check the merchant's state |
| QR payment code creation (`payments.createContext`) | `AMOUNT_REQUIRED`, `MERCHANT_NOT_FOUND`, `INVALID_REQUEST`, `DUPLICATE_MERCHANT_ORDER_ID` (includes the original payment) | Fix the request and create the QR again for the same order. `DUPLICATE_MERCHANT_ORDER_ID`: the order is already paid or being confirmed — take no further payment for it |

#### Generic fallbacks

`INVALID_REQUEST`, `NOT_FOUND`, `INTERNAL_ERROR` and `AUTHENTICATION_FAILURE`, with status `FAILED`,
can come from any Veyra service on any call. They are used when nothing more specific applies. Show
the message.

#### Where the codes come from

Payment outcomes travel unchanged from the bank, through the issuer's gateway, the switch and the
Veyra payment gateway, to the SDK. No hop re-interprets them, so the code your app sees is the code
the bank gave. The SDK only produces an outcome itself when it got no answer
([Table A](#table-a--outcomes-the-sdk-itself-produces)).

#### Waiting for a `PENDING` payment

A `PENDING` payment may well have completed, so the one thing you must not do is charge again.

1. **Stay on the confirmation screen** and show "We're checking this payment". Do not navigate away
   and do not print a receipt yet.
2. **Let the SDK resolve it.** It stores the transaction and polls with backoff; you do not have to.
3. **Finish when it settles** — from `onTransactionResolved` (below), or by reading the row with
   `transactions.refreshStatus(reference:)` / `transactions.history(limit:)`. On the wallet,
   `observeTransactionResolved` and `transactions(...)` do the same.

A pending row always converges: it becomes `APPROVED`, `DECLINED` or `FAILED` when the backend settles
it — or `RETRY` (`25` / `UNABLE_TO_LOCATE_RECORD`) when Veyra has no record of it, so nothing was
charged — or it stays `PENDING`. It never turns into an outcome the SDK made up, and there is no attempt cap
that gives up on it.

**`TRANSACTION_IN_PROCESS_ESCALATED`** is the one reason that changes what *you* do. Automated
reconciliation has stopped and a person will settle the payment. Stop any tight loop of your own, tell
the user "we're looking into this", and re-check lazily — next app open, or a long backoff. It will
still resolve; it just will not resolve in seconds.

##### `transactions.onTransactionResolved` — the SDK pushes the answer

```swift
try VeyraSoftPOS.shared.transactions.onTransactionResolved { resolution in
    // resolution.reference    — which payment (you may have more than one pending)
    // resolution.status       — "APPROVED" / "DECLINED" / "FAILED" / "RETRY" (never "PENDING")
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
- **Registration is single-listener: last registration wins.** Calling it again *replaces* the
  previous observer, and `stopObservingTransactionResolved()` clears it. If two parts of your app both
  want the answer, fan it out yourself from one registration.
- **It does not replay.** If your app was not running when the row settled, nothing is queued for you
  — read `transactions.history(limit:)` at start-up. Keep the read path.
- **The payment callback still fires exactly once**, possibly with `PENDING`. The resolution arrives
  on this separate channel; the two are not alternatives.
- It is delivered on the main queue, like the payment callback.

It fires from every rail this platform has — the tap reader, the merchant-presented QR settle and the
customer-QR charge.

##### `transactions.onCreditConfirmation` — the funds landed

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

Same rules as above — main queue, register once, **last registration wins**, no replay — plus one
that is specific to it: **`UNABLE_TO_CONFIRM` is a give-up, never a reversal.** The payment outcome is
unchanged; only the *settlement* could not be confirmed. The answer is also written to the sale's
stored row (`creditConfirmationStatus`), so a screen opened later still shows it.

#### Migrating from 2.x — the errors that became outcomes

In 2.x many of these were thrown. In 3.0.0 every one of them is an outcome on the call's result, and
`VeyraWalletError` / `VeyraSoftPOSError` hold only the five [setup errors](#setup-errors--thrown).
Move each `catch` branch to a `responseStatus` / `responseStatusReason` branch:

| 2.x thrown error | 3.0.0 outcome |
|---|---|
| `.requestFailed(message:)` | Retired. Depending on what happened: `NOT_SENT` / `SDK_UNABLE_TO_CONNECT` (the phone could not reach Veyra) or `NOT_SENT` / `SDK_INTERNAL_ERROR` on a payment or add-card — `FAILED` with the same reasons on any other call; `PENDING` / `NO_RESPONSE_RECEIVED` or `UPSTREAM_ERROR` for a payment or a state change that was sent; `FAILED` / the same reasons for add-card; `FAILED` / the same reasons for a read; or the backend's own `FAILED` / `DECLINED` with its reason |
| `.noNetworkConnection` | `NOT_SENT` / `NO_NETWORK_CONNECTION` on a payment or add-card; `FAILED` / `NO_NETWORK_CONNECTION` on any other call (`failureReason` on a `VeyraLookup`) |
| `.authenticationCancelled` / `.authenticationFailed` / `.authenticationUnavailable` | `NOT_SENT` / `AUTH_CANCELLED` / `AUTH_FAILED` / `AUTH_UNAVAILABLE` |
| `.notAuthenticated` | `NOT_SENT` / `NOT_AUTHENTICATED` on a payment or add-card; `FAILED` / `NOT_AUTHENTICATED` on any other call |
| `.onlineRequired` | `NOT_SENT` / `ONLINE_REQUIRED` |
| `.tokenNotActive` | `NOT_SENT` / `TOKEN_NOT_ACTIVE` |
| `.amountExceedsCardLimit` | `NOT_SENT` / `AMOUNT_EXCEEDS_CARD_LIMIT` |
| `.deviceNotBound` | `NOT_SENT` / `DEVICE_NOT_BOUND` |
| `.unrecognisedResponseCode(message:)` | `FAILED` / `UNRECOGNISED_RESPONSE_CODE` on `DigitiseResult` |
| `.tapRefused(message:)` | `NOT_SENT` / `MODE_REFUSED`, delivered as the tap's `.result` — `start()` no longer throws it |
| `.invalidRequest` | `NOT_SENT` / `INVALID_REQUEST` (a blank `merchantOrderID`); `FAILED` / `INVALID_REQUEST` ("not a payment QR" from `inspectCustomerQr`, or a bad argument on any other non-payment call) |
| A thrown error from `processReceipt` (a receipt that was not this wallet's, or did not match) | `ReceiptScan` with `FAILED` and `INVALID_RECEIPT` / `RECEIPT_NOT_FROM_THIS_WALLET` / `RECEIPT_MISMATCH` / `PAYMENT_NOT_CONFIRMED` / `RECEIPT_FOR_ANOTHER_TRANSACTION` |
| A thrown error from `reconcilePendingTransactions` | `ReconcileResult.failureReason` |
| A thrown error from `setActiveToken` (the card is not in this wallet) | `CardSelection` with `FAILED` / `CARD_NOT_FOUND` |
| None — new in 3.0.0. 2.x had no duplicate-order error: nothing checked a reused order ID (see the next table) | `FAILED` / `DUPLICATE_MERCHANT_ORDER_ID` (`94` on a payment) — the order is already paid or being confirmed; take no further payment for it |

Return types changed with it: `merchant.banks()` → `SettlementBankList`, `wallet.banks(...)` →
`BankList`, `tokenStatus(...)` → `TokenStatusResult`, `inspectCustomerQr(_:)` → `CustomerQrInspection`,
`processReceipt(...)` → `ReceiptScan` (was `TransactionReceipt`), `reconcilePendingTransactions()` →
`ReconcileResult` (was `Void`), `setActiveToken(_:)` → `CardSelection` (was `Void`),
the checks (`refreshStatus`, `refreshCreditConfirmation`, `transactions.status`,
`creditConfirmation`, `contextStatus`, `refreshTransactionStatus`) → `VeyraLookup`, and
`PaymentContextQR` / `PaymentQr` carry their outcome with optional payload fields.
`VeyraSDK.shared.currentMode` is now `get throws`.

**`RETRY` is new, and the merchant order ID now names the order across its attempts:**

| 2.x | 3.0.0 |
|---|---|
| `07`, `12`, `13`, `21`, `30`, `91` were `FAILED` | The same codes and reasons are `RETRY`: Veyra received the payment but never sent it to the bank — nothing was charged; retry with the same order ID |
| `25` / `UNABLE_TO_LOCATE_RECORD` on a lookup was `FAILED` | `25` / `RETRY`: no such payment, so the order can be paid |
| Nothing checked a reused order ID | The order ID is used for every attempt at the order — after `DECLINED`, `FAILED`, `RETRY` and `NOT_SENT` — until the order is `APPROVED` or `PENDING`; only then is a new attempt refused `94` / `DUPLICATE_MERCHANT_ORDER_ID` |

Add a `RETRY` branch wherever you branch on `responseStatus` (handle it like `NOT_SENT`), and keep
the order ID for the retry rather than minting a new one.

#### Card, merchant and QR states

These are not outcomes of a call. They are states the SDK keeps and reports, and they explain many of
the outcomes above.

##### Tap sessions that end without a card

`TapPaymentEvent.ended(outcome:)` means the reader session ended **without** a card, so nothing was
attempted and there is no triple. `TapSessionOutcome` is `.cancelled` (the merchant dismissed the
NFC sheet — dismiss quietly), `.timeout` (no card was presented — "try again"), `.error` (any other
session failure) or `.unavailable` (this device cannot read NFC). Create a new session to keep
accepting.

##### QR context states

`payments.contextStatus(txRef:).state` is the merchant-presented QR's own lifecycle:

| State | Meaning | What to do |
|---|---|---|
| `PENDING` | QR live, unpaid | Keep polling. |
| `IN_FLIGHT` | A wallet claimed it; settling | Keep polling. |
| `APPROVED` / `DECLINED` | Settled — `responseCode` carries the payment's code | Stop polling; result screen and receipt. |
| `EXPIRED` | Lapsed unpaid (your `onExpired` callback has blanked the QR) | Offer a fresh QR. An expired context is never recorded in history. |

##### Card lifecycle statuses

The wallet syncs each card's server status automatically (foreground sweeps and around payments).
What your app observes:

| Server status | Effect in the SDK | What to do |
|---|---|---|
| `ACTIVE` | Card pays normally | — |
| `SUSPENDED` / `EXPIRED` / `PENDING_ACTIVATION` | Card refuses to pay (`NOT_SENT` / `TOKEN_NOT_ACTIVE`); `StoredCard.status` shows the status | Render the card as unavailable. **Not sticky** — a later sync unfreezes it automatically. |
| `DEACTIVATED` | The card and all its material are wiped and it disappears from `tokens()` | Refresh your card list; the user re-adds the card if needed. |

To hear about these changes as they happen, see [`observeTokenStatusChanged`](#observetokenstatuschanged--the-sdk-tells-you-when-a-tokens-status-changes) and, for payment keys, [`observeCardKeyStateChanged`](#observecardkeystatechanged--a-token-ran-out-of-payment-keys-or-got-them-back) in [Observers](#observers).

##### Merchant statuses

`ACTIVE` / `INACTIVE` / `SUSPENDED` / `DEACTIVATED` (on registration results, `status()` responses and
every payment response's `merchantStatus`). Only an `ACTIVE` merchant can take payments — gate your
get-paid entry on `merchant.isRegistered` and the stored merchant's last known status.

##### `merchant.onMerchantStatusChanged` — the SDK watches it for you

The SDK polls the registered merchant's status in the background and tells you when it changes:

```swift
try VeyraSoftPOS.shared.merchant.onMerchantStatusChanged { change in
    // change.merchantID, change.status, change.previousStatus
    if !change.canAcceptPayments { disableGetPaid() }
}
```

Use it to stop offering to take payments the moment a merchant is deactivated mid-session, and to
catch the **activation** moment after registration without polling for it yourself.

**Branch on `canAcceptPayments`, not on `status`.** Anything that is not `ACTIVE`, including a status
newer than your build, is `false`.

**The polling is the SDK's and is app-scoped, not screen-scoped.** It starts at `configure` (and after
a successful `register`) and keeps running as the merchant navigates. iOS suspends timers when the OS
suspends your app, so polling pauses while backgrounded and resumes on foreground. **No answer is
lost** — a change that happened while you were away still arrives on the first poll after you return.

Only genuine changes fire, registration is single-listener with last-registration-wins, there is no
replay, and delivery is on the main thread. `stopObservingMerchantStatus()` clears it.

##### History status vocabularies

| Field | Values |
|---|---|
| Wallet `TransactionSummary.authorizationStatus` | `PENDING` (still being checked) / `APPROVED` / `DECLINED` / `FAILED` / `RETRY` (not sent to the bank — nothing charged) / `nil` (legacy row — indeterminate) |
| Merchant `MerchantTransaction.status` | `APPROVED` / `DECLINED` / `PENDING` (outcome unknown, the SDK keeps polling) / `FAILED` (Veyra received it but could not perform it) / `RETRY` (Veyra received it but never sent it to the bank — nothing charged; one row per attempt, so an order can show a `RETRY` row and then an `APPROVED` one) |
| Wallet scan rejection (`ScanInspection.rejected`) | `.malformed` / `.missingSignature` / `.unknownKey` / `.badSignature` (show "couldn't verify this code") / `.expired` (show "code expired — ask the merchant for a fresh one"). Every rejection ends the flow; no payment was attempted |

---

## Data models

Reference for the public models. All are immutable value types; fields not listed here are not public API.

```swift
// Shared (VeyraCommon, re-exported by both products):
public enum VeyraResponseStatus { static let approved, declined, failed, pending, notSent, retry }   // "APPROVED" … "RETRY"
public enum CancelResult: String {          // the answer to a cancel — never a call's outcome
    case cancelled, tooLateToCancelRequestAlreadySent, tooLateToCancelTaskAlreadyProcessed,
         noPaymentInProgressForOrderID, noDigitisationInProgressForClientRequestID   // rawValue "CANCELLED" …
}
public struct VeyraLookup<Value> {          // the answer to a read
    let value: Value?; let failureReason: String?; let message: String?
    var checked: Bool                       // failureReason == nil
}

public struct StoredCard {                  // wallet card display record
    let tokenUniqueReference: String        // identity for activation/removal/status
    let panLastFour: String
    let maskedPAN: String                   // "**** **** **** 1112"
    let expiry: String                      // "MM/YY"
    let cardHolderName: String      // "AFRIGO ****1234" — scheme + masked last four, not a person
    let accountHolderName: String
    let bankName: String?
    let status: String                      // lifecycle: "ACTIVE", "PENDING_ACTIVATION", "SUSPENDED", "EXPIRED"
    let requiresActivation: Bool
    let isActive: Bool                      // the card payments use
    let requiresOnline: Bool                // grey out + prompt to connect
    let deviceNotBound: Bool                // added on another device: grey out + "add this card again on this phone"
}

// wallet.observeTokenStatusChanged payload — branch on canPay, not on status
public struct TokenStatusChange {
    let tokenUniqueReference: String; let status: String; let rawStatus: String
    let canPay: Bool; let previousStatus: String?
}
// wallet.observeTransactionResolved payload — keyed on transactionHash, NOT on a
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
public struct BankList { let banks: [Bank]; let responseStatus: String; let responseStatusReason: String?; let message: String? }   // never PENDING
public struct TokenStatusResult { let tokenStatus: String?; let responseStatus: String; let responseStatusReason: String?; let message: String? }   // never PENDING
public struct VerifyAccountParams {   // accountHolderName and accountNumberSource optional
    var accountNumber: String; var institutionCode: String; var walletAccountID: String
    var accountHolderName: String?; var accountNumberSource: String?
}
public struct DigitiseParams {        // the first six required, the rest optional
    var accountNumber: String; var institutionCode: String; var accountHolderName: String
    var walletAccountID: String; var emailAddress: String; var recommendation: TokenizationRecommendation
    var consumerIdentifier: String?; var bvn: String?; var accountHolderAddress: String?; var mobileNumber: String?
    var clientRequestID: String?; var accountNumberSource: String?
    var deviceScore: TrustScore?; var accountScore: TrustScore?
    var recommendationReasons: [TokenizationRecommendationReason]?; var bankName: String?
}
public struct VerifyAccountResponse {
    let responseCode: String?; let message: String?
    let responseStatus: String?; let responseStatusReason: String?   // what the call did · why (branch on this)
    var isApproved: Bool
}
public struct DigitiseResult {
    let tokenUniqueReference: String?; let responseCode: String?; let message: String?
    let responseStatus: String?; let responseStatusReason: String?   // APPROVED/DECLINED/FAILED/NOT_SENT — never PENDING
    let activationMethods: [DigitiseActivationMethod]   // medium + masked contact
    let tokenStored: Bool
    var isApproved: Bool; var requiresActivation: Bool
}
public enum TokenizationRecommendation { case approve, decline, requireAdditionalAuthentication }
public enum TrustScore { case untrusted, lowTrust, moderateTrust, trusted, highlyTrusted }
public enum ActivationMedium { case maskedEmail, maskedMobilePhone }
public enum ActivationReason { case addCard, checkAccountEligibility, other }
public struct ActivationCodeResponse {
    let responseStatus: String; let responseStatusReason: String?          // on FAILED the reason is the failure code
    let tokenUniqueReference: String?; let expirationDateTime: String?; let status: String?; let message: String?
    let failureCode: ActivationFailureCode?; let failureCodeRaw: String?   // branch on failureCode, never on message
}
public struct ActivateResponse {
    let responseStatus: String; let responseStatusReason: String?          // on FAILED the reason is the failure code
    let tokenUniqueReference: String?; let status: String?; let message: String?
    let failureCode: ActivationFailureCode?; let failureCodeRaw: String?
    let attemptsRemaining: Int?                                           // code attempts left where a cap applies
    let recommendDelete: RecommendDelete?; let recommendDeleteRaw: String? // .must / .may after an exhausted cycle
}
public enum ActivationFailureCode {
    case tokenNotFound, tokenNotActivatable, activationLocked, noPendingActivation, codeExpired, codeInvalid
    case maxAttemptsExceeded, codeRequestRateLimited, invalidRequest, activationFailed
    case unknown(raw: String)
}
public enum RecommendDelete { case must, may, unknown(raw: String) }
public struct TokenStatusUpdateResponse {   // deactivateToken — only APPROVED removes the card locally
    let tokenUniqueReference: String?; let status: String?; let message: String?
    let responseStatus: String; let responseStatusReason: String?   // APPROVED/FAILED/PENDING
}
public struct CardSelection {               // setActiveToken — on the phone, nothing is sent
    let responseStatus: String              // APPROVED, or FAILED
    let responseStatusReason: String?       // CARD_NOT_FOUND on FAILED
    let message: String?
    var selected: Bool                      // responseStatus == "APPROVED"
}

public enum ScanInspection { case verified(VerifiedPayment); case rejected(ScanRejectionReason, detail: String?) }
public enum ScanRejectionReason { case malformed, missingSignature, unknownKey, badSignature, expired }
public struct VerifiedPayment {
    let txRef: String; let merchantID: String; let merchantName: String; let merchantCity: String?
    let amount: String                      // "5000.00"
    let amountMinorUnits: Int64; let currencyNumeric: String; let expiryEpochSeconds: Int64
    let merchantOrderID: String?            // signed into the QR; names the payment for cancelPayment; nil if none
}
public struct PaymentOutcome {
    let approved: Bool                       // derived: responseStatus == "APPROVED"; false for PENDING too
    let responseCode: String?                // "00", "51", "68"… — quote it verbatim; nil on NOT_SENT
    let responseStatus: String?              // APPROVED · DECLINED · FAILED · PENDING · RETRY · NOT_SENT — branch on this
    let responseStatusReason: String?        // stated cause: INSUFFICIENT_FUNDS, NO_RESPONSE_RECEIVED, AUTH_CANCELLED…
    let message: String?
    let merchantName: String?                // registered name from the gateway (beats the QR copy)
    let merchantLocation: String?            // "city, state" from the gateway; nil if not supplied
}
public struct PaymentQr {
    let responseStatus: String              // APPROVED (QR made) or NOT_SENT — nothing is sent either way
    let responseStatusReason: String?; let message: String?
    let tokenUniqueReference: String?
    let payload: String?                    // render as the QR; nil unless APPROVED
    let amountMinorUnits: Int64; let currencyNumeric: String?
    let expiresAtEpochMillis: Int64
    let transactionHash: String?            // match against history to reconcile exactly this QR
}

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
public struct ReceiptScan {                 // processReceipt — checked on the phone, nothing is sent
    let receipt: TransactionReceipt?        // set only on APPROVED
    let responseStatus: String              // APPROVED, or FAILED
    let responseStatusReason: String?       // INVALID_RECEIPT / RECEIPT_NOT_FROM_THIS_WALLET / RECEIPT_MISMATCH /
                                            // PAYMENT_NOT_CONFIRMED / RECEIPT_FOR_ANOTHER_TRANSACTION / SDK_INTERNAL_ERROR
    let message: String?
    var stored: Bool                        // APPROVED with a receipt
}
public struct ReconcileResult {             // reconcilePendingTransactions — a read: no status of its own
    let failureReason: String?              // set only when the reconcile itself could not run
    let message: String?
    var checked: Bool                       // failureReason == nil
}
public struct TransactionReceipt {
    /* merchantName, merchantId, merchantAddress, transactionType, transactionStatus,
       transactionTime, totalAmount, totalAmountFormatted, currency, maskedToken,
       merchantTransactionReference, cdcvmApprovedByWallet, cdcvmOutcome,
       transactionId, transactionHash */
}

// SoftPOS side:
public struct SettlementBank { let slug: String; let name: String; let institutionCode: String }
public struct SettlementBankList { let banks: [SettlementBank]; let responseStatus: String; let responseStatusReason: String?; let message: String? }   // never PENDING
public struct MerchantRegistration { /* see Merchant registration */ }
public struct MerchantRegistrationResult {
    let responseStatus: String; let responseStatusReason: String?   // APPROVED/FAILED/PENDING
    let success: Bool                       // == (responseStatus == "APPROVED")
    let merchantID: String?; let terminalID: String?; let merchantStatus: String?; let message: String?
}
public struct MerchantStatus {              // status / activate / deactivate / update
    let merchantID: String?; let status: String?
    let responseStatus: String; let responseStatusReason: String?; let message: String?
}
public struct MerchantUpdate { /* see merchant.update */ }
public struct StoredMerchant { /* full stored profile incl. backend-assigned merchantCategoryCode, terminalID, merchantStatus */ }
public enum TapPaymentEvent { case cardDetected, unsupportedTarget, cardContactLost, cardReadingComplete, sendingRequestOnline, receivingOnlineResponse, ended(outcome: TapSessionOutcome), result(TapPaymentResult) }
public struct TapPaymentResult {
    let status: String                    // the same value as responseStatus
    let responseCode: String?             // the wire literal — display, never branch; nil on NOT_SENT
    let responseStatus: String?           // APPROVED/DECLINED/FAILED/PENDING/NOT_SENT — BRANCH ON THIS
    let responseStatusReason: String?     // e.g. "INSUFFICIENT_FUNDS", "CARD_READ_FAILED" — display, never parse
    let pan: String?; let cardholderName: String?   // 5F20 display label, e.g. "AFRIGO ****1234"
    let iccDataHex: String?; let errorMessage: String?
    let sdkErrorCode: String?             // deprecated — read responseStatusReason
    let reference: String?
    let creditTransactionID: String?; let isCreditConfirmationSupported: Bool?
    let originalPayment: OriginalPayment?   // on DUPLICATE_MERCHANT_ORDER_ID only
}
public struct OriginalPayment {             // the payment already holding a reused order id
    let responseCode: String?
    let responseStatus: String?             // "APPROVED" (already paid) / "PENDING" (still being confirmed)
    let responseStatusReason: String?; let amountMinorUnits: Int64?
    let reference: String?; let transactionID: String?
}
public struct PaymentContextQR {            // createContext — txRef/expiry/kid/mpmPayload set only on APPROVED
    let txRef: String?; let expiry: String?; let kid: String?; let mpmPayload: String?
    let responseStatus: String; let responseStatusReason: String?; let message: String?
    let originalPayment: OriginalPayment?   // on DUPLICATE_MERCHANT_ORDER_ID only
}
public struct PaymentContextState { let txRef: String; let state: String; let responseCode: String?; var isSettled: Bool; var isApproved: Bool }   // contextStatus → VeyraLookup<PaymentContextState>
public struct CustomerQrInspection { let qr: ScannedCustomerQr?; let responseStatus: String; let responseStatusReason: String?; let message: String? }   // APPROVED, or FAILED / INVALID_REQUEST
public struct ScannedCustomerQr { let maskedCard: String; let amountMinorUnits: Int64; let currencyNumeric: String; let cardholderName: String? }
public struct CustomerQrChargeOutcome {
    let approved: Bool                      // responseStatus == "APPROVED" — never worked out from the code
    let responseStatus: String?; let responseStatusReason: String?   // APPROVED/DECLINED/FAILED/PENDING/NOT_SENT
    let responseCode: String?               // receipts and support only; nil on NOT_SENT
    let transactionID: String?; let reference: String
    let creditTransactionID: String?; let isCreditConfirmationSupported: Bool?
    let originalPayment: OriginalPayment?   // on DUPLICATE_MERCHANT_ORDER_ID only
}
public struct OrderPaymentStatus {          // transactions.paymentStatus(merchantOrderID:) → VeyraLookup<OrderPaymentStatus>
    let merchantOrderID: String
    let responseStatus: String              // the ORDER's: APPROVED / PENDING / DECLINED / FAILED / RETRY
    let responseStatusReason: String?       // the deciding attempt's (UNABLE_TO_LOCATE_RECORD with no attempts)
    let responseCode: String?               // the deciding attempt's ("25" with no attempts)
    let reference: String?; let transactionID: String?; let amountMinorUnits: Int64?
    let attempts: [OrderPaymentAttempt]     // newest first; empty when there are none
    let answeredBy: String                  // "DEVICE" (this phone's final record) or "GATEWAY"
}
public struct OrderPaymentAttempt { let reference: String?; let transactionID: String?; let amountMinorUnits: Int64?; let responseCode: String?; let responseStatus: String?; let responseStatusReason: String? }
public struct MerchantTransaction { let reference: String; let rail: String; let railLabel: String; let amountMinorUnits: Int64; let currencyNumeric: String?; let status: String; let responseCode: String?; let responseStatusReason: String?; let transactionTime: String?; let transactionID: String?; let merchantOrderID: String?; let maskedTokenLast4: String; let transactionHash: String?; let cardholderName: String?; let creditTransactionID: String?; let isCreditConfirmationSupported: Bool?; let creditConfirmationStatus: String? }
public struct CreditConfirmation { let creditTransactionID: String; let status: String; let amountMinorUnits: Int64?; let creditedAt: String?; let bankReference: String?; let message: String? }   // creditConfirmation → VeyraLookup<CreditConfirmation>
public struct TransactionResolution { let reference: String; let responseCode: String?; let status: String; let reason: String? }   // transactions.onTransactionResolved payload
public struct SaleCreditConfirmation { let reference: String; let creditTransactionID: String?; let status: String; let amountMinorUnits: Int64?; let bankReference: String?; let creditedAt: String? }   // transactions.onCreditConfirmation payload
public struct MerchantReceipt { let merchantName: String; let merchantAddress: String; let transactionType: String; let totalAmountMinorUnits: Int64; let totalAmountFormatted: String; let maskedToken: String; let reference: String; let transactionHash: String?; let qrPayload: String }
public struct TransactionStatus { let merchantTransactionReference: String; let merchantID: String; let amount: Int64?; let responseCode: String; let merchantStatus: String?; let transactionID: String?; let creditTransactionID: String?; let isCreditConfirmationSupported: Bool? }   // transactions.status → VeyraLookup<[TransactionStatus]>
```

---

## Complete flows

### Add a card (wallet)

```
User enters account number
        │
        ▼
  banks(accountNumber:)  ──►  user picks their bank (institutionCode)
        │                     (FAILED → show the reason, retry as is)
        ▼
  verifyAccount
        │
        ├─ FAILED / NO_NETWORK_CONNECTION … ──► fix the reason (connect…), check again
        ├─ DECLINED / other FAILED ──► show the reason (flow ends)
        │
        ▼ APPROVED
    digitise                       (never PENDING)
        │
        ├─ NOT_SENT / FAILED ──► show the reason; digitise again
        │   (NOT_SENT / CANCELLED: cancelDigitise stopped it — close add-card)
        │
        ├────────────────┬──────────────────────────┐
        ▼                ▼                          ▼
    APPROVED     APPROVE_REQUIRE_AUTH           DECLINED
        │                │                          │
        ▼                ▼                          ▼
  Card added ✓   Show activation methods       Show reason
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
        ├─ APPROVED ──► card active ✓                SDK keeps checking
        ├─ FAILED, no failureCode ──► fix the reason (connect…); retry the same code
        └─ FAILED ────► branch on failureCode (wrong code — retry, …)
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
        │                                       └─ .result → branch on responseStatus
        │
        ├─────────── Show a QR ─────────────► payments.createContext
        │                                       APPROVED → render mpmPayload; poll
        │                                       contextStatus until APPROVED / DECLINED /
        │                                       EXPIRED (onExpired blanks the code)
        │
        └────── Scan the customer's QR ─────► inspectCustomerQr (FAILED → "not a
                                                payment code", stay armed) → confirm the
                                                QR's own amount → chargeCustomerQr
                                                → branch on responseStatus
        Cancel while waiting: payments.cancelPayment(merchantOrderID:) →
                    CANCELLED → the rail ends NOT_SENT / CANCELLED, go back ·
                    TOO_LATE…ALREADY_SENT → "can no longer be cancelled", wait
        Every rail: NOT_SENT / RETRY / DECLINED / FAILED → retry with the
                    SAME merchantOrderID (fix the reason first);
                    94 (already paid / being confirmed) or PENDING → never retry
        After any settled rail:
        receipt(forReference:) → show receipt + receipt QR
        (customer scans it with their wallet's processReceipt)
        Lost the result (PENDING, app restarted)?
        transactions.paymentStatus(merchantOrderID:) → APPROVED: paid ·
        PENDING: wait · DECLINED / FAILED / RETRY: pay again, same order ID
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
                                        ├─ APPROVED ──► success screen; history row APPROVED
                                        ├─ DECLINED / FAILED ──► declined screen with the reason
                                        ├─ PENDING ──► "not confirmed yet — don't pay again";
                                        │              the SDK resolves it in history
                                        └─ NOT_SENT ──► nothing was sent; stay on confirm
                                             (CANCELLED — Cancel while paying, by the QR's
                                             merchantOrderID — goes back instead):
                                             AUTH_CANCELLED → no error · ONLINE_REQUIRED →
                                             "connect to the internet" · DEVICE_NOT_BOUND →
                                             "add this card again on this phone"
```

## Migrating from 3.0.0 — Setup

Setup takes the same arguments in the same order on iOS, Android and React Native:
`(customerID:, config:, provider:)`. Each `configure` returns its instance.

| 3.0.0 | 3.0.1 |
|---|---|
| `VeyraWallet.configure(_ config, customerID:, provider:)` | `VeyraWallet.configure(customerID:config:provider:)` → `VeyraWallet` |
| `VeyraSoftPOS.configure(_ config, customerID:, provider:)` | `VeyraSoftPOS.configure(customerID:config:provider:)` → `VeyraSoftPOS` |
| `VeyraSDK.configure(customerID:provider:softpos:wallet:)` | `VeyraSDK.configure(customerID:config: VeyraSDKConfiguration(softpos:wallet:), provider:)` → `VeyraSDK` |
| `VeyraSDK.shared.currentMode` (property) | `VeyraSDK.shared.currentMode()` |
| *(none)* | `VeyraSDK.shared.wallet` / `.softpos` — the member SDKs |

## Migrating from 3.0.0 — Wallet

3.0.1 gives every wallet operation one name and one owner on iOS, Android and React Native. The
operations moved from `VeyraWallet.shared.tokenisation` onto `VeyraWallet.shared` itself, and Swift
drops the `get` prefix the other two platforms use (`tokens()` here, `getTokens()` there). Nothing
behaves differently; only the calls change.

| 3.0.0 | 3.0.1 |
|---|---|
| `VeyraWallet.shared.tokenisation.<call>` | `VeyraWallet.shared.<call>` — every wallet operation, including `cancelDigitise` and `cancelPayment` |
| `tokenisation.verifyAccount(accountNumber:institutionCode:walletAccountID:accountHolderName:accountNumberSource:)` | `verifyAccount(VerifyAccountParams(...))` — `accountHolderName` is now optional |
| `tokenisation.digitise(accountNumber:…clientRequestID:)` | `digitise(DigitiseParams(...))` |
| `tokenisation.activeToken` (property) | `activeToken()` |
| `VeyraWallet.shared.isPaySessionOpen` (property) | `isPaySessionOpen()` |
| — | `token(_:)`, `hasActivationObserver(tokenUniqueReference:)` (new) |
| `tokenisation.lukState(tokenUniqueReference:)`, `LukState` | **Removed** — use the token's `requiresOnline` (from `tokens()` / `token(_:)`) and `observeCardKeyStateChanged` |
| `requestActivationCode(tokenUniqueReference:method:reason:)`, `ActivationMethod` | `requestActivationCode(tokenUniqueReference:medium:reason:)`, `ActivationMedium` |
| `VeyraWallet.shared.getTransactions(tokenUniqueReference:limit:)` | `transactions(tokenUniqueReference:limit:)` |
| `tokenisation.transactionHistory(tokenUniqueReference:limit:)` (deprecated) | **Removed** — `transactions(tokenUniqueReference:limit:)` (default `limit` 50, not 100) |
| `tokenisation.recentActivity(tokenUniqueReference:)`, `TokenActivity` | **Removed** — `transactions(tokenUniqueReference:limit:)` has every rail |
| `tokenisation.receipt(forTransactionHash:)` | `receiptForTransaction(_:)` |
| `tokenisation.observeTokenLifecycle(onTokenStatusChanged:)` / `stopObservingTokenLifecycle()` | `observeTokenStatusChanged(onTokenStatusChanged:)` / `stopObservingTokenStatusChanged()` |
| `tokenisation.observeCardKeyState(onKeyStateChanged:onDeviceNotBound:)` / `stopObservingCardKeyState()` | `observeCardKeyStateChanged(onKeyStateChanged:onDeviceNotBound:)` / `stopObservingCardKeyStateChanged()` |
| `observePaymentRefusals(…, onAmountExceedsCardLimit:, …)` | `observePaymentRefusals(…, onAmountExceedCardLimit:, …)` |
| `tokenisation.topUpKeysIfNeeded()` | **Removed** — the SDK tops payment keys up itself (at `configure`, when the app becomes active, every 15 minutes and before each payment). Delete the call |

## Building with React Native?

Use the official React Native SDK —
[`veyra-sdk-react-native`](https://www.npmjs.com/package/veyra-sdk-react-native) — and
its [sample app](https://github.com/Iventure-Tech/veyra-react-native-sample-app), whose
`DEVELOPER-GUIDE.md` is the canonical React Native guide. Do **not** integrate the
artifacts documented here directly from React Native: the React Native SDK wraps them
and adds the session hooks that tell the native layer which JavaScript screen is a
payment screen — something the native artifacts cannot see on their own.
