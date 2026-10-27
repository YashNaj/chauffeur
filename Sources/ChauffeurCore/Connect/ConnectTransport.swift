import Foundation

/// A call to App Store Connect. The host is fixed here: the only way to build one takes a path and query.
public struct ConnectRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    static let host = "api.appstoreconnect.apple.com"
    /// Built once from a literal that cannot fail to parse.
    private static let base: URL = {
        var c = URLComponents()
        c.scheme = "https"
        c.host = host
        c.path = "/"
        return c.url ?? URL(fileURLWithPath: "/")
    }()

    public let method: Method
    public let url: URL
    /// Method and path with ids replaced by placeholders, e.g. `GET /v1/builds/{id}`. Safe to log.
    public let shape: String
    public let body: Data?
    let token: String

    init(method: Method, pathAndQuery: String, shape: String, token: String, body: Data?) {
        self.method = method
        // Scheme and host are set on the components, never concatenated, so the path cannot move the request.
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.host
        let split = pathAndQuery.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(split.first ?? "")
        components.path = path.hasPrefix("/") ? path : "/" + path
        // URLComponents traps on the literal brackets of filter[...] keys, so the query is appended to the URL it
        // built (Foundation writes them as %5B/%5D). The host is already fixed by then, and a query cannot move it.
        let hostURL = components.url ?? Self.base
        self.url =
            split.count == 2 ? URL(string: hostURL.absoluteString + "?" + split[1]) ?? hostURL : hostURL
        self.shape = shape
        self.token = token
        self.body = body
    }

    public var description: String { shape }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }

    /// What the transport sends. Never logged: it carries the token.
    public var headers: [String: String] {
        var h = ["Authorization": "Bearer \(token)", "Accept": "application/json"]
        if body != nil { h["Content-Type"] = "application/json" }
        return h
    }
}

public struct ConnectResponse: Equatable, Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public struct RateLimit: Equatable, Sendable {
    public var limit: Int
    public var remaining: Int

    /// `user-hour-lim:3600;user-hour-rem:3599`, in either order.
    public static func parse(_ header: String?) -> RateLimit? {
        guard let header else { return nil }
        var limit: Int?
        var remaining: Int?
        for part in header.split(separator: ";") {
            let pair = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, let value = Int(pair[1]) else { continue }
            if pair[0] == "user-hour-lim" { limit = value } else if pair[0] == "user-hour-rem" { remaining = value }
        }
        guard let limit, let remaining else { return nil }
        return RateLimit(limit: limit, remaining: remaining)
    }
}

public protocol ConnectTransport: Sendable {
    func perform(_ request: ConnectRequest) throws -> ConnectResponse
}

// The semaphore orders the completion handler's write before the waiting thread's read; nothing reads after a timeout.
private final class ConnectOutcome: @unchecked Sendable {
    var result: Result<ConnectResponse, ConnectError> = .failure(.transport("no HTTP response"))
}

/// Hands a 3xx back as the response instead of following it.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// The real transport. Synchronous, like `Shell.run`: the CLI process has nothing else to do while it waits.
public struct URLSessionTransport: ConnectTransport {
    public let timeout: TimeInterval

    /// Ephemeral: no cache and no cookies on disk. Redirects are refused: following a 3xx to its `Location` is the
    /// one way a request, bearer token and all, could reach a host other than `ConnectRequest.host`, so a 3xx comes
    /// back as an ordinary response and surfaces as `ConnectError.apple`. No test covers this: it needs a network.
    private static let session = URLSession(
        configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)

    public init(timeout: TimeInterval = 30) { self.timeout = timeout }

    public func perform(_ request: ConnectRequest) throws -> ConnectResponse {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: timeout)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        let done = DispatchSemaphore(value: 0)
        let outcome = ConnectOutcome()
        let task = Self.session.dataTask(with: urlRequest) { data, response, error in
            defer { done.signal() }
            if let error {
                outcome.result = .failure(
                    .transport((error as? URLError)?.localizedDescription ?? error.localizedDescription))
            } else if let http = response as? HTTPURLResponse {
                var headers: [String: String] = [:]
                for (k, v) in http.allHeaderFields { headers["\(k)"] = "\(v)" }
                outcome.result = .success(
                    ConnectResponse(status: http.statusCode, headers: headers, body: data ?? Data()))
            }
        }
        task.resume()
        if done.wait(timeout: .now() + timeout + 5) == .timedOut {
            task.cancel()
            throw ConnectError.transport("timed out")
        }
        return try outcome.result.get()
    }
}
