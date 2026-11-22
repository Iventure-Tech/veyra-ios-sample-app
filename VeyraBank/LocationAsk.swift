import CoreLocation
import Foundation

/// Asks for location once, before the first payment or card added, with a short explanation first.
///
/// The Veyra SDKs never ask for a permission themselves: they send the phone's location with each
/// payment, card added and key refresh when the app already holds it, and report it as unavailable
/// otherwise. That evidence helps the payment's fraud checks, which isn't obvious to a user, so the app
/// explains before the system prompt. Asked once: whatever the answer, the flow carries on, and a
/// "no" is never asked again here; the user can still allow it in Settings.
@MainActor
final class LocationAsk: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationAsk()

    static let title = "Help protect your payments"
    static let message = "Veyra Bank sends your phone's location with each payment and card you add. "
        + "It helps check that each payment is really yours. You can change this at any time in Settings."

    /// True while the explanation is on screen.
    @Published var explaining = false

    private let manager = CLLocationManager()
    private var next: (() -> Void)?
    private static let askedKey = "veyra_bank_location_asked"

    /// Runs `then` at once if location was already decided or asked for; otherwise explains first.
    func beforePayment(_ then: @escaping () -> Void) {
        if manager.authorizationStatus != .notDetermined || UserDefaults.standard.bool(forKey: Self.askedKey) {
            then()
            return
        }
        next = then
        explaining = true
    }

    /// "Continue": the system prompt; the flow carries on once it is answered.
    func continueTapped() {
        UserDefaults.standard.set(true, forKey: Self.askedKey)
        manager.delegate = self
        manager.requestWhenInUseAuthorization()
    }

    /// "Not now": the flow carries on without location.
    func notNow() {
        UserDefaults.standard.set(true, forKey: Self.askedKey)
        finish()
    }

    private func finish() {
        let then = next
        next = nil
        then?()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // Called once with the current status when the delegate is set, before the user answers.
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard status != .notDetermined else { return }
            self.finish()
        }
    }
}
