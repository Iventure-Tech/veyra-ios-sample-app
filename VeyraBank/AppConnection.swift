// The provider this app passes to configure — one for both SDKs. There is no mode to configure:
// the SDK works out how to reach Veyra from the kind of provider it is given, so switching is
// choosing which provider `provider()` returns. The values each one needs come from the git-ignored
// Config/Veyra.xcconfig (copy Config/Veyra.xcconfig.example; the build injects them into Info.plist).
import Foundation
import VeyraWallet

enum AppConnection {
    private static func value(_ key: String) -> String {
        let raw = (Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.hasPrefix("your-") ? "" : raw // an untouched template value counts as unset
    }

    /// Stands in for your bank app's own logged-in session when calling your backend.
    static var bankSession: String? { value("VeyraBankSessionToken").isEmpty ? nil : value("VeyraBankSessionToken") }

    /// The provider for both SDKs. There is no mode: the SDK works out how to reach Veyra from
    /// the kind of provider it is given, so switching is returning a different one here.
    ///
    /// Return ONE of the three. The sample ships with the client-secret provider so it runs with
    /// just your onboarding client id and secret — **for testing only**; a real app returns
    /// `assertionProvider()` or `proxyProvider()`.
    static func provider() -> any VeyraProvider {
        clientSecretProvider()
        // assertionProvider()
        // proxyProvider()
    }

    /// Your client id, and the bank backend that signs the assertion.
    static func assertionProvider() -> any VeyraProvider {
        BankBackendAssertionProvider(clientId: value("VeyraClientID"), baseURL: bankBackend(), session: { bankSession })
    }

    /// Only the bank backend that relays the SDK's calls — no client id, no secret.
    static func proxyProvider() -> any VeyraProvider {
        BankBackendRelay(baseURL: bankBackend(), session: { bankSession })
    }

    /// Deprecated, testing only: just the client id and secret.
    @available(*, deprecated, message: "The client-secret provider is deprecated: return assertionProvider() or proxyProvider().")
    static func clientSecretProvider() -> any VeyraProvider {
        ClientSecretCredentials(clientId: value("VeyraClientID"), clientSecret: value("VeyraClientSecret"))
    }

    private static func bankBackend() -> URL {
        guard let url = URL(string: value("VeyraBankBackendBaseURL")), !value("VeyraBankBackendBaseURL").isEmpty else {
            fatalError("VEYRA_BANK_BACKEND_BASE_URL must be set in Config/Veyra.xcconfig for this provider")
        }
        return url
    }
}

/// The assertion provider: fetch a short-lived assertion for the signed-in user from **your bank
/// backend's endpoint** (`POST {base}/sdk-assertion`). See the integration guide for the minimum
/// claims — `iss`, `sub`, `aud` equal to the `audience` the SDK passes here, `iat`, `exp` ≤ 5 min
/// and a unique `jti` — plus the optional `cnf.jkt` (the `jkt` the SDK passes here) and `acr`. Request
/// `{"audience": …, "jkt": …}` with your app's session; response
/// `{"assertion": "<compact JWT>"}`. Returns nil when no user is signed in (401).
struct BankBackendAssertionProvider: VeyraAssertionProvider {
    /// The OAuth client id Veyra issued to this app (public, not a secret).
    let clientId: String
    let baseURL: URL
    let session: @Sendable () -> String?

    func assertion(audience: String, jkt: String) async throws -> String? {
        guard let session = session() else { return nil } // logged out
        var request = URLRequest(url: baseURL.appendingPathComponent("sdk-assertion"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(session)", forHTTPHeaderField: "Authorization") // your bank session
        request.httpBody = try JSONSerialization.data(withJSONObject: ["audience": audience, "jkt": jkt])
        let (data, response) = try await URLSession.shared.data(for: request)
        return try Self.parse(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }

    /// The assertion from your backend's answer: nil on 401 (no session), throws otherwise.
    static func parse(status: Int, body: Data) throws -> String? {
        if status == 401 { return nil }
        guard (200..<300).contains(status) else { throw URLError(.badServerResponse) }
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        guard let assertion = json?["assertion"] as? String, !assertion.isEmpty else {
            throw URLError(.cannotParseResponse)
        }
        return assertion
    }
}

/// The proxy provider: send every SDK call through **your bank backend**. The SDK's envelope goes,
/// unchanged, as the body of `POST {base}/veyra-relay/{method}`; your backend authenticates to
/// Veyra with its own client-credentials token, forwards path/query/headers/body to the Veyra API
/// unmodified, and answers with Veyra's response body — returned here unchanged. Called from the
/// SDK's background work too, so it must not depend on a screen being up.
struct BankBackendRelay: VeyraProxyProvider {
    let baseURL: URL
    let session: @Sendable () -> String?

    func post(_ request: String) async throws -> String { try await forward("post", request) }
    func get(_ request: String) async throws -> String { try await forward("get", request) }
    func put(_ request: String) async throws -> String { try await forward("put", request) }
    func delete(_ request: String) async throws -> String { try await forward("delete", request) }
    func patch(_ request: String) async throws -> String { try await forward("patch", request) }

    private func forward(_ method: String, _ envelope: String) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("veyra-relay").appendingPathComponent(method))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let session = session() { request.setValue("Bearer \(session)", forHTTPHeaderField: "Authorization") }
        request.httpBody = Data(envelope.utf8)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            throw Self.classify(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Your backend relays Veyra's status: a non-2xx means the request was delivered.
        guard (200..<300).contains(status) else {
            throw VeyraRelayError(kind: .other, neverSent: false, httpStatus: status)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Only "never got onto the network" and a refused connection are provably unsent
    /// (`neverSent: true` ⇒ the payment ends failed). Anything after the request may have been
    /// written — a timeout, a lost connection — is `neverSent: false`: pending, then reconciled.
    static func classify(_ error: URLError) -> VeyraRelayError {
        switch error.code {
        case .notConnectedToInternet, .cannotFindHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
            return VeyraRelayError(kind: .noNetwork, neverSent: true, message: error.localizedDescription)
        case .cannotConnectToHost:
            return VeyraRelayError(kind: .connectionRefused, neverSent: true, message: error.localizedDescription)
        case .timedOut:
            return VeyraRelayError(kind: .timeout, neverSent: false, message: error.localizedDescription)
        default:
            return VeyraRelayError(kind: .other, neverSent: false, message: error.localizedDescription)
        }
    }
}

/// The deprecated client-secret provider — **for testing only**, e.g. against UAT before your bank
/// backend can sign assertions. A secret inside an app can be extracted: ship a
/// `BankBackendAssertionProvider` or `BankBackendRelay` instead.
@available(*, deprecated, message: "The client-secret provider is deprecated: return assertionProvider() or proxyProvider().")
struct ClientSecretCredentials: VeyraClientSecretProvider {
    let clientId: String
    let clientSecret: String
}
