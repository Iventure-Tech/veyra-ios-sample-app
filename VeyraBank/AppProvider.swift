// The provider this app passes to configure — one for both SDKs. There is no mode to configure:
// the SDK works out how to reach Veyra from the kind of provider it is given, so switching is
// choosing which provider `provider()` returns. The values each one needs come from the git-ignored
// Config/Veyra.xcconfig (copy Config/Veyra.xcconfig.example; the build injects them into Info.plist).
import Foundation
import VeyraWallet

enum AppProvider {
    private static func value(_ key: String) -> String {
        let raw = (Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.hasPrefix("your-") ? "" : raw // an untouched template value counts as unset
    }

    /// The signed-in user's bank session: logs in to your bank with the user's username and
    /// password (password grant at `{VEYRA_BANK_BACKEND_BASE_URL}/oauth2/token`) and caches the
    /// token. This sample reads the credentials from Config/Veyra.xcconfig; a real app takes them
    /// from its login screen and never stores the password.
    static let bankSession = BankSession(
        baseURL: bankBackend(),
        bankClientId: required("VeyraBankClientID", "VEYRA_BANK_CLIENT_ID"),
        bankClientSecret: required("VeyraBankClientSecret", "VEYRA_BANK_CLIENT_SECRET"),
        username: value("VeyraUsername"),
        password: value("VeyraPassword")
    )

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

    /// Your Veyra client id (the only value the SDK receives), and your bank's own client at the
    /// authorization server that exchanges the user's session for the assertion.
    static func assertionProvider() -> any VeyraProvider {
        BankBackendAssertionProvider(
            clientId: value("VeyraClientID"),
            bankClientId: required("VeyraBankClientID", "VEYRA_BANK_CLIENT_ID"),
            bankClientSecret: required("VeyraBankClientSecret", "VEYRA_BANK_CLIENT_SECRET"),
            baseURL: bankBackend(),
            session: { try await bankSession.token() }
        )
    }

    /// Your bank's gateway, which relays the SDK's calls — no Veyra client id or secret in the app.
    static func proxyProvider() -> any VeyraProvider {
        BankBackendRelay(baseURL: bankBackend(), session: { try await bankSession.token() })
    }

    /// Deprecated, testing only: just the client id and secret.
    @available(*, deprecated, message: "The client-secret provider is deprecated: return assertionProvider() or proxyProvider().")
    static func clientSecretProvider() -> any VeyraProvider {
        ClientSecretCredentials(clientId: value("VeyraClientID"), clientSecret: value("VeyraClientSecret"))
    }

    private static func required(_ key: String, _ name: String) -> String {
        let v = value(key)
        guard !v.isEmpty else { fatalError("\(name) must be set in Config/Veyra.xcconfig for this provider") }
        return v
    }

    private static func bankBackend() -> URL {
        guard let url = URL(string: value("VeyraBankBackendBaseURL")), !value("VeyraBankBackendBaseURL").isEmpty else {
            fatalError("VEYRA_BANK_BACKEND_BASE_URL must be set in Config/Veyra.xcconfig for this provider")
        }
        return url
    }
}

/// The assertion provider: exchange the signed-in user's bank session for a short-lived assertion at
/// **your authorization server's token endpoint** (`POST {base}/oauth2/token`), using OAuth 2.0
/// Token Exchange (RFC 8693). See the integration guide for the minimum claims — `iss`, `sub`,
/// `aud` equal to the `audience` the SDK passes here, `iat`, `exp` ≤ 5 min and a unique `jti`.
///
/// Request (form-encoded; your bank's client authenticated with HTTP Basic
/// `bankClientId:bankClientSecret`): `grant_type=urn:ietf:params:oauth:grant-type:token-exchange`,
/// `subject_token=<bank session>`, `subject_token_type=…:token-type:access_token`,
/// `requested_token_type=…:token-type:jwt`, `audience=<Veyra API base URL>`. Response:
/// `{"access_token": "<compact JWT>", …}`. Returns nil when no user is signed in, or the server
/// refuses the session (401); any other failure throws.
struct BankBackendAssertionProvider: VeyraAssertionProvider {
    static let grantTokenExchange = "urn:ietf:params:oauth:grant-type:token-exchange"
    static let tokenTypeAccessToken = "urn:ietf:params:oauth:token-type:access_token"
    static let tokenTypeJWT = "urn:ietf:params:oauth:token-type:jwt"

    /// The OAuth client id Veyra issued to this app (public, not a secret). The SDK's only credential.
    let clientId: String
    /// Your bank's client at its authorization server (HTTP Basic). Never given to the SDK.
    let bankClientId: String
    /// A secret in an app can be extracted — a real app does this exchange on its own backend.
    let bankClientSecret: String
    let baseURL: URL
    let session: @Sendable () async throws -> String?
    var urlSession: URLSession = .shared

    func assertion(audience: String, jkt: String) async throws -> String? {
        guard let session = try await session(), !session.isEmpty else { return nil } // logged out
        let request = tokenExchangeRequest(session: session, audience: audience)
        let (data, response) = try await urlSession.data(for: request)
        return try Self.parse(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }

    func tokenExchangeRequest(session: String, audience: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("oauth2").appendingPathComponent("token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let basic = Data("\(bankClientId):\(bankClientSecret)".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(Self.form([
            ("grant_type", Self.grantTokenExchange),
            ("subject_token", session),
            ("subject_token_type", Self.tokenTypeAccessToken),
            ("requested_token_type", Self.tokenTypeJWT),
            ("audience", audience),
        ]).utf8)
        return request
    }

    /// `application/x-www-form-urlencoded`, every value percent-encoded (RFC 3986 unreserved kept).
    static func form(_ fields: [(String, String)]) -> String {
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-._~")
        return fields.map { name, value in
            "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value)"
        }.joined(separator: "&")
    }

    /// The exchanged token from the server's answer: nil on 401 (no session), throws otherwise.
    static func parse(status: Int, body: Data) throws -> String? {
        if status == 401 { return nil }
        guard (200..<300).contains(status) else {
            throw TokenExchangeError.refused(status: status, body: String(decoding: body, as: UTF8.self))
        }
        let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        guard let token = json?["access_token"] as? String, !token.isEmpty else {
            throw TokenExchangeError.noAccessToken
        }
        return token
    }
}

/// Why the token exchange produced no assertion.
enum TokenExchangeError: Error, CustomStringConvertible {
    case refused(status: Int, body: String)
    case noAccessToken

    var description: String {
        switch self {
        case let .refused(status, body): return "token exchange answered HTTP \(status): \(body)"
        case .noAccessToken: return "token exchange answered without an access_token"
        }
    }
}

/// The proxy provider: send every SDK call through **your bank**. The SDK's envelope — `{version,
/// service, method, path, query, headers, body}` — goes, unchanged, as the body of `POST
/// {base}/issuertokengateway/v1/proxy`: the envelope already names the method and the Veyra
/// service, so there is one entry point. Your API gateway checks the app's
/// session, removes the `/issuertokengateway/v1` context and forwards it to your ITG's `/proxy`,
/// which calls Veyra and answers with Veyra's response body — returned here unchanged. Called from
/// the SDK's background work too, so it must not depend on a screen being up.
struct BankBackendRelay: VeyraProxyProvider {
    let baseURL: URL
    let session: @Sendable () async throws -> String?

    func send(_ envelope: String) async throws -> String {
        // No bank session — signed out, or the login itself failed — means the call never left.
        let token: String
        do {
            guard let t = try await session(), !t.isEmpty else {
                throw VeyraRelayError(kind: .other, neverSent: true, message: "Not signed in to the bank")
            }
            token = t
        } catch let error as VeyraRelayError {
            throw error
        } catch {
            throw VeyraRelayError(kind: .other, neverSent: true, message: "Bank login failed: \(error)")
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("issuertokengateway").appendingPathComponent("v1").appendingPathComponent("proxy"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(envelope.utf8)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            throw Self.classify(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // A non-2xx came back from Veyra (or your gateway): the request was delivered. Your proxy's
        // own failures arrive as a 200 body the SDK recognises — returned unchanged like any other.
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

/// The deprecated client-secret provider — **for testing only**, e.g. against UAT before your
/// authorization server can issue assertions. A secret inside an app can be extracted: ship a
/// `BankBackendAssertionProvider` or `BankBackendRelay` instead.
@available(*, deprecated, message: "The client-secret provider is deprecated: return assertionProvider() or proxyProvider().")
struct ClientSecretCredentials: VeyraClientSecretProvider {
    let clientId: String
    let clientSecret: String
}

/// The signed-in user's bank session: an access token from your bank's authorization server,
/// obtained by logging the user in with their username and password (OAuth 2.0 password grant).
/// Both providers use it — the assertion provider as the token exchange's `subject_token`, the
/// proxy provider as the `Authorization: Bearer` on every relayed call.
///
/// Request: `POST {base}/oauth2/token`, your bank's client authenticated with HTTP Basic
/// `bankClientId:bankClientSecret`, form `grant_type=password&username=…&password=…`. Response:
/// `{"access_token": "…", "expires_in": 3600, …}`. Cached until shortly before it expires. A
/// refused login (400/401) or missing credentials mean nobody is signed in (`nil`); any other
/// failure throws. An actor, so concurrent SDK calls share one login.
actor BankSession {
    private let baseURL: URL
    private let bankClientId: String
    private let bankClientSecret: String
    private let username: String
    private let password: String
    private let urlSession: URLSession
    private let now: @Sendable () -> Date
    private var cached: (token: String, expiresAt: Date)?

    /// When the server does not say, assume a short life; renew a little early.
    static let defaultLifetime: TimeInterval = 300
    static let expiryMargin: TimeInterval = 30

    init(baseURL: URL, bankClientId: String, bankClientSecret: String, username: String, password: String,
         urlSession: URLSession = .shared, now: @escaping @Sendable () -> Date = { Date() }) {
        self.baseURL = baseURL
        self.bankClientId = bankClientId
        self.bankClientSecret = bankClientSecret
        self.username = username
        self.password = password
        self.urlSession = urlSession
        self.now = now
    }

    /// The current session token, logging in when there is none (or it is about to expire).
    func token() async throws -> String? {
        if let cached, now() < cached.expiresAt { return cached.token }
        cached = nil
        guard !username.isEmpty, !password.isEmpty else { return nil }
        var request = URLRequest(url: baseURL.appendingPathComponent("oauth2").appendingPathComponent("token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let basic = Data("\(bankClientId):\(bankClientSecret)".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(BankBackendAssertionProvider.form([
            ("grant_type", "password"),
            ("username", username),
            ("password", password),
        ]).utf8)
        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 400 || status == 401 { return nil } // credentials refused: signed out
        guard (200..<300).contains(status) else { throw BankLoginError.refused(status: status) }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let token = json?["access_token"] as? String, !token.isEmpty else { throw BankLoginError.noAccessToken }
        let lifetime = (json?["expires_in"] as? NSNumber)?.doubleValue ?? Self.defaultLifetime
        cached = (token, now().addingTimeInterval(max(0, lifetime - Self.expiryMargin)))
        return token
    }

    /// Forget the session (sign-out): the next call logs in again.
    func clear() { cached = nil }
}

/// Why the bank login produced no session.
enum BankLoginError: Error, CustomStringConvertible {
    case refused(status: Int)
    case noAccessToken

    var description: String {
        switch self {
        case let .refused(status): return "bank login answered HTTP \(status)"
        case .noAccessToken: return "bank login answered without an access_token"
        }
    }
}
