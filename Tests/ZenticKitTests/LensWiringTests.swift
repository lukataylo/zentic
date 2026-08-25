import Foundation
import Testing

@testable import ZenticKit

// The hops between a saved lens and a page, asserted against the app's own source.
//
// ## Why this test is shaped like this
//
// The first build of this feature shipped with `LensStore` instantiated nowhere,
// `generateLens`/`refitLens`/`recordReport` with no callers and
// `ReaderConfiguration.lenses` never populated: the whole feature was inert, and
// 259 tests passed. Not one of them could have failed, because none of them
// looked at a call site.
//
// So this looks at call sites. It is a coarse instrument and it knows it — a
// substring is not a proof that a line runs — but it fails on the one thing that
// actually went wrong, which is a hop being **absent**. Deleting the send, the
// assignment or the store call named below turns this red, and a comment claiming
// the wiring exists does not.
//
// ## What is left for it to do
//
// `ZenticMacTests` exists now, and the rules that *decide* things have been lifted
// out of the classes that cannot be built in a test and are executed properly:
// which set reaches the page and which page it is allowed to describe
// (`LensStagingTests`), what the button and the popover then say about it
// (`LensChromeTests`), how long a page's verdict lasts (`VerdictLifetimeTests`).
//
// None of that retires this file, and the reason is worth stating plainly. Every
// hop below crosses into something a test cannot have: a `WKWebView` to send
// `applyLenses` to, a `ReaderBridge` whose configuration is interpolated into a
// bootstrap script, a responder chain for ⌥⌘L, an `NSPopover` with a window under
// it. The decision each hop carries is tested; that the hop is still *there* is
// not, and cannot be without faking the world. This is the floor under that, and
// it should shrink only when a hop stops needing a window — not when the decision
// behind it gets a test.

@Suite("Lens wiring")
struct LensWiringTests {
    /// `Sources/`, from this file's path, the way `GoldenFixture.directory` finds
    /// the wire fixtures.
    static var sources: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()  // ZenticKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
            .appending(path: "Sources")
    }

    static func read(_ path: String) throws -> String {
        let url = sources.appending(path: path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// One hop: the file it lives in, the text that is it, and what stops working
    /// when it is gone. The reason is the whole value of the row — a failure here
    /// has to say what the user loses, not just which grep missed.
    struct Hop {
        var file: String
        var call: String
        var breaks: String
    }

    private static func check(_ hops: [Hop]) throws {
        for hop in hops {
            // Evaluated before the expectation rather than inside it: Swift
            // Testing prints the sub-expressions of a failed `#expect`, and a
            // whole source file in the failure output buries the sentence that
            // says what broke.
            let present = try read(hop.file).contains(hop.call)
            #expect(
                present,
                """
                \(hop.file) no longer contains `\(hop.call)`.
                Without it: \(hop.breaks)
                """
            )
        }
    }

    // MARK: - Storage

    /// Every public entry point on ``LensStore`` is reached by the app.
    ///
    /// The store is an actor with a file behind it, so a method nobody calls is
    /// not dead weight — it is a promise about the user's saved work that nothing
    /// keeps. `flush()` in particular: it exists so a coalesced report is not lost
    /// on the way to termination, and it is called from exactly one place.
    @Test("Every public LensStore method has a caller in the app")
    func storeIsReachable() throws {
        try Self.check([
            Hop(
                file: "ZenticMac/Content/LensController.swift",
                call: "let store = LensStore()",
                breaks: "nothing owns the store, so no lens is ever read or written"
            ),
            Hop(
                file: "ZenticMac/Content/LensController.swift",
                call: "store.lenses(for: host, path:",
                breaks: "no page is ever given a lens set"
            ),
            Hop(
                file: "ZenticMac/Content/LensController.swift",
                call: "store.all(for:",
                breaks: "the popover cannot list a lens that is switched off"
            ),
            Hop(
                file: "ZenticMac/Content/LensController.swift",
                call: "store.lens(id:",
                breaks: "edit, re-fit and duplicate resolve against a stale snapshot"
            ),
            Hop(
                file: "ZenticMac/Content/LensController.swift",
                call: "store.save(draft:",
                breaks: "Save in the editor persists nothing"
            ),
            Hop(
                file: "ZenticMac/Content/LensController.swift",
                call: "store.delete(id:",
                breaks: "Delete leaves the lens on disk and running on the next visit"
            ),
            Hop(
                file: "ZenticMac/Content/LensController.swift",
                call: "store.setEnabled(",
                breaks: "the popover checkbox moves and nothing changes"
            ),
            Hop(
                file: "ZenticMac/Content/LensController.swift",
                call: "store.recordReport(",
                breaks: "drift is forgotten at every relaunch, so the badge cannot"
                    + " explain a broken lens before the page loads"
            ),
            Hop(
                file: "ZenticMac/AppDelegate.swift",
                call: "store.flush()",
                breaks: "a coalesced report is dropped when the app quits"
            ),
        ])
    }

    // MARK: - Down to the page

    /// The lens set reaches the bootstrap, and the page, and can be replaced live.
    ///
    /// `configuration.lenses` is the one that matters most: it is what puts the
    /// stylesheet in the cascade at `document-start`, and it is the field that was
    /// never populated in the first build. Delivered as a command instead, it is a
    /// visible reflow on every visit; not delivered at all, the feature is inert
    /// and looks exactly like a lens whose selectors stopped matching.
    @Test("A saved lens reaches the page it was written for")
    func lensesReachThePage() throws {
        try Self.check([
            Hop(
                file: "ZenticMac/Content/TabController.swift",
                call: "configuration.lenses = plan.lenses",
                breaks: "no lens is in the bootstrap script, so nothing applies at"
                    + " document-start and the feature is inert"
            ),
            Hop(
                file: "ZenticMac/Content/TabController.swift",
                call: "bridge.send(.applyLenses(plan.lenses)",
                breaks: "toggling or saving a lens does not reach the loaded page"
            ),
            Hop(
                file: "ZenticMac/Content/TabController.swift",
                call: "await prepareLenses(for: url)",
                breaks: "the set is resolved after the document exists, which is a"
                    + " flash of the page the user asked not to see"
            ),
            Hop(
                file: "ZenticMac/Content/TabController.swift",
                call: "LensState.make(",
                breaks: "the toolbar and popover have no state to draw"
            ),
        ])
    }

    /// Every lens event the page can post reaches something that is not a trace.
    ///
    /// The Swift `switch` over `ReaderEvent` is exhaustive by the compiler, so a
    /// *missing* case cannot happen. A case that only logs can, and did: an event
    /// handled with `trace(...)` and nothing else is a page talking to an app that
    /// is not listening, which is indistinguishable from a page that never spoke.
    @Test("Every lens event the page posts reaches an action, not only a trace")
    func eventsReachAnAction() throws {
        try Self.check([
            Hop(
                file: "ZenticMac/Content/TabController.swift",
                call: "lensReports[report.lensID] = report",
                breaks: "`lensReport` is logged and discarded, so the badge never"
                    + " shows what a lens did"
            ),
            Hop(
                file: "ZenticMac/Content/TabController.swift",
                call: "LensController.shared.record(report)",
                breaks: "a report never reaches disk, so drift does not survive a relaunch"
            ),
            Hop(
                file: "ZenticMac/Content/TabController.swift",
                call: "drainCatalogWaiters(with: catalog)",
                breaks: "`lensRegions` never resumes the re-fit waiting on it"
            ),
            Hop(
                file: "ZenticMac/Content/TabController.swift",
                call: "await authorLens(for: request)",
                breaks: "`lensPrompt` is logged, the model is never called, and the"
                    + " editor stays at \"asking…\" for the life of the page"
            ),
            Hop(
                file: "ZenticMac/Content/TabController.swift",
                call: "await saveLensDraft(lens)",
                breaks: "`lensDraft` is logged and Save saves nothing"
            ),
            Hop(
                file: "ZenticMac/Content/TabController.swift",
                call: "isLensEditing = isEditing",
                breaks: "the app's idea of whether the editor is open drifts from"
                    + " the page's, and ⌥⌘L takes two presses"
            ),
            Hop(
                file: "ZenticMac/Content/TabController.swift",
                call: "failure.stage == \"lens.enterMode\"",
                breaks: "a mount that failed is never answered, so ⌥⌘L is silence"
                    + " until the settle ceiling expires"
            ),
        ])
    }

    // MARK: - Authoring and repair

    /// ⌥⌘L reaches the editor, the editor reaches the model, and the answer comes
    /// back as a proposal rather than as an effect.
    @Test("The authoring journey has every hop")
    func authoringIsWired() throws {
        try Self.check([
            Hop(
                file: "ZenticMac/AppDelegate.swift",
                call: "lensEditorCommand",
                breaks: "there is no menu item or shortcut that opens the editor"
            ),
            Hop(
                file: "ZenticMac/Content/BrowserViewController.swift",
                call: "func lensEditorCommand(",
                breaks: "the ⌥⌘L selector resolves to nothing on the responder chain"
            ),
            Hop(
                file: "ZenticMac/Content/BrowserViewController.swift",
                call: "#selector(lensEditorCommand)",
                breaks: "the menu item has no validation rule and is offered on a"
                    + " page that cannot carry a lens"
            ),
            Hop(
                file: "ZenticMac/Content/TabController.swift",
                call: "bridge.deliverLensEditor(to: webView)",
                breaks: "the editor bundle is never put in the page, so ⌥⌘L opens"
                    + " nothing — it is not in the document-start script"
            ),
            Hop(
                file: "ZenticMac/Content/TabController.swift",
                call: ".enterLensMode(",
                breaks: "the overlay is delivered and never told to mount"
            ),
            Hop(
                file: "ZenticMac/Content/LensController.swift",
                call: "openAI.generateLens(",
                breaks: "a prompt never reaches a model"
            ),
            Hop(
                file: "ZenticMac/Content/TabController.swift",
                call: "bridge.send(.proposeOps(proposal)",
                breaks: "the model's answer never reaches the editor, which is"
                    + " waiting on it with Ask disabled"
            ),
        ])
    }

    /// Drift is repairable: the popover offers Re-fit, Re-fit asks the page for a
    /// fresh catalog, and the catalog goes to the model with the regions' intent.
    @Test("The drift and repair journey has every hop")
    func refitIsWired() throws {
        try Self.check([
            Hop(
                file: "ZenticMac/Content/TabController.swift",
                call: "bridge.send(.requestRegions",
                breaks: "a re-fit is measured against the page as it was, not as it"
                    + " is, which is the difference the whole path exists for"
            ),
            Hop(
                file: "ZenticMac/Content/BrowserViewController.swift",
                call: "freshCatalog()",
                breaks: "Re-fit and Save never ask the page what is on it"
            ),
            Hop(
                file: "ZenticMac/Content/BrowserViewController.swift",
                call: "LensController.shared.refit(lens:",
                breaks: "the Re-fit button is drawn and does nothing"
            ),
            Hop(
                file: "ZenticMac/Content/LensController.swift",
                call: "openAI.refitLens(",
                breaks: "a drifted lens can never be repaired"
            ),
        ])
    }

    /// Every action the popover offers reaches the controller that performs it.
    @Test("Every popover action reaches the controller")
    func popoverActionsAreWired() throws {
        try Self.check([
            Hop(
                file: "ZenticMac/Content/BrowserViewController.swift",
                call: "LensController.shared.setEnabled(",
                breaks: "the row checkbox is decorative"
            ),
            Hop(
                file: "ZenticMac/Content/BrowserViewController.swift",
                call: "LensController.shared.delete(id:",
                breaks: "Delete is offered and does nothing"
            ),
            Hop(
                file: "ZenticMac/Content/BrowserViewController.swift",
                call: "LensController.shared.duplicate(id:",
                breaks: "Duplicate is offered and does nothing"
            ),
            Hop(
                file: "ZenticMac/Content/BrowserViewController.swift",
                call: "edit(lens:",
                breaks: "Edit… opens the editor on nothing, and Save then writes a"
                    + " second lens beside the one being edited"
            ),
            Hop(
                file: "ZenticMac/Content/BrowserViewController.swift",
                call: "LensController.didChangeLenses",
                breaks: "no open surface hears about a change, so the popover keeps"
                    + " showing a lens the user has just deleted"
            ),
        ])
    }
}
