import Foundation
import Testing
import WebKit

@testable import ZenticKit

/// The app-level integration tests. One parent, serialized: they share the app's
/// singletons (the data directory, the tab-state store, the blocker), and real
/// web views on the main actor are steadier one at a time.
@MainActor
@Suite(.serialized) enum AppIntegration {
    /// One server for the run, started on first use.
    static func server() async throws -> FixtureServer {
        if let running { return running }
        let server = try FixtureServer()
        try await server.start()
        running = server
        return server
    }

    private static var running: FixtureServer?
}

struct TimedOut: Error, CustomStringConvertible {
    let what: String
    var description: String { "Timed out waiting for \(what)" }
}

/// Wait for something WebKit does asynchronously. Polls a condition rather than
/// sleeping a fixed time: fast when the machine is fast, and on a slow one it
/// waits as long as it takes, up to `timeout`.
@MainActor
func eventually(
    _ what: String, timeout: Duration = .seconds(10), _ condition: () async throws -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while try await !condition() {
        guard ContinuousClock.now < deadline else { throw TimedOut(what: what) }
        try await Task.sleep(for: .milliseconds(20))
    }
}

extension WKWebView {
    /// Load and wait for the page to finish.
    @MainActor
    func loadAndWait(_ url: URL) async throws {
        load(URLRequest(url: url))
        try await waitForLoad(of: url)
    }

    @MainActor
    func waitForLoad(of url: URL? = nil) async throws {
        try await eventually("\(url?.absoluteString ?? "the page") to load") {
            guard !isLoading, self.url != nil, url.map({ self.url == $0 }) ?? true else { return false }
            return try await evaluateJavaScript("document.readyState") as? String == "complete"
        }
    }

    /// Run JavaScript in Zentic's world, as the app does.
    @MainActor
    func zentic(_ body: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        try await callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: InPageScript.world)
    }

    /// Run JavaScript in the page's own world.
    @MainActor
    func page(_ body: String) async throws -> Any? {
        try await callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page)
    }
}
