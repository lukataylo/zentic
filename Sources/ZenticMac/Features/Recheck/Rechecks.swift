import Foundation
import Observation
import ZenticKit

/// Notices when a site changes under a kept custom version.
///
/// After a page in Custom mode loads, and at most once per site every few
/// minutes, the page is measured while the browser is idle and the result is
/// folded into that site's ``DriftTracker``. What it finds is only ever shown:
/// a dot on the mode glyph and a sentence in the mode picker. Repairing is the
/// user's call — nothing here reaches a model.
///
/// Held in memory. A relaunch starts the evidence afresh, which costs a few
/// visits' worth of patience and writes nothing about browsing to disk.
@MainActor
@Observable
final class Rechecks {
    static let shared = Rechecks()

    /// Off: no page is measured after it loads, and nothing is shown.
    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.enabledKey)
            if !isEnabled { found = [:] }
        }
    }

    /// Drift found per site, with the version it was found on: a repaired
    /// (re-kept) version starts clean.
    private var found: [String: (version: Date, drift: Drift)] = [:]

    @ObservationIgnored private var trackers: [String: (version: Date, tracker: DriftTracker)] = [:]
    @ObservationIgnored private var lastChecked: [String: Date] = [:]
    @ObservationIgnored private let defaults = DataDirectory.defaults
    private static let enabledKey = "recheckCustomVersions"

    private init() {
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// How the version on this tab's page has drifted, if it has.
    func drift(for tab: Tab?) -> Drift? {
        guard let tab, tab.mode == .custom, tab.previewing == nil, let key = tab.siteKey else { return nil }
        return drift(forKey: key, version: tab.browser?.custom(for: tab.url))
    }

    func drift(forKey key: String, version: CustomVersion?) -> Drift? {
        guard let entry = found[key], entry.version == version?.updatedAt else { return nil }
        return entry.drift
    }

    /// A page in Custom mode finished loading.
    func pageDidLoad(_ tab: Tab) {
        guard isEnabled, let url = tab.url, let key = SiteKey.for(url) else { return }
        if let last = lastChecked[key], Date.now.timeIntervalSince(last) < Drift.checkInterval { return }
        lastChecked[key] = .now
        Task { await check(tab, key: key, path: url.path()) }
    }

    private func check(_ tab: Tab, key: String, path: String) async {
        guard let observed = await tab.measureCustomVersion(idle: true),
            // The tab may have moved on, or the version changed, while the page idled.
            tab.siteKey == key, tab.mode == .custom, tab.previewing == nil,
            let version = tab.browser?.custom(for: tab.url)
        else { return }

        var tracker: DriftTracker
        if let entry = trackers[key], entry.version == version.updatedAt {
            tracker = entry.tracker
        } else if let baseline = version.baseline {
            tracker = DriftTracker(hide: version.hide, baseline: baseline)
        } else if observed.canBeBaseline(for: version.hide) {
            tracker = DriftTracker(hide: version.hide, baseline: adopt(observed, for: version, on: tab))
        } else {
            // Not a page to measure the version by; the next visit may be.
            lastChecked[key] = nil
            return
        }
        let drift = tracker.record(observed, path: path)
        trackers[key] = (version.updatedAt, tracker)
        if let drift {
            // Written only on a change: every write redraws whatever shows it.
            if found[key]?.drift != drift || found[key]?.version != version.updatedAt {
                found[key] = (version.updatedAt, drift)
            }
            trace("recheck", "\(key): \(drift.problem)")
        } else if found[key] != nil {
            found[key] = nil
        }
    }

    /// A version kept before re-checking existed has no baseline: what it does
    /// to the site today becomes what it should keep doing. Stored with the
    /// version — except from a private window, which writes nothing.
    private func adopt(_ observed: PageCheck, for version: CustomVersion, on tab: Tab) -> CustomBaseline {
        let baseline = CustomBaseline(observed)
        if let browser = tab.browser, !browser.isPrivate {
            var measured = version
            measured.baseline = baseline
            browser.saveCustom(measured, for: tab.url)
        }
        return baseline
    }
}

extension Tab {
    /// What the custom version on the page does to it now. See `web/src/recheck.ts`.
    func measureCustomVersion(idle: Bool) async -> PageCheck? {
        PageCheck(script: await callJS("return zentic.recheck(idle)", arguments: ["idle": idle]))
    }
}
