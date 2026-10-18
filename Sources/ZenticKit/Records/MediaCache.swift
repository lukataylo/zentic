import CryptoKit
import Foundation

/// Images captured records refer to, fetched once and served locally.
///
/// Generated apps run with no network at all (see ``AppSandbox``). An avatar URL
/// handed to one would either be blocked — a broken image — or, if images were
/// allowed through, be a request to the source's CDN on every render of every
/// app. So the library fetches each image once, at capture time, cookie-less,
/// from hosts ``MediaPolicy`` allows — and apps only ever see
/// `zentic://<app>/media/<hash>`. An app's requests never cause a fetch.
public actor MediaCache {
    private let directory: URL
    private let session: URLSession
    private var inFlight: Set<String> = []

    public static var defaultDirectory: URL {
        DataDirectory.root.appending(path: "Media", directoryHint: .isDirectory)
    }

    public init(directory: URL = MediaCache.defaultDirectory) {
        self.directory = directory
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.timeoutIntervalForRequest = 15
        configuration.networkServiceType = .background
        session = URLSession(configuration: configuration)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The cache key for a remote URL: hex SHA-256, so it is path-safe by
    /// construction and the scheme handler can validate it with a regex.
    public nonisolated static func key(for url: String) -> String {
        SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public nonisolated static func isValidKey(_ key: String) -> Bool {
        key.count == 64 && key.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// Keys already on disk, out of `urls`.
    public func cachedKeys(for urls: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for url in urls {
            let key = Self.key(for: url)
            if FileManager.default.fileExists(atPath: file(key).path(percentEncoded: false)) {
                out[url] = key
            }
        }
        return out
    }

    /// The image and its media type, for the scheme handler.
    public func image(forKey key: String) -> (data: Data, mimeType: String)? {
        guard Self.isValidKey(key),
            let data = try? Data(contentsOf: file(key)),
            let mime = try? String(contentsOf: file(key).appendingPathExtension("type"), encoding: .utf8)
        else { return nil }
        return (data, mime)
    }

    /// Fetch whatever is missing. Returns how many images are newly cached, so the
    /// caller knows whether apps have anything new to show.
    @discardableResult
    public func fetch(_ urls: [String]) async -> Int {
        var fetched = 0
        await withTaskGroup(of: Bool.self) { group in
            for url in urls {
                let key = Self.key(for: url)
                guard !inFlight.contains(key),
                    !FileManager.default.fileExists(atPath: file(key).path(percentEncoded: false)),
                    let remote = URL(string: url), remote.scheme == "https"
                else { continue }
                inFlight.insert(key)
                group.addTask { [session] in
                    let result = await Self.download(remote, using: session)
                    return await self.finish(key: key, result: result)
                }
            }
            for await stored in group where stored { fetched += 1 }
        }
        return fetched
    }

    /// Clears the in-flight mark whatever happened, so a failed download is
    /// retried the next time the image is captured rather than never.
    private func finish(key: String, result: (data: Data, mimeType: String)?) -> Bool {
        defer { inFlight.remove(key) }
        guard let (data, mimeType) = result else { return false }
        do {
            try data.write(to: file(key), options: .atomic)
            try mimeType.write(to: file(key).appendingPathExtension("type"), atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// Streamed with a byte cap, so a hostile or broken server cannot make the
    /// cache hold a multi-gigabyte body in memory before the size check runs.
    private static func download(_ url: URL, using session: URLSession) async -> (data: Data, mimeType: String)? {
        guard let (bytes, response) = try? await session.bytes(from: url),
            let http = response as? HTTPURLResponse, http.statusCode == 200,
            let mime = http.mimeType?.lowercased(), mime.hasPrefix("image/"),
            // SVG is a document that can carry script and its own external loads.
            mime != "image/svg+xml",
            http.expectedContentLength <= Int64(LibraryBudget.maxCachedImageBytes)
        else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > LibraryBudget.maxCachedImageBytes { return nil }
            }
        } catch {
            return nil
        }
        return data.isEmpty ? nil : (data, mime)
    }

    private func file(_ key: String) -> URL {
        directory.appending(path: key)
    }
}
