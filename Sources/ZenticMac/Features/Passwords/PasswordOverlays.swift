import SwiftUI
import ZenticKit

/// What passwords put over a page: the AutoFill menu under a sign-in field,
/// and the save prompt hanging from the toolbar.
struct PasswordOverlays: View {
    let passwords: TabPasswords
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var menuHeight: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if let menu = passwords.menu {
                    SuggestionMenu(menu: menu, passwords: passwords)
                        .frame(width: Self.menuWidth(for: menu.anchor, in: proxy.size))
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self, of: \.size.height) { menuHeight = $0 }
                        .offset(
                            x: Self.menuX(for: menu.anchor, in: proxy.size),
                            y: Self.menuY(for: menu.anchor, height: menuHeight, in: proxy.size))
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .scale(scale: 0.96, anchor: Self.opensUpward(menu.anchor, height: menuHeight, in: proxy.size) ? .bottom : .top)
                                    .combined(with: .opacity))
                }

                if let prompt = passwords.prompt {
                    SavePrompt(prompt: prompt, passwords: passwords)
                        // A new view per offer: an account picked for one
                        // offer must never carry over to the next.
                        .id(prompt.offer)
                        .frame(width: 340)
                        .padding(.top, Metrics.toolbarInset + 8)
                        .padding(.trailing, 12)
                        .frame(maxWidth: .infinity, alignment: .topTrailing)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.98, anchor: .top)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: passwords.menu?.origin)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: passwords.prompt != nil)
        .onDisappear { passwords.closeMenu() }
    }

    /// As wide as the field it belongs to, within reason.
    private static func menuWidth(for anchor: CGRect, in size: CGSize) -> CGFloat {
        min(max(anchor.width, 260), 420, size.width - 24)
    }

    /// Under the field, or over it when a field near the bottom of the window
    /// leaves no room below and there is room above.
    private static func menuY(for anchor: CGRect, height: CGFloat, in size: CGSize) -> CGFloat {
        opensUpward(anchor, height: height, in: size) ? anchor.minY - 6 - height : anchor.maxY + 6
    }

    private static func opensUpward(_ anchor: CGRect, height: CGFloat, in size: CGSize) -> Bool {
        anchor.maxY + 6 + height > size.height - 8 && anchor.minY - 6 - height >= Metrics.toolbarInset
    }

    /// Under the field's leading edge, kept inside the card.
    private static func menuX(for anchor: CGRect, in size: CGSize) -> CGFloat {
        min(max(anchor.minX, 12), size.width - menuWidth(for: anchor, in: size) - 12)
    }
}

// MARK: - Suggestion menu

private struct SuggestionMenu: View {
    let menu: TabPasswords.Menu
    let passwords: TabPasswords

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if menu.insecure {
                InsecureNotice(host: menu.origin.displayName)
            } else if menu.logins.isEmpty {
                Label("No passwords saved for \(menu.origin.displayName)", systemImage: "key.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(10)
            } else {
                Label("Passwords for \(menu.origin.displayName)", systemImage: "key.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
                    .accessibilityAddTraits(.isHeader)
                ForEach(Array(menu.logins.enumerated()), id: \.element.id) { index, login in
                    AccountRow(login: login, highlighted: menu.highlighted == index) {
                        passwords.fill(login)
                    }
                }
            }
        }
        // As wide as the menu's frame, so a notice is not a narrower card
        // centred under the field.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(5)
        .panelGlass(in: .rect(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("AutoFill")
    }
}

private struct AccountRow: View {
    let login: SavedLogin
    let highlighted: Bool
    var choose: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 10) {
                Monogram(text: login.username.isEmpty ? login.origin.host : login.username)
                VStack(alignment: .leading, spacing: 1) {
                    Text(login.username.isEmpty ? "No username" : login.username)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(highlighted ? Color.white : login.username.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(verbatim: "••••••••")
                        .font(.system(size: 10, weight: .semibold))
                        .kerning(1)
                        .foregroundStyle(highlighted ? Color.white.opacity(0.75) : .secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(highlighted ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.07 : 0)))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: highlighted)
        .accessibilityLabel(login.username.isEmpty ? "Account with no username" : login.username)
        .accessibilityHint("Fills this account’s username and password")
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }
}

/// A round initial for an account — the quickest way to tell two apart.
private struct Monogram: View {
    let text: String

    var body: some View {
        let initial = text.first.map { String($0).uppercased() } ?? "?"
        Text(initial)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(Circle().fill(tint.gradient))
            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
            .accessibilityHidden(true)
    }

    /// Stable per name, so an account keeps its colour from one visit to the next.
    private var tint: Color {
        let palette: [Color] = [.indigo, .blue, .teal, .green, .orange, .pink, .purple]
        let sum = text.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[sum % palette.count]
    }
}

private struct InsecureNotice: View {
    let host: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.slash.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.orange)
                .symbolEffect(.bounce, options: .nonRepeating)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text("This page isn’t secure")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(host) doesn’t encrypt what you type, so anyone on the network could read a password entered here. Zentic won’t fill one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Save prompt

private struct SavePrompt: View {
    let prompt: TabPasswords.Prompt
    let passwords: TabPasswords
    @State private var chosenUsername: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Badge(saved: isSaved)
                VStack(alignment: .leading, spacing: 3) {
                    Text(isSaved ? "Saved to your Keychain" : TabPasswords.title(for: offer))
                        .font(.system(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                    detail
                }
                Spacer(minLength: 0)
            }

            if !isSaved {
                HStack(spacing: 8) {
                    if case .save = offer {
                        Button("Never for This Site") { passwords.neverSave(offer) }
                            .buttonStyle(.borderless)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .help("Don’t offer to save passwords for \(offer.origin.siteKey) again")
                    }
                    Spacer()
                    Button("Not Now") { passwords.dismissPrompt() }
                        .controlSize(.regular)
                    Button(isUpdate ? "Update" : "Save") { passwords.save(offer, as: chosenUsername) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                }
                .transition(.opacity)
            }
        }
        .padding(14)
        .panelGlass(in: .rect(cornerRadius: 18, style: .continuous))
        .animation(.smooth(duration: 0.3), value: isSaved)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isSaved ? "Password saved" : TabPasswords.title(for: offer))
    }

    @ViewBuilder
    private var detail: some View {
        switch prompt {
        case .failed(_, let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .saved:
            Text("AutoFill will offer it next time you sign in to \(offer.origin.displayName).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .offer(.update(_, let usernames, _)) where usernames.count > 1:
            Picker("Account", selection: Binding(get: { chosenUsername ?? usernames[0] }, set: { chosenUsername = $0 })) {
                ForEach(usernames, id: \.self) { Text($0.isEmpty ? "No username" : $0).tag($0) }
            }
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        case .offer(let offer):
            HStack(spacing: 6) {
                Text(username(of: offer).isEmpty ? "No username" : username(of: offer))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: "••••••••").kerning(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var offer: PasswordOffer { prompt.offer }

    private var isSaved: Bool {
        if case .saved = prompt { return true }
        return false
    }

    private var isUpdate: Bool {
        if case .update = offer { return true }
        return false
    }

    private func username(of offer: PasswordOffer) -> String {
        switch offer {
        case .save(_, let username, _): username
        case .update(_, let usernames, _): usernames.first ?? ""
        }
    }
}

/// The key in its tinted circle, turning into a check mark once saved.
private struct Badge: View {
    let saved: Bool

    var body: some View {
        Image(systemName: saved ? "checkmark" : "key.fill")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 32, height: 32)
            .background(
                Circle().fill(
                    saved
                        ? AnyShapeStyle(Color.green.gradient)
                        : AnyShapeStyle(LinearGradient(
                            colors: [Color(red: 0.98, green: 0.74, blue: 0.22), Color(red: 0.95, green: 0.55, blue: 0.12)],
                            startPoint: .top, endPoint: .bottom))))
            .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
            .symbolEffect(.bounce, value: saved)
            .accessibilityHidden(true)
    }
}
