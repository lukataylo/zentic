import AppKit
import SwiftUI
import ZenticKit

/// The amber of "worth a look": a site changed under a kept version. Not red —
/// nothing is broken that the user cannot see for themselves, and Original is
/// one click away. Deeper in light mode, where bright amber is too faint to
/// read as text.
extension Color {
    static let drift = Color(
        nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 1.0, green: 0.68, blue: 0.20, alpha: 1)
                : NSColor(srgbRed: 0.86, green: 0.47, blue: 0.0, alpha: 1)
        })
}

/// A small amber dot, pinned to the mode glyph's corner while the version on
/// the page has drifted. Ringed in the toolbar's glass so it reads on any page.
struct DriftDot: View {
    var size: CGFloat = 6
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Circle()
            .fill(Color.drift.gradient)
            .frame(width: size, height: size)
            .padding(1.25)
            .background(Circle().fill(scheme == .dark ? Color(white: 0.13) : Color(white: 0.97)))
            .accessibilityHidden(true)
    }
}

/// Under the Custom row of the mode picker, while the version has drifted:
/// the two honest ways forward.
struct DriftActions: View {
    @Environment(Browser.self) private var browser
    let tab: Tab
    let drift: Drift
    let version: CustomVersion

    var body: some View {
        // Aligned under the row's title, the primary action first — it reads
        // as the row's own follow-up rather than a separate dialog.
        HStack(spacing: 8) {
            Button {
                browser.modePickerPresented = false
                tab.design.repair(on: tab, drift: drift)
            } label: {
                Label("Repair…", systemImage: "wand.and.sparkles")
            }
            .buttonStyle(.borderedProminent)
            .tint(.drift)
            .help("Fit your version to the site’s new layout. You’ll see a preview — nothing is saved until you keep it. (⇧⌥⌘E)")
            Button("Turn Off") {
                browser.choose(version.base == .minimal ? .minimal : .clean)
                browser.modePickerPresented = false
            }
            .help("Show this site in \(version.base == .minimal ? "Minimal" : "Clean"). Your version is kept for later.")
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .padding(.leading, 49)
        .padding(.trailing, 8)
        .padding(.top, 2)
        .padding(.bottom, 4)
    }
}

/// The Custom row's detail while drifted: what changed, in amber.
struct DriftReason: View {
    let drift: Drift

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9.5, weight: .semibold))
                .imageScale(.small)
            Text(drift.reasons.first ?? "")
                .multilineTextAlignment(.leading)
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(Color.drift)
        .lineLimit(2)
        .help(drift.reasons.joined(separator: ". ") + ".")
    }
}

/// For the Sites list in Settings.
struct NeedsRepairBadge: View {
    var body: some View {
        Text("Needs Repair")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.drift)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.drift.opacity(0.14)))
            .help("This site has changed since you kept your version. Repair it from the site’s mode picker.")
    }
}

/// Settings › Intelligence.
struct RecheckSettingsSection: View {
    @Bindable private var rechecks = Rechecks.shared

    var body: some View {
        Section {
            Toggle("Notice when a site changes under your version", isOn: $rechecks.isEnabled)
        } footer: {
            Text("After a page with your version loads, Zentic checks — on this Mac, at most every few minutes per site — that the version still fits. If it doesn’t, a dot appears by the site’s mode. Nothing is sent to a model unless you choose Repair.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
