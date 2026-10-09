// How this app connects both SDKs to Veyra, read from the git-ignored Config/Veyra.xcconfig
// (copy Config/Veyra.xcconfig.example and fill it in; the build injects the values into
// Info.plist). The connection mode is the app's own decision, so there is no default: an unset or
// unknown mode stops the app at launch, naming what to set. Both SDKs use the same mode here for
// simplicity; a real app may choose per SDK.
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

    /// The connection for either SDK.
    static func connection() -> VeyraConnection {
        switch value("VeyraConnectionMode") {
        case "directWithClientSecret":
            return deprecatedClientSecret(clientId: value("VeyraClientID"), clientSecret: value("VeyraClientSecret"))
        case "directWithAssertion":
            let provider = BankBackendAssertionProvider(baseURL: bankBackend(), session: { bankSession })
            return .directWithAssertion(clientId: value("VeyraClientID"), assertionProvider: { jkt, audience in
                try await provider.assertion(jkt: jkt, audience: audience)
            })
        case "viaAppBackend":
            return .viaAppBackend(relay: BankBackendRelay(baseURL: bankBackend(), session: { bankSession }))
        case let mode:
            fatalError("VEYRA_CONNECTION_MODE is not set (got \"\(mode)\"). Copy Config/Veyra.xcconfig.example to "
                + "Config/Veyra.xcconfig, choose directWithClientSecret, directWithAssertion or viaAppBackend, "
                + "then re-run xcodegen.")
        }
    }

    @available(*, deprecated, message: "directWithClientSecret is deprecated: move to directWithAssertion or viaAppBackend.")
    private static func deprecatedClientSecret(clientId: String, clientSecret: String) -> VeyraConnection {
        .directWithClientSecret(clientId: clientId, clientSecret: clientSecret)
    }

    private static func bankBackend() -> URL {
        guard let url = URL(string: value("VeyraBankBackendBaseURL")), !value("VeyraBankBackendBaseURL").isEmpty else {
            fatalError("VEYRA_BANK_BACKEND_BASE_URL must be set in Config/Veyra.xcconfig for this connection mode")
        }
        return url
    }
}

/// `directWithAssertion`: fetch a short-lived assertion for the signed-in user from **your bank
/// backend's endpoint** (`POST {base}/sdk-assertion`). See the integration guide for the minimum
/// claims — `iss`, `sub`, `aud` equal to the `audience` the SDK passes here, `iat`, `exp` ≤ 5 min
/// and a unique `jti` — plus the optional `cnf.jkt` (the `jkt` the SDK passes here) and `acr`. Request
/// `{"jkt": …, "audience": …}` with your app's session; response
/// `{"assertion": "<compact JWT>"}`. Returns nil when no user is signed in (401).
struct BankBackendAssertionProvider: Sendable {
    let baseURL: URL
    let session: @Sendable () -> String?

    func assertion(jkt: String, audience: String) async throws -> String? {
        guard let session = session() else { return nil } // logged out
        var request = URLRequest(url: baseURL.appendingPathComponent("sdk-assertion"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(session)", forHTTPHeaderField: "Authorization") // your bank session
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jkt": jkt, "audience": audience])
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

/// `viaAppBackend`: send every SDK call through **your bank backend**. The SDK's envelope goes,
/// unchanged, as the body of `POST {base}/veyra-relay/{method}`; your backend authenticates to
/// Veyra with its own client-credentials token, forwards path/query/headers/body to the Veyra API
/// unmodified, and answers with Veyra's response body — returned here unchanged. Called from the
/// SDK's background work too, so it must not depend on a screen being up.
struct BankBackendRelay: VeyraBackendRelay {
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
