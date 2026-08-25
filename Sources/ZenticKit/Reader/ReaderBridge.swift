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

    /// Whether the lens editor bundle has been evaluated in the document the web
    /// view is currently showing. Reset on every `ready`, which is the page
    /// telling us a new document started and took the previous one's globals with
    /// it. See ``deliverLensEditor(to:)``.
    private var lensEditorDelivered = false

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
        try loadResource(named: "zentic")
    }

    private static func loadResource(named name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "js") else {
            throw ReaderBridgeError.malformedEvent("\(name).js missing from ZenticKit resources")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - The lens editor, on demand

    /// The lens editor bundle, read once for the whole process.
    ///
    /// Every tab injects the same bytes, and most tabs never inject them at all —
    /// a `static let` is initialised lazily, so a session that never enters lens
    /// mode never touches the file.
    private static let lensEditorSource: String? = try? loadResource(named: "zentic-lens-editor")

    /// Put the lens editor into the page, if it is not already there.
    ///
    /// The editor is ~36KB that cannot run until the user presses ⌥⌘L, so it is
    /// not in the `WKUserScript` set — see `web/src/lens/deferred.ts`. Keeping it
    /// out of the document-start payload takes a third of a megabyte off every
    /// navigation in every tab, including the overwhelming majority that never
    /// open an editor. Nothing on the reveal path waits for this.
    ///
    /// Evaluated into ``contentWorld``, exactly like the main bundle: page script
    /// must not be able to see or patch our chrome, and an editor injected into
    /// the page world would be readable by the site whose page it is describing.
    ///
    /// Callers must `await` this **before** sending ``ReaderCommand/enterLensMode``.
    /// `evaluateJavaScript` resolves after the script has run, so the ordering is
    /// the await: by the time the command is sent, the factory is on the world's
    /// global. A throw means the page could not be reached at all and the caller
    /// should say so rather than send a command that will be answered with a
    /// failure.
    ///
    /// - Note: At most once per document, not once per keystroke.
    public func deliverLensEditor(to webView: WKWebView) async throws {
        if lensEditorDelivered { return }
        guard let source = Self.lensEditorSource else {
            throw ReaderBridgeError.malformedEvent(
                "zentic-lens-editor.js missing from ZenticKit resources"
            )
        }
        _ = try await webView.evaluateJavaScript(source, in: nil, contentWorld: Self.contentWorld)
        lensEditorDelivered = true
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
            // A new document is running the bundle, so whatever we evaluated into
            // the last one is gone with its realm. Cleared here rather than on
            // navigation callbacks because this is the page itself saying so, and
            // it is said on exactly the events that matter: a full load, and
            // nothing else. Believing a stale delivery would cost the user a
            // ⌥⌘L that does nothing.
            if case .ready = event { lensEditorDelivered = false }
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
