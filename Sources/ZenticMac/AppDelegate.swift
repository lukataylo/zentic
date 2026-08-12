import AppKit
import ZenticKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: BrowserWindowController?
    private var store: BrowsingStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Launch.mark("didFinishLaunching")
        // Before any web view exists, so the memory diagnostic can tell our WebKit
        // processes from every other browser's.
        MemoryProbe.captureHelperBaseline()
        Blocking.warm()
        installMenuBar()

        do {
            let store = try BrowsingStore(url: try BrowsingStore.defaultStoreURL())
            self.store = store
            Launch.mark("store open")

            let controller = BrowserWindowController(store: store)
            windowController = controller
            Launch.mark("window built")
            controller.showWindow(nil)
        } catch {
            // A browser that cannot open its session store is still a browser worth
            // having, but silently starting fresh would look like data loss. Say so.
            let alert = NSAlert()
            alert.messageText = "Zentic could not open its session"
            alert.informativeText = "\(error)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        // The number that matters: a complete window the user can look at. The
        // selected tab's web view is built one run-loop turn later, so this is not
        // "window plus page" — it is deliberately the moment the chrome is up.
        Launch.mark("window on screen")

        if let count = Self.stressTabCount() {
            windowController?.browser.runStress(tabCount: count)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        windowController?.browser.persistBeforeTermination()
    }

    /// `ZenticMac --stress 30` — see `BrowserViewController.runStress(tabCount:)`.
    private static func stressTabCount() -> Int? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--stress"),
            let value = arguments[safe: index + 1].flatMap(Int.init)
        else { return nil }
        return value
    }

    // MARK: - Menu bar

    /// A SwiftPM executable has no nib, so the menu bar is assembled by hand.
    ///
    /// It is also where every keyboard shortcut lives. That is deliberate rather
    /// than incidental: menu key equivalents are dispatched before `keyDown` reaches
    /// the responder chain, so they work even while a `WKWebView` has focus — which
    /// is the whole time. Shortcuts implemented as `keyDown` handling would be eaten
    /// by the page.
    private func installMenuBar() {
        let mainMenu = NSMenu()
        mainMenu.addItem(appMenuItem())
        mainMenu.addItem(fileMenuItem())
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(viewMenuItem())
        mainMenu.addItem(historyMenuItem())
        mainMenu.addItem(tabsMenuItem())
        NSApp.mainMenu = mainMenu
    }

    private func item(
        _ title: String,
        _ action: Selector?,
        _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = .command,
        tag: Int = 0
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.tag = tag
        // Target stays nil so the action travels the responder chain and lands on
        // whichever BrowserViewController is in front.
        return item
    }

    private func appMenuItem() -> NSMenuItem {
        let menu = NSMenu()
        menu.addItem(item("About Zentic", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""))
        menu.addItem(.separator())
        menu.addItem(item("Hide Zentic", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(item("Quit Zentic", #selector(NSApplication.terminate(_:)), "q"))

        let holder = NSMenuItem()
        holder.submenu = menu
        return holder
    }

    private func fileMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "File")
        menu.addItem(item("New Tab", #selector(BrowserViewController.newTabCommand(_:)), "t"))
        menu.addItem(item("New Space", #selector(BrowserViewController.newSpaceCommand(_:)), "n", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Close Tab", #selector(BrowserViewController.closeTabCommand(_:)), "w"))
        menu.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]))

        let holder = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }

    /// Required for copy/paste inside the page and the address bar to work at all —
    /// `WKWebView` relies on the standard Edit menu's key equivalents.
    private func editMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        menu.addItem(.separator())
        menu.addItem(item("Find in Page", #selector(BrowserViewController.findCommand(_:)), "f"))
        menu.addItem(
            item("Open Address Bar", #selector(BrowserViewController.focusAddressCommand(_:)), "l")
        )
        menu.addItem(item("Command Palette", #selector(BrowserViewController.paletteCommand(_:)), "k"))

        let holder = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }

    private func viewMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "View")
        menu.addItem(item("Reload Page", #selector(BrowserViewController.reloadCommand(_:)), "r"))
        menu.addItem(
            item("Show Original Page", #selector(BrowserViewController.toggleOriginalCommand(_:)), "\\")
        )
        menu.addItem(.separator())
        menu.addItem(
            item("Simplify Page", #selector(BrowserViewController.simplifyCommand(_:)), "s", [.command, .shift])
        )
        menu.addItem(
            item("Show Original Text", #selector(BrowserViewController.discardRewriteCommand(_:)), "")
        )
        menu.addItem(.separator())
        menu.addItem(
            item("Toggle Sidebar", #selector(BrowserViewController.toggleSidebarCommand(_:)), "s", [.command, .option])
        )
        menu.addItem(
            item("Toggle Toolbar", #selector(BrowserViewController.toggleToolbarCommand(_:)), "t", [.command, .option])
        )
        menu.addItem(
            item("Focus Mode", #selector(BrowserViewController.toggleFocusModeCommand(_:)), "f", [.command, .shift])
        )
        menu.addItem(.separator())
        menu.addItem(backgroundMenuItem())
        menu.addItem(.separator())
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))

        let holder = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }

    /// Background: how much of the space's colour sits over the window's vibrancy,
    /// and the space colour itself.
    private func backgroundMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Background")
        for (index, strength) in TintStrength.allCases.enumerated() {
            menu.addItem(
                item(
                    strength.title,
                    #selector(BrowserViewController.setTintStrengthCommand(_:)),
                    "",
                    .command,
                    tag: index
                )
            )
        }
        menu.addItem(.separator())
        menu.addItem(
            item("Cycle Background", #selector(BrowserViewController.cycleTintCommand(_:)), "b", [.command, .option])
        )
        menu.addItem(
            item("Space Colour…", #selector(BrowserViewController.pickSpaceColorCommand(_:)), "")
        )

        let holder = NSMenuItem(title: "Background", action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }

    private func historyMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "History")
        menu.addItem(item("Back", #selector(BrowserViewController.goBackCommand(_:)), "["))
        menu.addItem(item("Forward", #selector(BrowserViewController.goForwardCommand(_:)), "]"))

        let holder = NSMenuItem(title: "History", action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }

    private func tabsMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Tabs")
        // ⌘⇧[ / ⌘⇧] rather than ⌘⌥←/→: it is what Safari uses, and it keeps ⌘[ free
        // for Back, which is the more frequent action.
        menu.addItem(
            item("Previous Tab", #selector(BrowserViewController.previousTabCommand(_:)), "[", [.command, .shift])
        )
        menu.addItem(
            item("Next Tab", #selector(BrowserViewController.nextTabCommand(_:)), "]", [.command, .shift])
        )
        menu.addItem(.separator())
        for ordinal in 1...9 {
            let title = ordinal == 9 ? "Last Tab" : "Tab \(ordinal)"
            menu.addItem(
                item(
                    title,
                    #selector(BrowserViewController.selectTabByOrdinal(_:)),
                    "\(ordinal)",
                    .command,
                    tag: ordinal
                )
            )
        }

        let holder = NSMenuItem(title: "Tabs", action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
