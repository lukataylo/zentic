import Foundation

/// What a listed host is known for. The interstitial explains the two very
/// differently: phishing wants your password, malware wants your Mac.
public enum ThreatKind: Sendable, CaseIterable {
    case malware, phishing
}

/// A public list of dangerous hosts, downloaded whole and matched on this Mac.
///
/// Whole lists rather than a lookup service (Google Safe Browsing and friends)
/// because a lookup sends the service a hash prefix of every address you open,
/// and "nothing about browsing leaves the device" is an invariant, not a goal.
///
/// Both lists come from malware-filter (curbengh), which republishes the
/// primary sources as plain hosts files on a CDN that answers `If-None-Match`,
/// and — the reason to prefer it over the raw feeds — drops any host on the
/// Tranco/Umbrella popularity lists, so a phishing page parked on a shared
/// host cannot get the whole of that host flagged. Phishing Army was ruled
/// out by its non-commercial licence, OpenPhish's own feed by its terms.
public struct ThreatFeed: Sendable {
    public let id: String
    public let kind: ThreatKind
    public let title: String
    public let url: URL
    /// Who to credit, and under what licence. Shown wherever the list is named.
    public let attribution: String

    public static let phishing = ThreatFeed(
        id: "phishing", kind: .phishing, title: "Phishing Filter",
        url: URL(string: "https://malware-filter.pages.dev/phishing-filter-hosts.txt")!,
        attribution: "malware-filter, from OpenPhish, PhishTank and IPThreat · CC BY-SA 4.0")

    /// The "online" variant: only hosts URLhaus currently sees serving malware.
    /// Malware hosts are taken down quickly, and a list of dead ones would only
    /// produce warnings about sites that are now someone else's.
    public static let malware = ThreatFeed(
        id: "malware", kind: .malware, title: "URLhaus Filter",
        url: URL(string: "https://malware-filter.pages.dev/urlhaus-filter-hosts-online.txt")!,
        attribution: "malware-filter, from abuse.ch URLhaus · CC0")

    public static let all: [ThreatFeed] = [.malware, .phishing]

    public static func with(kind: ThreatKind) -> ThreatFeed {
        all.first { $0.kind == kind }!
    }

    /// The source as the shared filter-list fetcher wants it, so downloads get
    /// the same ETag handling and size ceiling as the content blockers'.
    var source: FilterListSource {
        FilterListSource(id: "threats.\(id)", title: title, url: url, isDefault: true)
    }

    /// The hosts in a hosts-format list, normalised and de-duplicated.
    ///
    /// Accepts `0.0.0.0 host`, `127.0.0.1 host` and bare `host` lines. Anything
    /// that is not a plain hostname is dropped rather than repaired: each host
    /// is compiled into a content-blocker regex, so a line that smuggled in a
    /// `/`, a space or a `*` must never get that far.
    public static func hosts(in text: String) -> [String] {
        var seen = Set<String>()
        var hosts: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let content = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let fields = content.split(whereSeparator: \.isWhitespace)
            let candidate: Substring?
            switch fields.count {
            case 1: candidate = fields[0]
            case 2 where sinkholes.contains(String(fields[0])): candidate = fields[1]
            default: candidate = nil
            }
            guard let candidate, let host = normalised(candidate), seen.insert(host).inserted else { continue }
            hosts.append(host)
        }
        return hosts
    }

    private static let sinkholes: Set<String> = ["0.0.0.0", "127.0.0.1", "::", "::1"]

    /// Lowercased, without a trailing dot; nil for anything but a dotted name
    /// made of letters, digits, hyphens and underscores.
    static func normalised<S: StringProtocol>(_ raw: S) -> String? {
        var host = raw.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        guard host.count <= 253, host.contains("."), !host.hasPrefix("."), !host.contains(".."),
            !sinkholes.contains(host)
        else { return nil }
        let allowed = host.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "." || $0 == "_"
        }
        return allowed ? host : nil
    }
}
