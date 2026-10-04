import Foundation
import Observation
import SwiftUI
import ZenticKit

/// One of a window's spaces: a name, an icon and a tint, its own pinned tabs
/// and open tabs, and which of them was last shown.
///
/// Holds state only. Every change to the tab lists goes through `Browser`,
/// which owns selection, suspension and saving.
@MainActor
@Observable
final class Space: Identifiable {
    let id: UUID
    var name: String
    /// An SF Symbol name, or a single emoji.
    var icon: String
    var tint: SidebarTint
    var pinned: [Tab] = []
    var tabs: [Tab] = []
    var selectedID: UUID?

    init(id: UUID = UUID(), name: String, icon: String, tint: SidebarTint) {
        self.id = id
        self.name = name
        self.icon = icon
        self.tint = tint
    }

    /// Pinned tabs first, as the sidebar lists them.
    var allTabs: [Tab] { pinned + tabs }

    var selected: Tab? {
        guard let selectedID else { return nil }
        return pinned.first { $0.id == selectedID } ?? tabs.first { $0.id == selectedID }
    }

    func contains(_ tab: Tab) -> Bool {
        pinned.contains { $0 === tab } || tabs.contains { $0 === tab }
    }
}

extension SidebarTint {
    /// A saturated mid-tone of the tint, for marks that must read on the
    /// window frame in both appearances — where the wash itself, at high
    /// translucency, is too pale to tell one space from another.
    var accent: Color {
        switch self {
        case .indigo: Color(red: 0.42, green: 0.38, blue: 0.96)
        case .graphite: Color(red: 0.46, green: 0.47, blue: 0.52)
        case .rose: Color(red: 0.90, green: 0.30, blue: 0.50)
        case .forest: Color(red: 0.18, green: 0.62, blue: 0.42)
        case .ocean: Color(red: 0.14, green: 0.52, blue: 0.92)
        case .ember: Color(red: 0.95, green: 0.46, blue: 0.20)
        }
    }
}
