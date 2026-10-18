import Foundation
import Network

/// Serves `Tests/Fixtures/Pages` over HTTP on 127.0.0.1, so the tests load real
/// pages over a real connection — with redirects, subresources and downloads
/// as WebKit sees them on the web — and never need the internet.
///
/// Shared by the integration tests and the UI tests (`project.yml` compiles
/// this file into both). `/download/<name>` answers with an attachment of that
/// name; anything else is a file from the fixtures folder. The query string is
/// ignored, so a test can make an address unique to itself.
final class FixtureServer: @unchecked Sendable {
    static let pages = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures/Pages", directoryHint: .isDirectory)

    private let listener: NWListener
    private let queue = DispatchQueue(label: "zentic.fixture-server")
    /// `http://127.0.0.1:<port>/`, set once the listener is up.
    private(set) var base: URL!

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    /// Start listening; returns once the port is known.
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // The handler runs on `queue`, one call at a time.
            nonisolated(unsafe) var resumed = false
            listener.stateUpdateHandler = { [unowned self] state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    base = URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/")!
                    continuation.resume()
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [unowned self] connection in
                connection.start(queue: queue)
                receive(on: connection, buffered: Data())
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    /// An address on this server: `url("article.html")`, `url("download/report.zip")`.
    func url(_ path: String) -> URL { URL(string: path, relativeTo: base)!.absoluteURL }

    // MARK: -

    private func receive(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [unowned self] data, _, done, error in
            var request = buffered
            if let data { request.append(data) }
            // Only GETs are served, so the headers are the whole request.
            if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                respond(to: request, on: connection)
            } else if done || error != nil {
                connection.cancel()
            } else {
                receive(on: connection, buffered: request)
            }
        }
    }

    private func respond(to request: Data, on connection: NWConnection) {
        let line = String(decoding: request.prefix { $0 != UInt8(ascii: "\r") }, as: UTF8.self)
        let target = line.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let path = String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            .removingPercentEncoding ?? ""

        let status: String
        var headers: [String: String] = [:]
        let body: Data
        if path.hasPrefix("/download/") {
            status = "200 OK"
            headers["Content-Type"] = "application/octet-stream"
            headers["Content-Disposition"] = "attachment; filename=\"\(path.dropFirst("/download/".count))\""
            body = Data(repeating: 0x5A, count: 48 * 1024)
        } else if let file = Self.file(at: path), let data = try? Data(contentsOf: file) {
            status = "200 OK"
            headers["Content-Type"] = Self.contentType(of: file)
            body = data
        } else {
            status = "404 Not Found"
            headers["Content-Type"] = "text/plain"
            body = Data("Not found".utf8)
        }
        headers["Content-Length"] = String(body.count)
        headers["Cache-Control"] = "no-store"
        headers["Connection"] = "close"
        let head = "HTTP/1.1 \(status)\r\n" + headers.map { "\($0): \($1)\r\n" }.joined() + "\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// A file inside the fixtures folder, never outside it.
    private static func file(at path: String) -> URL? {
        let name = path == "/" ? "index.html" : String(path.drop { $0 == "/" })
        let file = pages.appending(path: name).standardizedFileURL
        guard file.path.hasPrefix(pages.standardizedFileURL.path + "/") else { return nil }
        return file
    }

    private static func contentType(of file: URL) -> String {
        switch file.pathExtension {
        case "html": "text/html; charset=utf-8"
        case "css": "text/css"
        case "js": "text/javascript"
        case "json": "application/json"
        default: "application/octet-stream"
        }
    }
}
