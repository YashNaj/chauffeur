import Foundation

/// Sends the operations in `RequestTable` and nothing else. One per command; not shared across threads.
public final class ConnectClient {
    private let key: ConnectKey
    private let role: ConnectRole
    private let transport: ConnectTransport
    private let now: () -> Date

    /// The last `X-Rate-Limit` App Store Connect sent, if any.
    public private(set) var rateLimit: RateLimit?
    /// One line per request: shape, status and milliseconds. Never a token, a header or an id.
    public private(set) var log: [String] = []

    public init(key: ConnectKey, role: ConnectRole, transport: ConnectTransport, now: @escaping () -> Date = Date.init)
    {
        self.key = key
        self.role = role
        self.transport = transport
        self.now = now
    }

    private static func row(_ op: Operation) throws -> RequestRow {
        guard let row = RequestTable.rows[op.kind] else { throw ConnectError.transport("no request for \(op.kind)") }
        return row
    }

    private static func shape(_ row: RequestRow) -> String { "\(row.method.rawValue) \(row.path)" }

    private static func shape(_ op: Operation) -> String { RequestTable.rows[op.kind].map(shape) ?? "\(op.kind)" }

    /// The request for `op`, with a token scoped to that one call and valid for two minutes.
    public func request(for op: Operation, now: Date) throws -> ConnectRequest {
        let row = try Self.row(op)
        let pathAndQuery = RequestTable.pathAndQuery(for: op)
        let token = try ConnectToken.mint(
            key, lifetime: .call, scope: ["\(row.method.rawValue) \(pathAndQuery)"], now: now)
        return ConnectRequest(
            method: row.method, pathAndQuery: pathAndQuery, shape: Self.shape(row), token: token, body: nil)
    }

    /// Sends `op` and returns whatever came back. Throws only `ConnectError.transport`.
    public func perform(_ op: Operation) throws -> ConnectResponse {
        let request: ConnectRequest
        do {
            request = try self.request(for: op, now: now())
        } catch let error as ConnectError {
            if case .transport = error { throw error }
            throw ConnectError.transport("could not sign the request: \(error.description)")
        } catch {
            throw ConnectError.transport("could not sign the request")
        }
        let clock = ContinuousClock()
        let start = clock.now
        let response: ConnectResponse
        do {
            response = try transport.perform(request)
        } catch let error as ConnectError {
            throw error
        } catch {
            throw ConnectError.transport("\(type(of: error))")
        }
        let elapsed = start.duration(to: clock.now)
        let ms = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
        log.append("\(request.shape) \(response.status) \(ms)ms")
        if let limit = RateLimit.parse(response.header("X-Rate-Limit")) { rateLimit = limit }
        return response
    }

    /// What `response` means for `op`: nil for 2xx, otherwise the error to report.
    public func error(for response: ConnectResponse, op: Operation) -> ConnectError? {
        let status = response.status
        if (200..<300).contains(status) { return nil }
        let shape = Self.shape(op)
        switch status {
        case 401: return .unauthorized
        case 403:
            // A key whose role covers the row was refused for a reason only Apple knows: pass Apple's reason on.
            let needs = RequestTable.rows[op.kind]?.role ?? .developer
            if role.satisfies(needs) {
                return .apple(status: 403, shape: shape, errors: AppleError.parse(response.body))
            }
            return .forbidden(shape: shape, needs: needs, have: role)
        case 409: return .conflict(shape: shape, errors: AppleError.parse(response.body))
        case 429: return .rateLimited(remaining: rateLimit?.remaining ?? 0)
        default: return .apple(status: status, shape: shape, errors: AppleError.parse(response.body))
        }
    }

    /// Sends `op` and returns its body, or throws what the status means.
    public func send(_ op: Operation) throws -> JSON {
        let response = try perform(op)
        if let error = error(for: response, op: op) { throw error }
        do {
            return try JSON.parse(response.body)
        } catch {
            throw ConnectError.unexpectedBody(shape: Self.shape(op))
        }
    }

    /// Throws when the last known rate limit leaves fewer than `n` requests this hour.
    public func ensure(requests n: Int) throws {
        if let rateLimit, rateLimit.remaining < n { throw ConnectError.rateLimited(remaining: rateLimit.remaining) }
    }
}
