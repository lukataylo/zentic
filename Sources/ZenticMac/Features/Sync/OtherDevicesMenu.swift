import SwiftUI
import ZenticKit

/// History › one submenu per other Mac: its tabs from the keyboard, and the
/// same Open All the sidebar's context menu has.
struct OtherDevicesMenu: View {
    let browser: Browser?

    /// A menu longer than this is a list nobody scans; the sidebar has the rest.
    private static let limit = 30

    var body: some View {
        let devices = TabSync.shared.devices
        if let browser, !browser.isPrivate, !devices.isEmpty {
            Divider()
            Section("Other Devices") {
                ForEach(devices) { device in
                    Menu {
                        ForEach(device.allTabs.prefix(Self.limit), id: \.url) { tab in
                            Button(tab.title.isEmpty ? URLGuess.displayHost(tab.url) : tab.title) { browser.open(tab) }
                        }
                        Divider()
                        Button("Open All in New Space") { browser.openAll(from: device) }
                    } label: {
                        Label(device.name, systemImage: device.kind.symbol)
                    }
                }
            }
        }
    }
}
