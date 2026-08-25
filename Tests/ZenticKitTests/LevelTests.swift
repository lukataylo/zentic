import Foundation
import Testing

@testable import ZenticKit

@Suite("Page levels")
struct PageLevelTests {

    /// The whole point of a slider: every stop must do everything the one below it
    /// does. If the strip axis ever went down as the level went up, "more" would
    /// mean "fewer ads blocked" somewhere in the middle of the control.
    @Test("Stripping never weakens as the level rises")
    func stripIsMonotone() {
        for (lower, higher) in zip(PageLevel.allCases, PageLevel.allCases.dropFirst()) {
            #expect(lower.strip <= higher.strip, "\(lower) → \(higher)")
            #expect(lower < higher)
            // Same rule, other axis. A stop that pressed a consent button while the
            // one above it did not would make "more" mean "fewer walls dismissed"
            // somewhere in the middle of the control.
            #expect(
                !lower.dismissesCookieWalls || higher.dismissesCookieWalls,
                "\(lower) → \(higher)"
            )
        }
    }

    /// A reload is exactly the strip delta, across all 25 pairs. Asserted as a
    /// cross-product rather than a handful of cases because the failure this
    /// prevents is someone adding a sixth stop without deciding which axis it moves
    /// — and then either reloading the world on every click, or silently not
    /// applying a blocking change at all.
    @Test("Reload is required for exactly the blocking changes")
    func reloadTracksTheStripAxis() {
        for from in PageLevel.allCases {
            for to in PageLevel.allCases {
                #expect(
                    PageLevel.requiresReload(from: from, to: to) == (from.strip != to.strip),
                    "\(from) → \(to)"
                )
            }
        }
    }

    @Test("Moving within the reader layers never reloads")
    func readerTransitionsAreLive() {
        // The three that a user will do most often, and the reason the control can
        // feel instant at all.
        #expect(!PageLevel.requiresReload(from: .calm, to: .reader))
        #expect(!PageLevel.requiresReload(from: .reader, to: .rewritten))
        #expect(!PageLevel.requiresReload(from: .rewritten, to: .calm))
        // ...and the ones that must, because WebKit cannot un-block a request.
        #expect(PageLevel.requiresReload(from: .original, to: .clean))
        #expect(PageLevel.requiresReload(from: .clean, to: .calm))
    }

    /// Clean and Calm differing is the entire reason `.blockingOnly` exists. They
    /// collapsed into one another for the whole of M2 because the shell asked for
    /// `installedRuleLists()`, which is defined as `ruleLists(for: .standard)`.
    @Test("Clean and Calm are genuinely different shields")
    func cleanIsNotCalm() {
        #expect(PageLevel.clean.shield == .blockingOnly)
        #expect(PageLevel.calm.shield == .standard)
        #expect(PageLevel.clean.shield != PageLevel.calm.shield)
        #expect(PageLevel.original.shield == .off)
    }

    @Test("Only the reader levels render, and only the top level rewrites")
    func projectionsMatchTheLadder() {
        #expect(PageLevel.allCases.filter { $0.readerMode == .restructured } == [.reader, .rewritten])
        #expect(PageLevel.allCases.filter(\.allowsRewrite) == [.rewritten])
        #expect(PageLevel.allCases.filter(\.allowsTheme) == [.reader, .rewritten])
    }

    /// The line the user moved, and the one they did not.
    ///
    /// A consent wall is not the site's own layout — it is the tracking-consent
    /// apparatus — so it belongs with "ads and trackers blocked" rather than with
    /// the annoyances one stop up. Clean blocking every tracker on the page and
    /// then leaving the tracking dialog sitting on top of it was a boundary nobody
    /// could make sense of from the control.
    ///
    /// Original is the boundary that stays: dismissing a cookie wall is an action
    /// taken in the user's name, and the stop that promises to change nothing must
    /// change nothing.
    @Test("Cookie walls are dismissed from Clean up, and never at Original")
    func consentStartsAtClean() {
        #expect(PageLevel.allCases.filter(\.dismissesCookieWalls) == [.clean, .calm, .reader, .rewritten])
        #expect(!PageLevel.original.dismissesCookieWalls)
    }

    /// Why moving that line did not widen `requiresReload`.
    ///
    /// Consent is pressed by the in-page bundle, not by a rule list, so nothing
    /// about it needs a fresh document on its own — but the bundle only starts a
    /// dismissal at load, and a level change that does not reload cannot ask it to.
    /// The step that newly gains dismissal, Original → Clean, also moves the strip
    /// axis and so already reloads, which is what makes the move free.
    ///
    /// This fails if someone puts consent behind a threshold that shares a strip
    /// setting with the stop below it — Reader, say — where the user would press a
    /// stop, get no wall dismissed, and have no way to tell why.
    @Test("Every step that newly dismisses a cookie wall already reloads")
    func gainingConsentAlwaysReloads() {
        for from in PageLevel.allCases {
            for to in PageLevel.allCases where !from.dismissesCookieWalls && to.dismissesCookieWalls {
                #expect(PageLevel.requiresReload(from: from, to: to), "\(from) → \(to)")
            }
        }
    }
}

@Suite("Design suggestions")
struct DesignSuggestionTests {

    /// The reason these exist: a reference page and an essay want opposite
    /// typography, so a single generic list would be wrong for both.
    @Test("Suggestions lead with something about this kind of page")
    func archetypeLeadsTheList() {
        let docs = DesignSuggestions.forPage(archetype: .docs)
        let article = DesignSuggestions.forPage(archetype: .article)

        #expect(docs.first != article.first)
        #expect(docs.first?.contains("documentation") == true)
        #expect(article.first?.contains("long-form") == true)
    }

    @Test("A page with no archetype still gets somewhere to start")
    func alwaysOffersSomething() {
        for archetype in Archetype.allCases.map(Optional.some) + [nil] {
            let suggestions = DesignSuggestions.forPage(archetype: archetype)
            #expect(!suggestions.isEmpty, "\(String(describing: archetype))")
            #expect(suggestions.allSatisfy { !$0.isEmpty })
        }
    }

    @Test("No duplicates, and the list stays short enough to read")
    func listIsUsable() {
        for archetype in Archetype.allCases.map(Optional.some) + [nil] {
            let suggestions = DesignSuggestions.forPage(archetype: archetype)
            #expect(Set(suggestions).count == suggestions.count)
            // Twenty options is another blank field wearing a hat.
            #expect(suggestions.count <= 8, "\(String(describing: archetype))")
        }
    }

    /// A theme cannot change a word — but a joke design on a medical page is a
    /// statement about how seriously to take it, and we should not be the ones
    /// suggesting it.
    @Test("Fidelity-sensitive pages are not offered a novelty look")
    func sensitivePagesStaySober() {
        let sensitive = DesignSuggestions.forPage(archetype: .article, isFidelitySensitive: true)
        let ordinary = DesignSuggestions.forPage(archetype: .article, isFidelitySensitive: false)

        #expect(!sensitive.contains { $0.contains("1997") })
        #expect(ordinary.contains { $0.contains("1997") })
    }
}

@Suite("Level persistence")
@MainActor
struct LevelStoreTests {

    private let origin = "https://example.com"

    @Test("A pinned level survives a store reload")
    func pinRoundTrips() throws {
        let store = try BrowsingStore(url: nil)
        store.setPreference(.pinned(.original), for: origin)
        store.save()

        #expect(store.preference(for: origin) == .pinned(.original))
        #expect(store.level(for: origin) == .original)
    }

    @Test("A ceiling is stored as a cap, not as a pin")
    func ceilingRoundTrips() throws {
        let store = try BrowsingStore(url: nil)
        store.setPreference(.ceiling(.calm), for: origin)

        #expect(store.preference(for: origin) == .ceiling(.calm))
        // The archetype says article, the cap says Calm. The cap wins.
        store.recordExtraction(origin: origin, archetype: .article, isFidelitySensitive: false)
        #expect(store.level(for: origin) == .calm)
    }

    /// Choosing the level the site would have picked anyway is agreement, not a
    /// decision — and storing it as a pin would freeze the site there when its
    /// archetype memory later changes.
    @Test("Pinning the level that was already automatic stores nothing")
    func agreementIsNotAPin() throws {
        let store = try BrowsingStore(url: nil)
        store.recordExtraction(origin: origin, archetype: .article, isFidelitySensitive: false)
        #expect(store.level(for: origin) == .reader)

        store.setPreference(.pinned(.reader), for: origin)
        #expect(store.preference(for: origin) == .auto)

        // ...and because it was not pinned, the site follows when it turns out to
        // be an app after all.
        store.recordExtraction(origin: origin, archetype: .app, isFidelitySensitive: false)
        #expect(store.level(for: origin) == .calm)
    }

    /// The chrome caches one resolution per tab and redraws from it on every title
    /// change, favicon and reveal. If the standing choice were not in there it would
    /// have to be fetched where it is drawn, on that same path — so in practice it
    /// was not drawn at all, and the rail had no way to show what the user set.
    @Test("The resolution carries the standing choice, not just the two levels")
    func resolutionCarriesThePreference() throws {
        let store = try BrowsingStore(url: nil)
        store.recordExtraction(origin: origin, archetype: .article, isFidelitySensitive: false)

        #expect(store.resolution(for: origin).preference == .auto)

        store.setPreference(.ceiling(.calm), for: origin)
        let capped = store.resolution(for: origin)
        #expect(capped.preference == .ceiling(.calm))
        // The two levels alone cannot tell a ceiling that bites from a page that
        // simply landed low, which is the whole reason the preference has to travel.
        #expect(capped.level == .calm)
        #expect(capped.automatic == .reader)

        store.setPreference(.pinned(.original), for: origin)
        #expect(store.resolution(for: origin).preference == .pinned(.original))
    }

    /// A choice that agrees with the automatic answer is stored as `auto` on
    /// purpose. That is deliberate and tested elsewhere; what matters here is that
    /// the resolution reports what was *stored*, so the menu's checkmark and the
    /// rail's sentence describe the same thing rather than disagreeing.
    @Test("Agreement is reported as automatic, not as a pin")
    func agreementResolvesAsAutomatic() throws {
        let store = try BrowsingStore(url: nil)
        store.recordExtraction(origin: origin, archetype: .article, isFidelitySensitive: false)
        store.setPreference(.pinned(.reader), for: origin)

        #expect(store.resolution(for: origin).preference == .auto)
    }

    @Test("A real pin is not cleared when the archetype agrees later")
    func realPinsPersist() throws {
        let store = try BrowsingStore(url: nil)
        store.recordExtraction(origin: origin, archetype: .app, isFidelitySensitive: false)
        store.setPreference(.pinned(.original), for: origin)

        store.recordExtraction(origin: origin, archetype: .article, isFidelitySensitive: false)
        #expect(store.level(for: origin) == .original)
    }

    @Test("Fidelity sensitivity is remembered once seen")
    func fidelityIsMonotone() throws {
        let store = try BrowsingStore(url: nil)
        store.recordExtraction(origin: origin, archetype: .article, isFidelitySensitive: true)
        store.recordExtraction(origin: origin, archetype: .article, isFidelitySensitive: false)

        #expect(store.siteStat(for: origin)?.fidelitySensitiveSeen == true)
    }

    @Test("An origin with no record at all still resolves")
    func unknownOriginResolves() throws {
        let store = try BrowsingStore(url: nil)
        #expect(store.level(for: "https://never-seen.example") == .reader)
        #expect(store.level(for: nil) == .reader)
    }
}

@Suite("Level policy")
struct LevelPolicyTests {

    /// Invariant 2. Detection fails open, and the default must never be the one
    /// that mangles a mail client.
    @Test("An app never defaults above Calm")
    func appsAreNeverRestructuredByDefault() {
        for sensitive in [true, false] {
            let level = LevelPolicy.defaultLevel(archetype: .app, isFidelitySensitive: sensitive)
            #expect(level <= .calm)
            #expect(level.readerMode == .original)
        }
    }

    /// The case that looks like a bug and is not. Booting an unknown origin at
    /// `.calm` would mean the reader never appears on a site's first article —
    /// only on the second visit, once an archetype had been recorded.
    @Test("A never-visited origin still defaults to Reader")
    func unknownOriginsStillReach() {
        #expect(LevelPolicy.defaultLevel(archetype: nil, isFidelitySensitive: false) == .reader)
        #expect(LevelPolicy.resolve(SiteLevelInputs()) == .reader)
    }

    @Test("Feeds and threads stay at Calm until they have a layout")
    func feedsAreNotArticles() {
        #expect(LevelPolicy.defaultLevel(archetype: .feed, isFidelitySensitive: false) == .calm)
        #expect(LevelPolicy.defaultLevel(archetype: .thread, isFidelitySensitive: false) == .calm)
        #expect(LevelPolicy.defaultLevel(archetype: .article, isFidelitySensitive: false) == .reader)
        #expect(LevelPolicy.defaultLevel(archetype: .docs, isFidelitySensitive: false) == .reader)
    }

    /// Invariant 6: rewriting is off by default. No combination of page signals may
    /// ever produce it on its own.
    @Test("Rewriting is never reached by inference")
    func rewriteIsNeverAutomatic() {
        for archetype in Archetype.allCases.map(Optional.some) + [nil] {
            for sensitive in [true, false] {
                for enabled in [true, false] {
                    let level = LevelPolicy.resolve(
                        SiteLevelInputs(
                            preference: .auto,
                            archetype: archetype,
                            isFidelitySensitive: sensitive,
                            isRewriteEnabled: enabled
                        )
                    )
                    #expect(level != .rewritten, "\(String(describing: archetype)) \(sensitive) \(enabled)")
                }
            }
        }
    }

    @Test("Rewriting requires the global opt-in even when pinned")
    func pinnedRewriteNeedsTheOptIn() {
        let pinned = SiteLevelInputs(preference: .pinned(.rewritten), archetype: .article)
        #expect(LevelPolicy.resolve(pinned) == .reader)

        var enabled = pinned
        enabled.isRewriteEnabled = true
        #expect(LevelPolicy.resolve(enabled) == .rewritten)
    }

    @Test("A ceiling clamps the automatic answer without pinning it")
    func ceilingClamps() {
        let capped = SiteLevelInputs(preference: .ceiling(.calm), archetype: .article)
        #expect(LevelPolicy.resolve(capped) == .calm)

        // A ceiling above the automatic answer changes nothing — it is a cap, not
        // a target. Pinning is how you ask for more than the page suggests.
        let loose = SiteLevelInputs(preference: .ceiling(.rewritten), archetype: .article)
        #expect(LevelPolicy.resolve(loose) == .reader)
    }

    /// A site that used to look like an app, or used to look like prose, must not
    /// drag a deliberate choice around with it.
    @Test("A pin survives the archetype changing under it")
    func pinsOutliveTheArchetype() {
        for archetype in Archetype.allCases {
            let inputs = SiteLevelInputs(preference: .pinned(.original), archetype: archetype)
            #expect(LevelPolicy.resolve(inputs) == .original, "\(archetype)")
        }
    }

    /// The user may ask for the reader on a page we detect as an app. The control
    /// records the request; the bundle still declines it. What must never happen is
    /// the preference silently rewriting itself to something the user did not pick.
    @Test("Asking for Reader on an app is recorded, not overruled here")
    func overrideIsNotSecondGuessed() {
        let inputs = SiteLevelInputs(preference: .pinned(.reader), archetype: .app)
        #expect(LevelPolicy.resolve(inputs) == .reader)
    }
}
