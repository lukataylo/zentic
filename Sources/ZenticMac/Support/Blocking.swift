import Foundation
import WebKit
import ZenticKit

/// The app's one content blocker.
///
/// `BlockerEngine` was written for M2 and then never attached to anything, which
/// is why nothing was ever blocked: the compiler, the cache and the converter all
/// worked, and no web view had ever seen a rule list. This is the missing wire.
///
/// One engine for the whole app, not one per tab. Compiling EasyList takes seconds
/// and WebKit caches the result by identifier, so a second engine would either
/// duplicate that work or race the first one for the same store.
@MainActor
enum Blocking {
    static let engine = BlockerEngine(compiler: WebKitRuleListCompiler())

    /// Warm the lists at launch, off the critical path.
    ///
    /// Deliberately not awaited by anyone: the seed list compiles quickly and the
    /// full set arrives when it arrives. A browser that waited for EasyList before
    /// showing a window would trade the thing users notice (launch) for the thing
    /// they do not (the first few hundred milliseconds of blocking).
    static func warm() {
        Task {
            do {
                let lists = try await engine.installedRuleLists()
                trace("blocking", "installed \(lists.count) rule lists")
            } catch {
                // A browser without blocking is still a browser. Say so and move on.
                trace("blocking", "unavailable: \(error)")
            }
        }
    }

    /// Attach the compiled lists to a tab's content controller.
    ///
    /// Called after the web view exists rather than during configuration, because
    /// the lists are async and blocking a tab's creation on list compilation would
    /// stall the first paint. Rule lists can join a live `WKUserContentController`
    /// at any time; the cost of attaching a moment late is that the very first
    /// requests of the very first page load may slip through, which is worth it
    /// against a stalled window.
    static func attach(to controller: WKUserContentController, shield: ShieldState) {
        // Registered synchronously, before the attach is even scheduled: a refresh
        // that lands in the gap would otherwise re-attach every tab except the one
        // still being set up, which is precisely the tab most likely to be holding
        // seed-only rules.
        register(controller, shield: shield)
        Task { await apply(shield, to: controller) }
    }

    /// Swap a live controller onto a different shield.
    ///
    /// Removes first: rule lists are additive, so re-adding a narrower set over a
    /// wider one leaves the wider one attached and the change does nothing.
    ///
    /// Callers that are *raising* protection must reload afterwards. WebKit bakes
    /// `css-display-none` into a document at load and never re-evaluates it, and a
    /// request already on the wire cannot be recalled — so this call changes the
    /// next document, not the one on screen.
    static func reattach(to controller: WKUserContentController, shield: ShieldState) async {
        register(controller, shield: shield)
        await apply(shield, to: controller, removingFirst: true)
    }

    private static func apply(
        _ shield: ShieldState,
        to controller: WKUserContentController,
        removingFirst: Bool = false
    ) async {
        // `ruleLists(for:)`, not `installedRuleLists()` — the latter is defined as
        // `ruleLists(for: .standard)`, so routing through it made `.blockingOnly`
        // attach the cosmetic lists too and silently collapsed two shield states
        // into one.
        //
        // Fetched *before* anything is detached, deliberately. Compilation can fail
        // — a corrupt store, a rule list evicted under memory pressure — and a
        // remove-then-fail ordering would leave the tab with no protection at all
        // while the user believes they only moved one notch.
        let lists: [WKContentRuleList]
        if shield == .off {
            lists = []
        } else if let compiled = try? await engine.ruleLists(for: shield) {
            lists = compiled
        } else {
            trace("blocking", "no lists for \(shield.rawValue) · leaving the tab as it is")
            return
        }

        if removingFirst { controller.removeAllContentRuleLists() }
        for list in lists {
            controller.add(list)
        }
    }

    // MARK: - Re-attaching when the full set lands

    /// Live controllers, weakly held, with the shield each was attached under.
    ///
    /// The seed list compiles in milliseconds and EasyList takes seconds, so the
    /// first tabs of a first launch attach seed-only protection. `engine.updates()`
    /// exists precisely to fix that up, and until now nothing in the app subscribed
    /// to it — those tabs kept seed-only protection until they happened to reload.
    private final class Attached {
        weak var controller: WKUserContentController?
        var shield: ShieldState
        init(_ controller: WKUserContentController, _ shield: ShieldState) {
            self.controller = controller
            self.shield = shield
        }
    }

    private static var attached: [Attached] = []
    private static var isWatching = false

    /// Remember the shield a controller is running under, so a later refresh
    /// re-attaches the same subset rather than promoting every tab to `.standard`.
    private static func register(_ controller: WKUserContentController, shield: ShieldState) {
        attached.removeAll { $0.controller == nil }
        if let existing = attached.first(where: { $0.controller === controller }) {
            existing.shield = shield
        } else {
            attached.append(Attached(controller, shield))
        }
        startWatching()
    }

    private static func startWatching() {
        guard !isWatching else { return }
        isWatching = true
        Task {
            for await _ in await engine.updates() {
                attached.removeAll { $0.controller == nil }
                trace("blocking", "installed set changed · re-attaching \(attached.count) tabs")
                for entry in attached {
                    guard let controller = entry.controller else { continue }
                    await apply(entry.shield, to: controller, removingFirst: true)
                }
            }
        }
    }
}
