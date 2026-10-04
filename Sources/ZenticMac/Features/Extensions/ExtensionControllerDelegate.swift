import AppKit
import WebKit
import ZenticKit

/// What extensions ask of the browser itself: which windows are open, a new
/// tab or window, the options page, permission, and a popup shown.
///
/// Native messaging to an extension's own app is not offered: Safari routes
/// it through private plumbing to the app extension, and there is no public
/// way for another browser to do the same. WebKit answers such calls with an
/// error, which extensions are written to expect from browsers without it.
@MainActor
final class ExtensionControllerDelegate: NSObject, WKWebExtensionControllerDelegate {
    private var extensions: Extensions { .shared }

    func webExtensionController(
        _ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        extensions.windows(visibleTo: extensionContext).map(extensions.events.window(for:))
    }

    func webExtensionController(
        _ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        guard let front = Windows.shared.frontmost, !front.isPrivate || extensionContext.hasAccessToPrivateData,
            front.window?.isKeyWindow == true
        else { return nil }
        return extensions.events.window(for: front)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void
    ) {
        let isPrivate = configuration.shouldBePrivate && extensionContext.hasAccessToPrivateData
        let browser = Windows.shared.openWindow(showing: configuration.tabURLs, private: isPrivate)
        completionHandler(extensions.events.window(for: browser), nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        let parent = (configuration.parentTab as? ExtensionTab)?.tab
        let requested = (configuration.window as? ExtensionWindow)?.browser ?? parent?.browser
        guard let browser = requested ?? extensions.windows(visibleTo: extensionContext).first else {
            let browser = Windows.shared.openWindow(showing: configuration.url.map { [$0] } ?? [], private: false)
            return completionHandler(browser.allTabs.first.map(extensions.events.tab(for:)), nil)
        }
        let tab = browser.openTab(configuration.url, after: parent, select: configuration.shouldBeActive)
        if configuration.shouldBePinned { browser.pin(tab) }
        extensions.events.sync()
        completionHandler(extensions.events.tab(for: tab), nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        extensions.openOptions(of: extensionContext)
        completionHandler(nil)
    }

    // Permission

    func webExtensionController(
        _ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        let asks = permissions.sorted { $0.rawValue < $1.rawValue }.map(ExtensionPrompt.Ask.permission)
        extensions.ask(asks, from: extensionContext, in: tab) { until in
            completionHandler(until == nil ? [] : permissions, until)
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        let hosts = Set(urls.map { URLGuess.displayHost($0) }).sorted()
        extensions.ask(hosts.map(ExtensionPrompt.Ask.site), from: extensionContext, in: tab) { until in
            completionHandler(until == nil ? [] : urls, until)
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        let sites = Set(matchPatterns.map { $0.matchesAllHosts ? "every website" : SitePattern.site(of: $0.string) ?? $0.string })
        extensions.ask(sites.sorted().map(ExtensionPrompt.Ask.site), from: extensionContext, in: tab) { until in
            completionHandler(until == nil ? [] : matchPatterns, until)
        }
    }

    // Toolbar

    func webExtensionController(
        _ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action,
        forExtensionContext context: WKWebExtensionContext
    ) {
        extensions.actionDidChange()
    }

    func webExtensionController(
        _ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
        for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void
    ) {
        completionHandler(extensions.present(action, of: context))
    }
}
