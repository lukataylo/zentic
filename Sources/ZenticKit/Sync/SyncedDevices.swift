import Foundation

/// Every other Mac's last known tabs, as fetched, by device id.
///
/// CloudKit hands over changes since the last fetch, never the whole set, so
/// this is kept on disk between launches: without it, a relaunch would show
/// nothing until each other Mac happened to send again.
public struct SyncedDevices: Codable, Sendable, Equatable {
    public private(set) var byID: [String: SyncedDevice] = [:]

    /// A Mac not heard from in this long is not shown: it was most likely
    /// sold, wiped or stopped syncing without saying so, and a list of a
    /// month-old tabs is clutter.
    public static let staleAfter: TimeInterval = 30 * 24 * 3600

    public init() {}

    /// A device's record arrived. An older copy than the one held — possible
    /// when a fetch and a cached copy race — is ignored.
    public mutating func apply(_ device: SyncedDevice) {
        if let held = byID[device.id], held.modified > device.modified { return }
        byID[device.id] = device
    }

    public mutating func remove(id: String) {
        byID[id] = nil
    }

    /// What to show: other Macs only, with tabs open, heard from recently,
    /// most recently heard from first.
    public func others(than ownID: String, now: Date = .now) -> [SyncedDevice] {
        byID.values
            .filter { $0.id != ownID && $0.tabCount > 0 && now.timeIntervalSince($0.modified) < Self.staleAfter }
            .sorted { ($0.modified, $0.id) > ($1.modified, $1.id) }
    }
}

extension [SyncedDevice] {
    /// Tabs on these devices whose title or address contains `query`, most
    /// recently sent device first, each address once.
    public func tabs(matching query: String, limit: Int) -> [(device: SyncedDevice, tab: SyncedDevice.Tab)] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, limit > 0 else { return [] }
        var seen: Set<URL> = []
        var matches: [(SyncedDevice, SyncedDevice.Tab)] = []
        for device in self {
            for tab in device.allTabs
            where tab.title.localizedCaseInsensitiveContains(q)
                || (tab.url.host() ?? "").localizedCaseInsensitiveContains(q)
            {
                guard seen.insert(tab.url).inserted else { continue }
                matches.append((device, tab))
                if matches.count == limit { return matches }
            }
        }
        return matches
    }
}

/// When to send this Mac's tabs after they change.
public enum SyncPacing {
    /// Changes come in bursts (a window of tabs restored, a dozen closed);
    /// wait for the burst to finish.
    public static let settle: TimeInterval = 5
    /// At most one send this often, however busy the user is.
    public static let minimumInterval: TimeInterval = 30

    public static func nextSend(lastSent: Date?, now: Date) -> Date {
        let settled = now.addingTimeInterval(settle)
        guard let lastSent else { return settled }
        return max(settled, lastSent.addingTimeInterval(minimumInterval))
    }
}
