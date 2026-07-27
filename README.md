# Veyra Bank — iOS sample app

A complete working integration of the **Veyra SDK** on iOS, built against the published
Swift package exactly the way a third-party app consumes it. One app demonstrates both
sides of a contactless payment:

- **Get paid (SoftPOS merchant):** registration & profile, NFC tap acceptance, get-paid QR
  (merchant-presented), charging a customer's payment QR (consumer-presented), transaction
  history and receipt QRs.
- **Pay (wallet customer):** add card (account tokenisation), token activation, scan-to-pay,
  show-QR-to-pay, card states, transaction history and receipts.

> Tap-to-**pay** (card emulation) is not available on iOS — Apple restricts card emulation —
> so the iOS wallet pays by QR. Tap **acceptance** works on NFC-capable iPhones.

The full **[Developer Guide](DEVELOPER-GUIDE.md)** — platform requirements, install steps,
the complete public API reference with async/closure samples, and the error catalogue with
per-outcome guidance — lives in this repository.

## Prerequisites

- Xcode 15+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
- A physical iPhone running iOS 15+ — App Attest and NFC don't work on the simulator.
- **Veyra onboarding credentials**: OAuth client id/secret, payment app provider id, token
  requestor id — plus your Apple Developer Team ID. The app talks to the Veyra TEST
  environment.
- The test account details from your onboarding pack (the prefill identity in
  `VeyraBank/SampleData.swift` is a placeholder — digitisation is checked against the
  issuer's test records).

## Run it (5 minutes)

1. Clone this repository.
2. Copy the configuration template and fill in your onboarding values:

   ```bash
   cp Config/Veyra.xcconfig.example Config/Veyra.xcconfig
   # edit Config/Veyra.xcconfig
   ```

3. Optionally update `VeyraBank/SampleData.swift` with your test account details so the
   forms prefill usefully.
4. Generate the project and open it:

   ```bash
   xcodegen
   open VeyraBank.xcodeproj
   ```

5. Select your device and press Run.

The SDK resolves as a Swift package from
`https://github.com/Iventure-Tech/veyra-sdk-ios` at a pinned version — no local files,
no extra setup.

## Where things are

| Path | What it shows |
|---|---|
| `VeyraBank/VeyraBankApp.swift` | SDK configuration & initialisation (both SDKs via the combined facade), Home |
| `VeyraBank/GetPaidView.swift` | The merchant (Get paid) flow — all three acceptance rails |
| `VeyraBank/PayView.swift` + `AddCardView` / `ScanToPayView` / `ShowToPayView` | The wallet (Pay) flow |
| `VeyraBank/TransactionsView.swift` + `TransactionDetailView` | Wallet history & receipts |
| `DEVELOPER-GUIDE.md` | The full iOS developer guide |

Building for **Android**? See https://github.com/Iventure-Tech/veyra-android-sample-app.
