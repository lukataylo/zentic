import AppKit
import WebKit
import ZenticKit

/// Links and files other apps hand Zentic: a link clicked in Mail, an HTML
/// file double-clicked in Finder, a `.webloc` dragged onto the Dock icon.
@MainActor
enum OpenFromElsewhere {
    private static var queued: [URL] = []
    private static let receiver = Receiver()

    /// Takes the "open URL" and "open documents" Apple Events before AppKit
    /// passes them to SwiftUI, which would open another window onto the same
    /// browser for each one — or, with a sheet up, several.
    static func install() {
        let events = NSAppleEventManager.shared()
        events.setEventHandler(
            receiver, andSelector: #selector(Receiver.openURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        events.setEventHandler(
            receiver, andSelector: #selector(Receiver.openDocuments(_:reply:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEOpenDocuments))
    }

    /// Each in a new tab of the frontmost ordinary window, in the order given,
    /// the first one shown. Never in a private window: a link from another
    /// app is not something the user chose to keep off the record.
    static func open(_ urls: [URL]) {
        let flushing = !queued.isEmpty
        queued += urls
        guard !flushing else { return }
        Task {
            // `open a b c` arrives as one Apple Event per link. Gathered into
            // one batch they keep their order, rather than each landing on
            // top of the last.
            try? await Task.sleep(for: .milliseconds(80))
            let urls = queued
            queued = []
            // Saved-link files are read to find their address: off the main thread.
            let addresses = await Task.detached(priority: .userInitiated) { urls.compactMap(IncomingURL.resolve) }.value
            guard !addresses.isEmpty else { return }
            let browser = Windows.shared.windowForLinks()
            var previous: Tab?
            for address in addresses {
                let tab = Tab(url: address)
                browser.insert(tab, after: previous, select: previous == nil)
                previous = tab
            }
            NSApp.activate()
            if let window = browser.window {
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// Apple Event handlers must be Objective-C methods on an object.
    private final class Receiver: NSObject {
        @objc func openURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
            guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
                let url = URL(string: string)
            else { return }
            MainActor.assumeIsolated { OpenFromElsewhere.open([url]) }
        }

        @objc func openDocuments(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {            guard let list = event.paramDescriptor(forKeyword: keyDirectObject) else { return }
            // One file arrives as itself rather than as a list of one.
            let items = list.numberOfItems == 0 ? [list] : (1...list.numberOfItems).compactMap(list.atIndex)
            let files = items.compactMap { $0.coerce(toDescriptorType: typeFileURL)?.fileURLValue }
            MainActor.assumeIsolated { OpenFromElsewhere.open(files) }
        }
    }
}

extension WKWebView {
    /// A web address, or a file from disk. A file is given read access to
    /// its folder, so a saved page finds the images and stylesheets beside it.
    func load(address url: URL) {
        if url.isFileURL {
            loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            load(URLRequest(url: url))
        }
    }
}
