import Foundation

/// A call to App Store Connect. The host is fixed here: the only way to build one takes a path and query.
public struct ConnectRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    static let host = "https://api.appstoreconnect.apple.com"

    public let method: Method
    public let url: URL
    /// Method and path with ids replaced by placeholders, e.g. `GET /v1/builds/{id}`. Safe to log.
    public let shape: String
    public let body: Data?
    let token: String

    init(method: Method, pathAndQuery: String, shape: String, token: String, body: Data?) {
        self.method = method
        // The host is a constant, so this only fails on a malformed path; fall back to the bare host.
        self.url = URL(string: Self.host + pathAndQuery) ?? URL(fileURLWithPath: "/")
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

private final class ConnectOutcome: @unchecked Sendable {
    var result: Result<ConnectResponse, ConnectError> = .failure(.transport("no HTTP response"))
}

/// The real transport. Synchronous, like `Shell.run`: the CLI process has nothing else to do while it waits.
public struct URLSessionTransport: ConnectTransport {
    public let timeout: TimeInterval

    public init(timeout: TimeInterval = 30) { self.timeout = timeout }

    public func perform(_ request: ConnectRequest) throws -> ConnectResponse {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: timeout)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        let done = DispatchSemaphore(value: 0)
        let outcome = ConnectOutcome()
        let task = URLSession.shared.dataTask(with: urlRequest) { data, response, error in
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
