import Foundation
import WebKit
import ZenticKit

/// The app's one content blocker, and the glue that attaches its compiled
/// lists to tabs.
///
/// One engine for the whole app, not one per tab. Compiling EasyList takes seconds
/// and WebKit caches the result by identifier, so a second engine would either
/// duplicate that work or race the first one for the same store.
@MainActor
enum Blocking {
    /// Compiled lists live in the engine's own store under `DataDirectory`, not
    /// WebKit's default one: the default store is shared by every copy of the app,
    /// so an isolated test run would garbage-collect the lists of the copy someone
    /// is browsing with.
    static let engine = WebKitContentBlocker()

    /// Warm the lists at launch, off the critical path.
    ///
    /// Deliberately not awaited by anyone: the seed list compiles quickly and the
    /// full set arrives when it arrives. A browser that waited for EasyList before
    /// showing a window would trade the thing users notice (launch) for the thing
    /// they do not (the first few hundred milliseconds of blocking).
    static func warm() {
        Task {
            do {
                let lists = try await engine.ruleLists()
                trace("blocking", "installed \(lists.count) rule lists")
            } catch {
                // A browser without blocking is still a browser. Say so and move on.
                trace("blocking", "unavailable: \(error)")
            }
        }
    }

    /// Turn blocking on or off for a live controller.
    ///
    /// Removes first: rule lists are additive, so turning blocking off by
    /// attaching nothing would leave the lists in place.
    ///
    /// Callers that are *raising* protection must reload afterwards. WebKit bakes
    /// `css-display-none` into a document at load and never re-evaluates it, and a
    /// request already on the wire cannot be recalled — so this call changes the
    /// next document, not the one on screen.
    static func reattach(to controller: WKUserContentController, blocking: Bool) async {
        register(controller, blocking: blocking)
        await apply(blocking, to: controller, removingFirst: true)
    }

    private static func apply(
        _ blocking: Bool,
        to controller: WKUserContentController,
        removingFirst: Bool = false
    ) async {
        // Fetched *before* anything is detached, deliberately. Compilation can fail
        // — a corrupt store, a rule list evicted under memory pressure — and a
        // remove-then-fail ordering would leave the tab with no protection at all.
        let lists: [WKContentRuleList]
        if !blocking {
            lists = []
        } else if let compiled = try? await engine.ruleLists() {
            lists = compiled
        } else {
            trace("blocking", "no lists · leaving the tab as it is")
            return
        }

        if removingFirst { controller.removeAllContentRuleLists() }
        for list in lists {
            controller.add(list)
        }
        // Whatever the site's mode: protection from malware hosts is not a
        // matter of taste, so Original keeps it.
        if let threats = SafeBrowsing.shared.ruleList { controller.add(threats) }
    }

    // MARK: - Re-attaching when the full set lands

    /// Live controllers, weakly held, with whether each blocks.
    ///
    /// The seed list compiles in milliseconds and EasyList takes seconds, so the
    /// first tabs of a first launch attach seed-only protection. `engine.updates()`
    /// exists precisely to fix that up, and until now nothing in the app subscribed
    /// to it — those tabs kept seed-only protection until they happened to reload.
    private final class Attached {
        weak var controller: WKUserContentController?
        var blocking: Bool
        init(_ controller: WKUserContentController, _ blocking: Bool) {
            self.controller = controller
            self.blocking = blocking
        }
    }

    private static var attached: [Attached] = []
    private static var isWatching = false

    /// Remember whether a controller blocks, so a later refresh never turns
    /// blocking back on for a site in Original.
    private static func register(_ controller: WKUserContentController, blocking: Bool) {
        attached.removeAll { $0.controller == nil }
        if let existing = attached.first(where: { $0.controller === controller }) {
            existing.blocking = blocking
        } else {
            attached.append(Attached(controller, blocking))
        }
        startWatching()
    }

    private static func startWatching() {
        guard !isWatching else { return }
        isWatching = true
        Task {
            for await _ in await engine.updates() {
                trace("blocking", "installed set changed · re-attaching tabs")
                await reapply()
            }
        }
    }

    /// Re-attach every live tab's lists — when Safe Browsing's list changes or
    /// is switched off, which must reach open pages without waiting for a load.
    static func reattachAll() {
        Task { await reapply() }
    }

    private static func reapply() async {
        attached.removeAll { $0.controller == nil }
        for entry in attached {
            guard let controller = entry.controller else { continue }
            await apply(entry.blocking, to: controller, removingFirst: true)
        }
    }
}
