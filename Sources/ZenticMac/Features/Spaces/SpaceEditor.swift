import SwiftUI

/// A space being made or edited, until the sheet is confirmed.
struct SpaceDraft: Identifiable {
    let id = UUID()
    /// The space being edited; nil for a new one.
    var editing: UUID?
    var name: String
    var icon: String
    var tint: SidebarTint

    /// A new space, starting from an icon and tint no other space uses, so
    /// two spaces never look alike by default.
    @MainActor init(newIn browser: Browser) {
        editing = nil
        name = ""
        let usedIcons = Set(browser.spaces.map(\.icon))
        let usedTints = Set(browser.spaces.map(\.tint))
        icon = SpaceEditor.symbols.first { !usedIcons.contains($0.key) }?.key ?? "circle"
        tint = SidebarTint.allCases.first { !usedTints.contains($0) } ?? .indigo
    }

    @MainActor init(editing space: Space) {
        editing = space.id
        name = space.name
        icon = space.icon
        tint = space.tint
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    @MainActor func commit(to browser: Browser) {
        guard !trimmedName.isEmpty else { return }
        if let editing, let space = browser.spaces.first(where: { $0.id == editing }) {
            space.name = trimmedName
            space.icon = icon
            space.tint = tint
            browser.spaceDidChange()
        } else {
            browser.addSpace(name: trimmedName, icon: icon, tint: tint)
        }
    }
}

/// The New Space / Edit Space sheet: a live preview of the space at the top,
/// then its name, icon and colour.
struct SpaceEditor: View {
    @Environment(Browser.self) private var browser
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State var draft: SpaceDraft
    @State private var emoji = ""
    @FocusState private var nameFocused: Bool

    /// The symbols offered, with the names VoiceOver and tooltips use.
    static let symbols: KeyValuePairs = [
        "person.crop.circle": "Person", "briefcase": "Briefcase", "house": "House", "book": "Book",
        "graduationcap": "Graduation Cap", "hammer": "Hammer", "paintpalette": "Palette",
        "music.note": "Music", "gamecontroller": "Game Controller", "cart": "Cart", "airplane": "Airplane",
        "leaf": "Leaf", "heart": "Heart", "star": "Star", "bolt": "Bolt", "flame": "Flame",
        "globe.europe.africa": "Globe", "camera": "Camera", "film": "Film",
        "chart.line.uptrend.xyaxis": "Chart", "terminal": "Terminal", "newspaper": "Newspaper",
        "cup.and.saucer": "Coffee", "moon.stars": "Night",
    ]

    var body: some View {
        VStack(spacing: 0) {
            preview
                .padding(.bottom, 18)

            VStack(alignment: .leading, spacing: 16) {
                TextField("Name", text: $draft.name, prompt: Text("Name your space"))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .focused($nameFocused)
                    .onSubmit(save)

                section("Icon") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 6) {
                        ForEach(Self.symbols, id: \.key) { symbol, name in
                            IconChoice(selected: draft.icon == symbol, tint: draft.tint) {
                                Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                            } action: {
                                draft.icon = symbol
                                emoji = ""
                            }
                            .help(name)
                            .accessibilityLabel(name)
                        }
                    }
                    HStack(spacing: 8) {
                        Text("Or an emoji")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        TextField("Emoji", text: $emoji, prompt: Text("🙂"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 52)
                            .multilineTextAlignment(.center)
                            .onChange(of: emoji) { _, typed in
                                // Keep only the last character typed, and only
                                // if it is not plain text.
                                guard let last = typed.last else { return }
                                let character = String(last)
                                if character.unicodeScalars.contains(where: { !$0.isASCII }) {
                                    draft.icon = character
                                    if emoji != character { emoji = character }
                                } else {
                                    emoji = ""
                                }
                            }
                        Button("Emoji & Symbols") {
                            NSApp.orderFrontCharacterPalette(nil)
                        }
                        .buttonStyle(.link)
                        .font(.callout)
                    }
                    .padding(.top, 4)
                }

                section("Colour") {
                    HStack(spacing: 10) {
                        ForEach(SidebarTint.allCases) { tint in
                            Button {
                                withAnimation(.smooth(duration: 0.25)) { draft.tint = tint }
                            } label: {
                                Circle()
                                    .fill(LinearGradient(colors: tint.colors(dark: true), startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 22, height: 22)
                                    .overlay { Circle().strokeBorder(.white.opacity(0.15), lineWidth: 0.5) }
                                    .padding(3)
                                    .overlay {
                                        Circle()
                                            .strokeBorder(Color.primary.opacity(0.85), lineWidth: 2)
                                            .opacity(draft.tint == tint ? 1 : 0)
                                    }
                            }
                            .buttonStyle(.plain)
                            .help(tint.title)
                            .accessibilityLabel(tint.title)
                            .accessibilityAddTraits(draft.tint == tint ? .isSelected : [])
                        }
                    }
                }
            }

            HStack {
                if draft.editing == nil {
                    Text("Spaces keep their own pinned and open tabs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(draft.editing == nil ? "Create Space" : "Done", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.trimmedName.isEmpty)
            }
            .padding(.top, 22)
        }
        .padding(22)
        .frame(width: 380)
        .onAppear {
            nameFocused = true
            if draft.icon.unicodeScalars.contains(where: { !$0.isASCII }) { emoji = draft.icon }
        }
    }

    /// The space as the sidebar will show it, washed in its colour.
    private var preview: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return VStack(spacing: 8) {
            SpaceIcon(icon: draft.icon, size: 26)
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 54, height: 54)
                .background(Circle().fill(.white.opacity(0.16)))
                .overlay(Circle().strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
            Text(draft.trimmedName.isEmpty ? (draft.editing == nil ? "New Space" : " ") : draft.trimmedName)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(draft.trimmedName.isEmpty ? 0.55 : 1))
                .lineLimit(1)
                .contentTransition(.opacity)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 118)
        .background {
            ZStack {
                shape.fill(LinearGradient(colors: draft.tint.colors(dark: true), startPoint: .topLeading, endPoint: .bottomTrailing))
                // Light from the corner, in the space's own colour.
                shape.fill(RadialGradient(colors: [draft.tint.accent.opacity(0.45), .clear], center: .topLeading, startRadius: 0, endRadius: 300))
            }
        }
        .overlay { shape.strokeBorder(.white.opacity(0.12), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preview")
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func save() {
        guard !draft.trimmedName.isEmpty else { return }
        let draft = draft
        dismiss()
        // After the sheet has gone, so the switch to the new space is seen.
        DispatchQueue.main.async { draft.commit(to: browser) }
    }
}

private struct IconChoice<Label: View>: View {
    let selected: Bool
    let tint: SidebarTint
    @ViewBuilder var label: Label
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.8))
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            selected
                                ? AnyShapeStyle(LinearGradient(colors: tint.colors(dark: true), startPoint: .topLeading, endPoint: .bottomTrailing))
                                : AnyShapeStyle(Color.primary.opacity(hovering ? 0.09 : 0.05)))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A space's icon: an SF Symbol, or an emoji drawn at the same size.
struct SpaceIcon: View {
    let icon: String
    var size: CGFloat = 13

    var body: some View {
        if icon.unicodeScalars.contains(where: { !$0.isASCII }) {
            Text(icon).font(.system(size: size * 0.95))
        } else {
            Image(systemName: icon).font(.system(size: size, weight: .medium))
        }
    }
}
