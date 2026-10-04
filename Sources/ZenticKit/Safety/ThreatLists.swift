import Foundation

/// The downloaded threat lists on disk, and their refresh.
///
/// Each feed is kept as its parsed host list, one host per line. That one file
/// serves both consumers: the in-memory ``ThreatSet`` is rebuilt from it at
/// launch (a few milliseconds, off the main thread), and the subresource
/// content blocker is recompiled from it if WebKit ever evicts the compiled
/// copy — without going back to the network.
public actor ThreatLists {
    private let directory: URL
    private let fetcher: any FilterListFetching
    private let feeds: [ThreatFeed]
    private let now: @Sendable () -> Date
    private let manifestFile: JSONFile<Manifest>

    public init(
        directory: URL = DataDirectory.root.appending(path: "SafeBrowsing", directoryHint: .isDirectory),
        fetcher: any FilterListFetching = URLSessionFilterListFetcher(),
        feeds: [ThreatFeed] = ThreatFeed.all,
        now: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.directory = directory
        self.fetcher = fetcher
        self.feeds = feeds
        self.now = now
        manifestFile = JSONFile(name: "manifest.json", directory: directory)
    }

    struct Manifest: Codable, Sendable, Equatable {
        struct Feed: Codable, Sendable, Equatable {
            var etag: String?
            var checkedAt: Date
        }
        var feeds: [String: Feed] = [:]
    }

    /// What is installed: the set to match against, and enough to name it.
    public struct Snapshot: Sendable, Equatable {
        public var set: ThreatSet
        /// When upstream was last asked, successfully — the "updated" the user
        /// sees, since a 304 is as good as a download.
        public var checkedAt: Date?
        /// Changes exactly when the hosts do; names the compiled rule list.
        public var contentID: String
    }

    // MARK: - Reading

    /// The lists as they are on disk, or nil before the first download.
    public func snapshot() -> Snapshot? {
        let manifest = manifestFile.load() ?? Manifest()
        var hosts: [ThreatKind: [String]] = [:]
        var texts: [String] = []
        for feed in feeds {
            guard let text = try? String(contentsOf: hostsURL(feed), encoding: .utf8) else { continue }
            hosts[feed.kind] = text.split(separator: "\n").map(String.init)
            texts.append(feed.id + "\n" + text)
        }
        guard !hosts.isEmpty else { return nil }
        return Snapshot(
            set: ThreatSet(hosts: hosts),
            checkedAt: checkedAt(manifest),
            contentID: String(ContentHash.of(texts.joined(separator: "\n")).prefix(16)))
    }

    /// When every list was last confirmed current; nil until each has been.
    public func checkedAt() -> Date? { checkedAt(manifestFile.load() ?? Manifest()) }

    private func checkedAt(_ manifest: Manifest) -> Date? {
        let checked = feeds.compactMap { manifest.feeds[$0.id]?.checkedAt }
        return checked.count == feeds.count ? checked.min() : nil
    }

    /// Whether any list is older than a day, or missing.
    public func isStale() -> Bool {
        let manifest = manifestFile.load() ?? Manifest()
        return feeds.contains {
            guard let checked = manifest.feeds[$0.id]?.checkedAt else { return true }
            return now().timeIntervalSince(checked) > BlockerLimits.listMaxAge
        }
    }

    /// Every listed host, for compiling the subresource blocker.
    public func allHosts() -> [String] {
        var seen = Set<String>()
        return feeds.flatMap { feed in
            ((try? String(contentsOf: hostsURL(feed), encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }.filter { seen.insert($0).inserted }
    }

    // MARK: - Refreshing

    public enum RefreshError: Error, Equatable {
        /// Every feed failed. One failing is not an error: the other still
        /// updated, and the failed one keeps its last good copy.
        case allFailed(String)
    }

    /// Ask upstream for each list, with the stored ETag unless `force`.
    /// Returns a new snapshot when any list's hosts changed, nil when
    /// everything was current.
    public func refresh(force: Bool = false) async throws -> Snapshot? {
        var manifest = manifestFile.load() ?? Manifest()
        var changed = false
        var failures: [String] = []

        for feed in feeds {
            let previous = manifest.feeds[feed.id]
            let result: FilterListFetchResult
            do {
                result = try await fetcher.fetch(feed.source, etag: force ? nil : previous?.etag)
            } catch {
                failures.append("\(feed.title): \(error)")
                continue
            }
            switch result {
            case .notModified:
                guard var entry = previous else { continue }
                entry.checkedAt = now()
                manifest.feeds[feed.id] = entry
            case .updated(let text, let etag):
                let hosts = ThreatFeed.hosts(in: text)
                // A list that parses to nothing is a broken download or a
                // changed format, not "the internet is safe now". Keep the
                // last good copy rather than switching protection off.
                guard !hosts.isEmpty else {
                    failures.append("\(feed.title): no hosts in the download")
                    continue
                }
                let body = hosts.joined(separator: "\n")
                if body != (try? String(contentsOf: hostsURL(feed), encoding: .utf8)) {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try Data(body.utf8).write(to: hostsURL(feed), options: .atomic)
                    changed = true
                }
                manifest.feeds[feed.id] = .init(etag: etag, checkedAt: now())
            }
        }

        manifestFile.save(manifest)
        if failures.count == feeds.count { throw RefreshError.allFailed(failures.joined(separator: "; ")) }
        return changed ? snapshot() : nil
    }

    private func hostsURL(_ feed: ThreatFeed) -> URL {
        directory.appending(path: "\(feed.id).hosts")
    }
}

/// The threat hosts as a `WKContentRuleList`, so a harmless page cannot pull a
/// script, an iframe or a download from one of them.
///
/// Third-party loads only. The top-level page is the interstitial's job, and
/// once someone has chosen to visit a listed site anyway, its own first-party
/// resources must load or the page they insisted on seeing would be broken.
public enum ThreatRules {
    public static func json(hosts: [String]) -> String {
        let rules = hosts.compactMap { raw -> String? in
            // Re-validated here, not trusted from the caller: an unescaped
            // character in a url-filter is a rule that matches something else.
            guard let host = ThreatFeed.normalised(raw) else { return nil }
            let escaped = host.replacingOccurrences(of: ".", with: "\\\\.")
            return #"{"trigger":{"url-filter":"^[^:]+://+([^:/]+\\.)?\#(escaped)[:/]","load-type":["third-party"]},"action":{"type":"block"}}"#
        }
        return "[" + rules.joined(separator: ",") + "]"
    }
}
