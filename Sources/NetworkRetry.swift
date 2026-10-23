import Foundation
import os

/// One retry for transient connection failures, on a brand-new connection.
///
/// The usage endpoints are polled every ~5 min and URLSession reuses the previous keep-alive connection.
/// When that idle connection has silently died (VPN / NAT / proxy dropped it), the request gets no
/// response and times out after 15 s (seen 2026-10-23: `reused=1`, -1001). Retrying on the same session
/// could pick the same dead connection again, so the retry uses a one-off ephemeral session.
enum NetworkRetry {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// A one-off session with its own connection pool, invalidated after the request.
    static let freshConnection: Transport = { req in
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        return try await session.data(for: req)
    }

    /// Connection-level failures worth one immediate retry; anything else (cancelled, bad URL,
    /// a server response) is returned to the caller as is.
    static func isTransient(_ error: Error) -> Bool {
        guard let e = error as? URLError else { return false }
        switch e.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .notConnectedToInternet, .secureConnectionFailed, .resourceUnavailable, .internationalRoamingOff,
             .callIsActive, .dataNotAllowed:
            return true
        default:
            return false
        }
    }

    /// True for a URLError (no HTTP response at all), as opposed to a parsing or server error.
    static func isConnectionError(_ error: Error) -> Bool { error is URLError }

    /// e.g. "URLError -1001 (timed out)". Never includes request headers.
    static func describe(_ error: Error) -> String {
        if let e = error as? URLError { return "URLError \(e.code.rawValue) (\(e.localizedDescription))" }
        return String(describing: type(of: error))
    }

    /// Sends `request`; on a transient failure logs it and retries once with `retry`.
    static func send(_ request: URLRequest, using transport: Transport, retry: Transport,
                     log: Logger, label: String) async throws -> (Data, URLResponse) {
        do {
            return try await transport(request)
        } catch {
            log.error("\(label, privacy: .public) failed: \(describe(error), privacy: .public)")
            guard isTransient(error) else { throw error }
            do {
                let result = try await retry(request)
                log.notice("\(label, privacy: .public) succeeded on a new connection")
                return result
            } catch {
                log.error("\(label, privacy: .public) retry on a new connection failed: \(describe(error), privacy: .public)")
                throw error
            }
        }
    }
}
