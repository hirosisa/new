import Foundation

/// Small shared networking helper.
///
/// Everything goes through one `URLSession` with explicit timeouts, and every
/// response is status-checked before decoding. The previous implementation
/// decoded whatever came back, so an HTML anti-bot page or an error body
/// surfaced as an opaque `DecodingError`.
actor HTTPClient {

    static let shared = HTTPClient()

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 45
        config.waitsForConnectivity = true
        config.requestCachePolicy = .reloadRevalidatingCacheData
        config.httpAdditionalHeaders = [
            "Accept-Encoding": "gzip, deflate"
        ]
        self.session = URLSession(configuration: config)
    }

    func data(from url: URL, accept: String? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let accept {
            request.setValue(accept, forHTTPHeaderField: "Accept")
        }

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw SourceError.transport("Malformed server response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw SourceError.http(status: http.statusCode, host: url.host ?? "server")
        }

        // A JSON endpoint answering with HTML means we hit a login wall, a
        // captcha, or an anti-bot interstitial. Detect it here rather than
        // letting JSONDecoder report a confusing type mismatch.
        if let accept, accept.contains("json"),
           let contentType = http.value(forHTTPHeaderField: "Content-Type"),
           contentType.lowercased().contains("text/html") {
            throw SourceError.blocked(host: url.host ?? "server")
        }

        return data
    }

    func json<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        let data = try await data(from: url, accept: "application/json")
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw SourceError.decoding(String(describing: error))
        }
    }

    /// POSTs a JSON body and returns the raw response.
    ///
    /// The User-Agent is a required parameter rather than a default, because
    /// InnerTube decides which client it thinks it's talking to partly from this
    /// header — sending the wrong one alongside an iOS client context gets the
    /// request rejected.
    func postJSON(url: URL, body: Data, userAgent: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw SourceError.transport("Malformed server response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw SourceError.http(status: http.statusCode, host: url.host ?? "server")
        }

        if let contentType = http.value(forHTTPHeaderField: "Content-Type"),
           contentType.lowercased().contains("text/html") {
            throw SourceError.blocked(host: url.host ?? "server")
        }

        return data
    }

    /// iOS reports a normal-looking UA; some CDNs reject empty or exotic ones.
    private static let userAgent =
        "MediaPlayerApp/1.0 (iOS; +personal-use)"
}

// MARK: - Errors

enum SourceError: LocalizedError, Equatable {
    case http(status: Int, host: String)
    case blocked(host: String)
    case transport(String)
    case decoding(String)
    case noStream(String)
    case notConfigured(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case let .http(status, host):
            return "\(host) returned HTTP \(status)."
        case let .blocked(host):
            return "\(host) is behind a bot check and can't be used from an app."
        case let .transport(message):
            return message
        case .decoding:
            return "The server sent data in an unexpected format."
        case let .noStream(title):
            return "No playable stream found for “\(title)”."
        case let .notConfigured(message):
            return message
        case .cancelled:
            return nil
        }
    }
}
