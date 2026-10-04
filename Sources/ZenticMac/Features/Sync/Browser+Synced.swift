import Foundation
import ZenticKit

extension Browser {
    /// A tab from another Mac: the tab already showing it in this space if
    /// there is one, else a new tab beside the current one.
    func open(_ synced: SyncedDevice.Tab) {
        if let existing = space.allTabs.first(where: { $0.url == synced.url }) {
            select(existing)
        } else {
            insert(Tab(url: synced.url, title: synced.title), after: selectedTab, select: true)
        }
    }

    /// Everything another Mac has open, as a new space named after it. Only
    /// the first tab loads; the rest wait, asleep, until they are shown.
    func openAll(from device: SyncedDevice) {
        guard !isPrivate else { return }
        let tabs = device.allTabs
        guard let first = tabs.first else { return }
        addSpace(name: device.name, icon: device.kind.symbol, tint: .graphite)
        // New tabs go to the top of a space, so insert from the bottom up.
        // Titled from the other Mac, so the asleep ones read as more than hosts.
        for synced in tabs.dropFirst().reversed() {
            insert(Tab(url: synced.url, title: synced.title), after: nil, select: false)
        }
        insert(Tab(url: first.url, title: first.title), after: nil, select: true)
    }
}
