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

> **Building with React Native? Do not integrate the SDK's framework directly — use the
> official React Native SDK (`veyra-sdk-react-native`) instead.** The SDK manages the
> device's payment modes automatically by following native screen lifecycle, which a
> React Native app's JavaScript navigation does not exercise — and React Native's iOS
> dependency tooling (CocoaPods autolinking) cannot consume this Swift package. The React
> Native SDK bridges screen focus into the SDK's mode management and ships the framework
> in a CocoaPods-compatible form. See
> https://github.com/Iventure-Tech/veyra-react-native-sample-app.

## Prerequisites

- Xcode 15+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
- A physical iPhone running iOS 15+ — App Attest and NFC don't work on the simulator.
- **Veyra onboarding credentials**: artifact-repository username/password (the SDK's binary
  is hosted on an authenticated server), OAuth client id/secret, payment app provider id,
  token requestor id — plus your Apple Developer Team ID. The app talks to the Veyra TEST
  environment.
- The test account details from your onboarding pack (the prefill identity in
  `VeyraBank/SampleData.swift` is a placeholder — digitisation is checked against the
  issuer's test records).

## Run it (5 minutes)

1. Clone this repository.
2. Add the Veyra repository credentials to `~/.netrc` (SwiftPM reads it when downloading
   the SDK's binary):

   ```
   machine repo.veyra.co
     login your-repo-username
     password your-repo-password
   ```

   ```bash
   chmod 600 ~/.netrc
   ```

3. Copy the configuration template and fill in your onboarding values:

   ```bash
   cp Config/Veyra.xcconfig.example Config/Veyra.xcconfig
   # edit Config/Veyra.xcconfig
   ```

4. Optionally update `VeyraBank/SampleData.swift` with your test account details so the
   forms prefill usefully.
5. Generate the project and open it:

   ```bash
   xcodegen
   open VeyraBank.xcodeproj
   ```

6. Select your device and press Run.

The SDK resolves as a Swift package from
`https://github.com/Iventure-Tech/veyra-sdk-ios` at a pinned version; its binary downloads
from the Veyra artifact server using your `~/.netrc` credentials — no local files.

## Where things are

| Path | What it shows |
|---|---|
| `VeyraBank/VeyraBankApp.swift` | SDK configuration & initialisation (both SDKs via the combined facade), Home |
| `VeyraBank/GetPaidView.swift` | The merchant (Get paid) flow — all three acceptance rails |
| `VeyraBank/PayView.swift` + `AddCardView` / `ScanToPayView` / `ShowToPayView` | The wallet (Pay) flow |
| `VeyraBank/TransactionsView.swift` + `TransactionDetailView` | Wallet history & receipts |
| `DEVELOPER-GUIDE.md` | The full iOS developer guide |

Building for **Android**? See https://github.com/Iventure-Tech/veyra-android-sample-app.
