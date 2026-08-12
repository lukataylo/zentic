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
    /// `installedRuleLists()` is async and blocking a tab's creation on list
    /// compilation would stall the first paint. Rule lists can join a live
    /// `WKUserContentController` at any time; the cost of attaching a moment late
    /// is that the very first requests of the very first page load may slip
    /// through, which is worth it against a stalled window.
    static func attach(to controller: WKUserContentController, origin: String?) {
        Task {
            let shield = if let origin { await engine.shield(for: origin) } else { ShieldState.standard }
            guard shield != .off else {
                trace("blocking", "shield off for \(origin ?? "?")")
                return
            }
            guard let lists = try? await engine.installedRuleLists() else { return }
            for list in lists {
                controller.add(list)
            }
        }
    }
}
