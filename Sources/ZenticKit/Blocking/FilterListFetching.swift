import Foundation

public enum FilterListFetchResult: Sendable, Hashable {
    /// Upstream confirmed our copy is current. Nothing to convert, nothing to
    /// compile — this is the case that makes a daily refresh nearly free.
    case notModified
    case updated(text: String, etag: String?)
}

/// Fetching a filter list. Injected so the test suite never touches the network.
public protocol FilterListFetching: Sendable {
    func fetch(_ source: FilterListSource, etag: String?) async throws -> FilterListFetchResult
}

public struct URLSessionFilterListFetcher: FilterListFetching {
    private let session: URLSession

    /// - Parameter session: Defaults to an ephemeral session. Deliberately not
    ///   `.shared`: URLSession's own cache would answer a conditional GET with a
    ///   cached 200, which is indistinguishable from a real update and would make
    ///   us reconvert and recompile a list that never changed.
    public init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    public func fetch(
        _ source: FilterListSource,
        etag: String?
    ) async throws -> FilterListFetchResult {
        var request = URLRequest(url: source.url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BlockerError.downloadFailed(
                list: source.id,
                message: error.localizedDescription
            )
        }

        guard let http = response as? HTTPURLResponse else {
            throw BlockerError.downloadFailed(list: source.id, message: "not an HTTP response")
        }
        if http.statusCode == 304 { return .notModified }
        guard http.statusCode == 200 else {
            throw BlockerError.downloadFailed(list: source.id, message: "HTTP \(http.statusCode)")
        }
        guard data.count <= BlockerLimits.maxListBytes else {
            throw BlockerError.downloadFailed(
                list: source.id,
                message:
                    "list is \(data.count) bytes, over the \(BlockerLimits.maxListBytes) ceiling"
            )
        }

        // Filter lists are UTF-8 by convention but a stray Latin-1 byte in a
        // comment should not lose the whole list.
        guard
            let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
        else {
            throw BlockerError.downloadFailed(list: source.id, message: "undecodable text")
        }

        return .updated(text: text, etag: http.value(forHTTPHeaderField: "ETag"))
    }
}
