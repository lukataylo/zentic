import SwiftUI
import ZenticKit

/// How this site looks: Original, Clean, Minimal or the user's own version.
/// The choice is remembered for the site.
struct ModePicker: View {
    @Environment(Browser.self) private var browser
    @Environment(AppModel.self) private var app
    let tab: Tab

    var body: some View {
        let custom = app.custom(for: tab.url)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                SiteIcon(image: tab.icon, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tab.displayHost)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text("Remembered for this site")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 10)

            VStack(spacing: 2) {
                ForEach(Array(SiteMode.allCases.enumerated()), id: \.element) { index, mode in
                    ModeRow(
                        mode: mode,
                        shortcut: "⌥⌘\(index + 1)",
                        selected: tab.mode == mode && tab.previewing == nil,
                        reloads: mode.blocks != tab.mode.blocks && !(mode == .custom && custom == nil),
                        detail: mode == .custom ? custom.map { "“\($0.summary)”" } ?? "Describe it in your own words…" : nil
                    ) {
                        browser.choose(mode)
                        if mode != .custom || custom != nil {
                            // Let the checkmark land before the popover leaves.
                            Task {
                                try? await Task.sleep(for: .milliseconds(180))
                                browser.modePickerPresented = false
                            }
                        }
                    }
                }
            }

            if custom != nil {
                HStack(spacing: 8) {
                    Button {
                        browser.modePickerPresented = false
                        tab.design.present()
                    } label: {
                        Label("Refine Your Version", systemImage: "wand.and.sparkles")
                    }
                    Spacer()
                    Button("Remove", role: .destructive) {
                        if let key = tab.siteKey { app.removeCustom(forKey: key) }
                    }
                    .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .padding(.top, 10)
            }

            Divider().padding(.vertical, 10)

            HStack {
                Text("New sites open in")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("New sites open in", selection: Binding(get: { app.defaultMode }, set: { app.defaultMode = $0 })) {
                    ForEach([SiteMode.original, .clean, .minimal]) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .controlSize(.small)
            }
            .padding(.horizontal, 8)
        }
        .padding(12)
        .frame(width: 340)
    }
}

private struct ModeRow: View {
    let mode: SiteMode
    let shortcut: String
    let selected: Bool
    let reloads: Bool
    let detail: String?
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color.primary.opacity(0.07)))
                    Image(systemName: mode.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.8))
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(mode.title)
                            .font(.system(size: 13, weight: .semibold))
                        if reloads {
                            Text("Reloads")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(Color.primary.opacity(0.07)))
                        }
                    }
                    Text(detail ?? mode.subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 6)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Text(shortcut)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .opacity(hovering ? 1 : 0)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.12) : hovering ? Color.primary.opacity(0.05) : .clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.smooth(duration: 0.2), value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A site's icon, or a neutral globe while there is none.
struct SiteIcon: View {
    let image: NSImage?
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "globe")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .fontWeight(.light)
                    .foregroundStyle(.secondary)
                    .padding(size * 0.06)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}
