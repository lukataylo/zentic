import Foundation
import Testing
import ZenticKit

@testable import ZenticMac

/// How long a level set on the rail is true for.
///
/// The defect these exist for, reported on theverge.com. The user dragged the rail
/// to Clean to look at the page, and weeks later reported "reader view doesn't work"
/// on that site. It worked: every drag wrote `.pinned(level)` for the origin, so
/// the momentary look had pinned the site below the reader permanently —
///
/// ```
/// realize BFEA clean https://www.theverge.com/
/// revealed · passthrough · 0ms
/// ```
///
/// — and `PageLevel.readerMode` at Clean is `.original`, so the pipeline declined
/// on arrival, every visit, for good. The menu behind the rail's label already had
/// "Always ⟨level⟩" and "Never above ⟨level⟩" for that intent, deliberately chosen
/// and named in words; a drag was performing the same permanent act by accident.
///
/// So the rail changes the page and the menu changes the site. The lifetime is the
/// whole fix, and it is keyed to a document for two reasons that pull in opposite
/// directions — see ``PageLevelOverride``.
@Suite("Page-scoped levels")
struct PageLevelOverrideTests {

    private let article = URL(string: "https://www.theverge.com/1/tech-story")!

    /// The reason the scope cannot be "until the next navigation". A drag across
    /// the strip layer reloads for itself — WebKit cannot recall a request already
    /// sent — so an override that a reload dropped would be undone by the act of
    /// applying it, and Clean would spring straight back to Reader.
    @Test("A reload keeps the level the rail was dragged to")
    func reloadKeepsTheDrag() {
        var override = PageLevelOverride()
        override.hold(.clean, for: article, standing: .reader)

        #expect(override.level(at: article) == .clean)
        // A reload preserves the URL exactly, so nothing expires.
        let expired = override.expire(at: article)
        #expect(!expired)
        #expect(override.level(at: article) == .clean)
    }

    /// The other direction, and the half that makes the gesture honest: the next
    /// article on the same site is a different page, so it gets the site's answer.
    @Test("The next page on the same site does not inherit the drag")
    func navigationDropsTheDrag() {
        var override = PageLevelOverride()
        override.hold(.clean, for: article, standing: .reader)

        let next = URL(string: "https://www.theverge.com/2/other-story")!
        #expect(override.level(at: next) == nil)
        // ...and the tab is told, so it can go and fetch the site's answer rather
        // than take the cheap same-origin early-out in `adoptLevel`.
        let expired = override.expire(at: next)
        #expect(expired)
        #expect(override.level(at: article) == nil)
    }

    @Test("Crossing to another site drops it too")
    func crossOriginDropsTheDrag() {
        var override = PageLevelOverride()
        override.hold(.clean, for: article, standing: .reader)
        let expired = override.expire(at: URL(string: "https://example.com/"))
        #expect(expired)
    }

    /// An anchor click creates no document and is not a navigation, so it must not
    /// throw away a level the user set on the page still in front of them.
    @Test("An anchor on the same page is the same page")
    func fragmentIsNotANavigation() {
        var override = PageLevelOverride()
        override.hold(.reader, for: article, standing: .clean)

        let anchor = URL(string: "https://www.theverge.com/1/tech-story#comments")!
        #expect(override.level(at: anchor) == .reader)
        let expired = override.expire(at: anchor)
        #expect(!expired)
    }

    /// Agreement is not an override — the same rule `BrowsingStore.setPreference`
    /// applies to a pin. Without it, dragging back to where you started would leave
    /// the rail marked as overridden with nothing about the page changed.
    @Test("Dragging to the level the site already gives releases instead of holding")
    func agreementIsNotAnOverride() {
        var override = PageLevelOverride()
        override.hold(.clean, for: article, standing: .reader)
        override.hold(.reader, for: article, standing: .reader)

        #expect(override.level(at: article) == nil)
        #expect(override == PageLevelOverride())
    }

    /// The signal `adoptLevel` guards on. Nothing held means nothing to report, or
    /// every same-site click would pay for a store read it does not need.
    @Test("Nothing held expires nothing")
    func expiringAnEmptyOverrideReportsNothing() {
        var override = PageLevelOverride()
        let expiredAtPage = override.expire(at: article)
        let expiredAtNothing = override.expire(at: nil)
        #expect(!expiredAtPage)
        #expect(!expiredAtNothing)
        #expect(override.level(at: article) == nil)
    }

    @Test("A level held against no URL at all is not held")
    func noURLIsNotADocument() {
        var override = PageLevelOverride()
        override.hold(.clean, for: nil, standing: .reader)
        #expect(override.level(at: nil) == nil)
        #expect(override.level(at: article) == nil)
    }

    @Test("Releasing puts the page back to the site's answer")
    func releaseClears() {
        var override = PageLevelOverride()
        override.hold(.original, for: article, standing: .reader)
        override.release()
        #expect(override.level(at: article) == nil)
    }
}

/// The rail's drag, and the menu's choice, at the layer that owns both.
///
/// What is *not* covered here is `BrowserViewController`, which is where the two
/// doors are wired to the controls: it is an `NSViewController` over a loaded view,
/// a restored session and a sidebar, and constructing one in a test would be
/// asserting on AppKit. The store write that caused the defect lived there and is
/// gone; what these hold still is that the drag's effect is scoped to the document
/// and that no level the rail sets can reach the store.
@Suite("Rail drag scope")
@MainActor
struct RailDragScopeTests {

    private static let origin = "https://www.theverge.com"

    /// A tab on a Verge article, resolving its level from a real store.
    ///
    /// `adoptStandingLevel` stands in for `realize()`, which does the same two
    /// things — take the site's answer as both the standing level and the level on
    /// screen — and also builds a `WKWebView`, which a test has no use for. The
    /// level path below the web view is identical either way: `setLevel` reaches
    /// for a bridge and a web view, finds neither, and has already recorded the
    /// level by then.
    private func makeTab(
        store: BrowsingStore,
        path: String = "/1/tech-story"
    ) -> TabController {
        let space = store.spacesEnsuringDefault()[0]
        let record = store.addTab(to: space, url: URL(string: Self.origin + path))
        let controller = TabController(
            record: record,
            faviconService: FaviconService(),
            resolveLevel: { store.resolution(for: $0) }
        )
        controller.refreshLevelResolution()
        controller.adoptStandingLevel(store.level(for: Self.origin))
        return controller
    }

    /// The report, in one assertion. The site is an article site, so it resolves to
    /// Reader; the user drags to Clean to look at the page; the site still resolves
    /// to Reader, because a drag is not a decision about the site.
    @Test("Dragging the rail leaves the site's stored preference alone")
    func dragDoesNotPinTheSite() throws {
        let store = try BrowsingStore(url: nil)
        store.recordExtraction(origin: Self.origin, archetype: .article, isFidelitySensitive: false)
        let controller = makeTab(store: store)
        #expect(controller.level == .reader)

        controller.setPageLevel(.clean)

        #expect(controller.level == .clean)
        #expect(store.preference(for: Self.origin) == .auto)
        // The next visit — a fresh tab on the same origin, reading the same store.
        #expect(store.level(for: Self.origin) == .reader)
        let next = makeTab(store: store, path: "/2/other-story")
        #expect(next.level == .reader)
        #expect(next.pageScopedFrom == nil)
    }

    /// The rail cannot tell a dragged Clean from a pinned Clean out of `level` and
    /// `levelPreference` — both read "Clean, auto" and "Clean, pinned to Clean"
    /// respectively regardless of how the page got there — so the tab has to say
    /// which it is, and say what the page falls back to.
    @Test("A dragged level reports what the page reverts to; a resolved one reports nothing")
    func dragIsReportedToTheChrome() throws {
        let store = try BrowsingStore(url: nil)
        store.recordExtraction(origin: Self.origin, archetype: .article, isFidelitySensitive: false)
        let controller = makeTab(store: store)
        #expect(controller.pageScopedFrom == nil)

        controller.setPageLevel(.clean)
        #expect(controller.pageScopedFrom == .reader)

        // Dragging back is agreement, not a second override.
        controller.setPageLevel(.reader)
        #expect(controller.pageScopedFrom == nil)
    }

    /// A pin is a standing choice and a drag is not, so a drag must not rewrite one
    /// — and must not be silently ignored either. It moves the page and leaves the
    /// pin in force for everything else, which is what the rail then has to say.
    @Test("Dragging away from a pin moves the page and leaves the pin standing")
    func dragDoesNotRewriteAPin() throws {
        let store = try BrowsingStore(url: nil)
        store.recordExtraction(origin: Self.origin, archetype: .article, isFidelitySensitive: false)
        store.setPreference(.pinned(.clean), for: Self.origin)
        let controller = makeTab(store: store)
        #expect(controller.level == .clean)

        controller.setPageLevel(.reader)

        #expect(controller.level == .reader)
        #expect(store.preference(for: Self.origin) == .pinned(.clean))
        // The page reverts to the pin, not to the automatic answer, and the rail is
        // told which — "back to Clean" is the true sentence here, "back to Reader"
        // would be the automatic answer the pin exists to override.
        #expect(controller.pageScopedFrom == .clean)
        #expect(controller.levelPreference == .pinned(.clean))
    }

    /// The un-pin nicety, still reachable and still in the one place that writes:
    /// the menu. `setPreference` collapses a choice that agrees with the automatic
    /// answer into `.auto`, so picking "Always Reader" on a site that lands there
    /// anyway removes the pin rather than replacing it.
    @Test("The menu is what makes a level standing, and what removes a pin")
    func menuOwnsTheStandingChoice() throws {
        let store = try BrowsingStore(url: nil)
        store.recordExtraction(origin: Self.origin, archetype: .article, isFidelitySensitive: false)
        store.setPreference(.pinned(.clean), for: Self.origin)

        store.setPreference(.pinned(.reader), for: Self.origin)
        #expect(store.preference(for: Self.origin) == .auto)
        #expect(store.level(for: Self.origin) == .reader)
    }

    /// A standing choice supersedes a drag made before it. Left to expire on its
    /// own the drag would sit on top of the level the user just named, and the menu
    /// would look like it had been ignored.
    @Test("Choosing a standing level clears a drag made on the page")
    func standingChoiceClearsTheDrag() throws {
        let store = try BrowsingStore(url: nil)
        store.recordExtraction(origin: Self.origin, archetype: .article, isFidelitySensitive: false)
        let controller = makeTab(store: store)
        controller.setPageLevel(.clean)
        #expect(controller.pageScopedFrom == .reader)

        store.setPreference(.ceiling(.calm), for: Self.origin)
        controller.adoptStandingLevel(store.level(for: Self.origin))
        controller.refreshLevelResolution()

        #expect(controller.level == .calm)
        #expect(controller.pageScopedFrom == nil)
        #expect(controller.levelPreference == .ceiling(.calm))
    }
}
