import Foundation
import OSLog
import WebKit

public protocol ReaderBridgeDelegate: AnyObject, Sendable {
    @MainActor func readerBridge(_ bridge: ReaderBridge, didReceive event: ReaderEvent)
    @MainActor func readerBridge(_ bridge: ReaderBridge, didFailWith error: any Error)
}

/// Owns the JavaScript side of one web view: script injection, configuration
/// bootstrap, and the message channel in both directions.
///
/// One bridge per tab. Recipes and reader mode are per-page state and they are
/// delivered through `WKUserScript`, which belongs to a
/// `WKUserContentController`, which belongs to a `WKWebViewConfiguration` — so
/// tabs cannot share a configuration without also sharing reader state.
///
/// ## Isolated content world
///
/// Everything runs in a named `WKContentWorld` rather than the page's world.
/// This is a correctness requirement, not hardening for its own sake: in the
/// page world, site JavaScript could replace `window.webkit.messageHandlers` and
/// forge events, patch `document.querySelectorAll` out from under extraction, or
/// simply enumerate our internals. Isolated worlds still get full DOM access,
/// which is all extraction needs, while page script cannot see or reach us.
@MainActor
public final class ReaderBridge {
    public static let messageHandlerName = "zentic"
    public static let contentWorldName = "zentic"

    /// The world our scripts and message handler live in.
    public static let contentWorld = WKContentWorld.world(name: contentWorldName)

    public weak var delegate: (any ReaderBridgeDelegate)?

    private let contentController: WKUserContentController
    private let encoder = ZenticCoding.makeEncoder()
    private let decoder = ZenticCoding.makeDecoder()
    private let logger = Logger(subsystem: "app.zentic.kit", category: "ReaderBridge")
    private var configuration: ReaderConfiguration
    private let bundleSource: String

    /// - Parameters:
    ///   - contentController: The web view's content controller. Taken over by
    ///     this bridge — the caller should not add its own scripts under
    ///     ``contentWorld``.
    ///   - configuration: Initial reader configuration.
    public init(
        contentController: WKUserContentController,
        configuration: ReaderConfiguration = ReaderConfiguration()
    ) throws {
        self.contentController = contentController
        self.configuration = configuration
        self.bundleSource = try Self.loadBundleSource()

        // A proxy breaks the retain cycle: WKUserContentController holds its
        // message handlers strongly, so registering `self` directly would keep
        // every closed tab's bridge alive for the life of the content controller.
        let proxy = WeakMessageHandlerProxy()
        proxy.bridge = self
        contentController.add(proxy, contentWorld: Self.contentWorld, name: Self.messageHandlerName)

        installUserScripts()
    }

    // MARK: - Configuration

    /// Replace the bootstrap configuration.
    ///
    /// Takes effect on the **next** navigation. `WKUserScript`s are snapshotted
    /// into a document when it starts loading, so changing configuration cannot
    /// retroactively affect the current page — use ``send(_:to:)`` for that.
    public func updateConfiguration(_ configuration: ReaderConfiguration) {
        self.configuration = configuration
        installUserScripts()
    }

    public var currentConfiguration: ReaderConfiguration { configuration }

    private func installUserScripts() {
        // No API exists to remove one script, so the set is rebuilt wholesale.
        // Safe because this bridge owns every script in its world.
        contentController.removeAllUserScripts()

        for source in [bootstrapSource(), bundleSource] {
            contentController.addUserScript(
                WKUserScript(
                    source: source,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true,
                    in: Self.contentWorld
                )
            )
        }
    }

    /// Defines `globalThis.__zenticConfig` ahead of the bundle.
    ///
    /// This must run at `atDocumentStart` and before the bundle, because the
    /// bundle's first act is deciding whether to hide the document — a decision
    /// that needs the recipe and the pass-through list already in hand. Anything
    /// delivered asynchronously arrives after first paint, which is exactly the
    /// flash the pipeline exists to avoid.
    private func bootstrapSource() -> String {
        guard let json = try? encoder.encode(configuration),
              let text = String(data: json, encoding: .utf8)
        else {
            logger.error("Failed to encode reader configuration; bundle will use defaults")
            return "globalThis.__zenticConfig = null;"
        }
        return "globalThis.__zenticConfig = \(text);"
    }

    private static func loadBundleSource() throws -> String {
        guard let url = Bundle.module.url(forResource: "zentic", withExtension: "js") else {
            throw ReaderBridgeError.malformedEvent("zentic.js missing from ZenticKit resources")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Outbound

    /// Send a command to the page.
    ///
    /// Throws if the page has no bundle running (for instance a `pdf` or an error
    /// page), which callers should treat as benign.
    public func send(_ command: ReaderCommand, to webView: WKWebView) async throws {
        let json = try encoder.encode(command)
        guard let text = String(data: json, encoding: .utf8) else {
            throw ReaderBridgeError.malformedEvent("command was not valid UTF-8")
        }

        // The command is passed as an argument rather than interpolated into the
        // script body: interpolating JSON into source is how you get a syntax
        // error from an apostrophe in a rewritten paragraph.
        _ = try await webView.callAsyncJavaScript(
            "await globalThis.__zentic?.receive(command);",
            arguments: ["command": text],
            contentWorld: Self.contentWorld
        )
    }

    // MARK: - Inbound

    fileprivate func handle(message: WKScriptMessage) {
        guard message.name == Self.messageHandlerName else {
            delegate?.readerBridge(self, didFailWith: ReaderBridgeError.unknownHandler(message.name))
            return
        }

        guard let text = message.body as? String, let data = text.data(using: .utf8) else {
            delegate?.readerBridge(
                self,
                didFailWith: ReaderBridgeError.malformedEvent("expected a JSON string body")
            )
            return
        }

        do {
            let event = try decoder.decode(ReaderEvent.self, from: data)
            delegate?.readerBridge(self, didReceive: event)
        } catch {
            logger.error("Undecodable reader event: \(error, privacy: .public)")
            delegate?.readerBridge(self, didFailWith: error)
        }
    }
}

/// Weakly forwards script messages, so a content controller does not keep a
/// bridge (and therefore a tab) alive.
@MainActor
private final class WeakMessageHandlerProxy: NSObject, WKScriptMessageHandler {
    weak var bridge: ReaderBridge?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        bridge?.handle(message: message)
    }
}
