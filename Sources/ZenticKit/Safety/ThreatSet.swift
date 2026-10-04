import CryptoKit
import Foundation

/// The dangerous hosts, held as sorted 64-bit hashes: the check that runs in
/// `decidePolicyFor` on the main thread is a handful of binary searches, and
/// forty thousand hosts cost 320 KB instead of the megabytes their strings would.
///
/// The first 64 bits of SHA-256: stable across launches, which Swift's own
/// `Hasher` deliberately is not, and — unlike a fast non-cryptographic hash
/// such as FNV — nobody can craft a listed host that collides with a real
/// site's and get that site flagged for everyone. By chance, a given host
/// collides with one of ~50k entries around once in 10¹⁴.
public struct ThreatSet: Sendable, Equatable {
    private var hashes: [ThreatKind: [UInt64]]

    public init(hosts: [ThreatKind: [String]] = [:]) {
        hashes = hosts.mapValues { Array(Set($0.map(Self.hash))).sorted() }
    }

    public var count: Int { hashes.values.reduce(0) { $0 + $1.count } }

    /// The listing that covers `host`, if any: the host itself or one of its
    /// parent domains, so a list naming `evil.example` also covers
    /// `login.evil.example` — the shape almost every phishing kit takes.
    /// Malware is reported ahead of phishing when a host is on both.
    public func match(host raw: String) -> ThreatMatch? {
        guard let host = ThreatFeed.normalised(raw) else { return nil }
        for candidate in Self.candidates(for: host) {
            let hash = Self.hash(candidate)
            for kind in ThreatKind.allCases where hashes[kind]?.containsSorted(hash) == true {
                return ThreatMatch(kind: kind, listedHost: candidate)
            }
        }
        return nil
    }

    /// The host and its parents, longest first, stopping before the bare
    /// top-level domain — at most five, as Google Safe Browsing does, which
    /// bounds the work for a pathological hostname. An IP address has no
    /// parents: `2.3.4` is not a network that contains `1.2.3.4`.
    static func candidates(for host: String) -> [String] {
        if host.allSatisfy({ $0.isNumber || $0 == "." }) { return [host] }
        let labels = host.split(separator: ".")
        guard labels.count > 2 else { return [host] }
        let start = max(0, labels.count - 5)
        var result = [host]
        for index in max(1, start)..<(labels.count - 1) {
            result.append(labels[index...].joined(separator: "."))
        }
        return result
    }

    static func hash(_ string: String) -> UInt64 {
        SHA256.hash(data: Data(string.utf8)).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
    }
}

public struct ThreatMatch: Sendable, Hashable {
    public var kind: ThreatKind
    /// The entry on the list that matched — a parent of the host, sometimes.
    public var listedHost: String

    public init(kind: ThreatKind, listedHost: String) {
        self.kind = kind
        self.listedHost = listedHost
    }

    public var feed: ThreatFeed { .with(kind: kind) }
}

extension Array where Element == UInt64 {
    fileprivate func containsSorted(_ value: UInt64) -> Bool {
        var low = 0
        var high = count
        while low < high {
            let mid = (low + high) / 2
            if self[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low < count && self[low] == value
    }
}
