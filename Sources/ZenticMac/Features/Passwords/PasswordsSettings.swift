import SwiftUI
import ZenticKit

/// Settings › Passwords: AutoFill, every saved account by site, and the sites
/// never to save for. Passwords are read from the Keychain only to show, copy
/// or edit one, each behind Touch ID or the login password.
struct PasswordsSettings: View {
    @State private var passwords = Passwords.shared
    @State private var query = ""
    /// Passwords on screen right now. Dropped when the pane closes.
    @State private var revealed: [SavedLogin.ID: String] = [:]
    @State private var copied: SavedLogin.ID?
    @State private var editing: EditDraft?
    @State private var deleting: SavedLogin?
    @State private var failure: String?

    var body: some View {
        @Bindable var passwords = passwords
        Form {
            Section {
                Toggle(isOn: $passwords.autoFill) {
                    Text("AutoFill passwords")
                    Text("Suggest saved accounts when you click a sign-in field. Nothing is filled until you pick one, and only on the exact site it was saved for. ⇧⌘A suggests them any time.")
                }
            } footer: {
                Text("Passwords are kept in your login Keychain, where Keychain Access shows them too. Showing, copying or filling one asks for Touch ID or your password.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if passwords.logins.isEmpty && passwords.neverSave.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("No Saved Passwords", systemImage: "key.viewfinder")
                    } description: {
                        Text("When you sign in to a site, Zentic offers to save the password here.")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                }
            } else {
                if !passwords.logins.isEmpty {
                    Section {
                        SearchField(text: $query)
                    }
                }
                ForEach(groups, id: \.origin) { group in
                    Section {
                        ForEach(group.logins) { login in
                            row(login)
                        }
                    } header: {
                        SiteHeader(origin: group.origin)
                    }
                }
                if groups.isEmpty && !query.isEmpty {
                    Section {
                        ContentUnavailableView.search(text: query)
                            .frame(maxWidth: .infinity)
                    }
                }
                if !passwords.neverSave.isEmpty && query.isEmpty {
                    Section {
                        ForEach(passwords.neverSave, id: \.self) { site in
                            NeverSaveRow(site: site) { passwords.allowSaving(site) }
                        }
                    } header: {
                        Text("Never Saved")
                    } footer: {
                        Text("Zentic doesn’t offer to save passwords for these sites.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 500)
        .animation(.smooth(duration: 0.25), value: passwords.logins)
        .animation(.smooth(duration: 0.25), value: passwords.neverSave)
        .onAppear { passwords.reload() }
        .onDisappear { revealed = [:] }
        .sheet(item: $editing) { draft in
            EditSheet(draft: draft) { username, password in
                try await passwords.edit(draft.login, username: username, password: password)
                revealed[draft.login.id] = nil
            }
        }
        .confirmationDialog(
            deleting.map { "Delete the password for \(Self.name($0)) on \($0.origin.displayName)?" } ?? "",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button("Delete", role: .destructive) {
                guard let login = deleting else { return }
                Task {
                    do { try await passwords.delete(login) } catch { failure = error.localizedDescription }
                }
            }
        } message: {
            Text("It’s removed from your Keychain. This can’t be undone.")
        }
        .alert("Couldn’t Delete the Password", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
        } message: {
            Text(failure ?? "")
        }
    }

    private func row(_ login: SavedLogin) -> some View {
        LoginRow(
            login: login, shown: revealed[login.id], copied: copied == login.id,
            toggleReveal: { toggleReveal(login) },
            copy: { copy(login) },
            copyUsername: { Self.copyUsername(login) },
            edit: { edit(login) },
            delete: { deleting = login })
    }

    // MARK: Grouping

    private struct Group {
        var origin: LoginOrigin
        var logins: [SavedLogin]
    }

    private var groups: [Group] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let matching = passwords.logins.filter { login in
            needle.isEmpty || login.origin.host.localizedCaseInsensitiveContains(needle)
                || login.username.localizedCaseInsensitiveContains(needle)
        }
        return Dictionary(grouping: matching, by: \.origin)
            .map { Group(origin: $0.key, logins: $0.value) }
            .sorted { $0.origin < $1.origin }
    }

    // MARK: Actions

    private func toggleReveal(_ login: SavedLogin) {
        if revealed[login.id] != nil { return revealed[login.id] = nil }
        Task {
            if let password = await passwords.password(for: login, reason: "show your password for \(login.origin.displayName)") {
                revealed[login.id] = password
            }
        }
    }

    private func copy(_ login: SavedLogin) {
        Task {
            let password: String? =
                if let shown = revealed[login.id] { shown } else {
                    await passwords.password(for: login, reason: "copy your password for \(login.origin.displayName)")
                }
            guard let password else { return }
            Passwords.copyToPasteboard(password)
            copied = login.id
            try? await Task.sleep(for: .seconds(1.5))
            if copied == login.id { copied = nil }
        }
    }

    private static func copyUsername(_ login: SavedLogin) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(login.username, forType: .string)
    }

    private func edit(_ login: SavedLogin) {
        Task {
            guard let password = await passwords.password(for: login, reason: "edit your password for \(login.origin.displayName)")
            else { return }
            editing = EditDraft(login: login, password: password)
        }
    }

    static func name(_ login: SavedLogin) -> String {
        login.username.isEmpty ? "the account with no username" : login.username
    }
}

// MARK: - Rows

private struct SiteHeader: View {
    let origin: LoginOrigin

    var body: some View {
        HStack(spacing: 7) {
            SiteIcon(image: Favicons.shared.cached(for: URL(string: origin.serialized)), size: 14)
            Text(origin.displayName)
        }
    }
}

private struct LoginRow: View {
    let login: SavedLogin
    let shown: String?
    let copied: Bool
    var toggleReveal: () -> Void
    var copy: () -> Void
    var copyUsername: () -> Void
    var edit: () -> Void
    var delete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(login.username.isEmpty ? "No username" : login.username)
                    .foregroundStyle(login.username.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Group {
                    if let shown {
                        Text(verbatim: shown)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text(verbatim: "••••••••••")
                            .font(.callout)
                            .kerning(1.5)
                            .accessibilityLabel("Password hidden")
                    }
                }
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
            }
            Spacer(minLength: 8)

            Button(action: toggleReveal) {
                Image(systemName: shown == nil ? "eye" : "eye.slash")
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 22, height: 22)
            }
            .help(shown == nil ? "Show Password" : "Hide Password")
            .accessibilityLabel(shown == nil ? "Show Password" : "Hide Password")

            Button(action: copy) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(copied ? AnyShapeStyle(Color.green) : AnyShapeStyle(.secondary))
                    .frame(width: 22, height: 22)
            }
            .help("Copy Password")
            .accessibilityLabel(copied ? "Copied" : "Copy Password")

            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .menuStyle(.button)
            .fixedSize()
            .help("More")
            .accessibilityLabel("More Actions")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .padding(.vertical, 2)
        .animation(.smooth(duration: 0.2), value: shown)
        .animation(.smooth(duration: 0.2), value: copied)
        .contextMenu { actions }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var actions: some View {
        Button("Copy Username", action: copyUsername).disabled(login.username.isEmpty)
        Button("Copy Password", action: copy)
        Button(shown == nil ? "Show Password" : "Hide Password", action: toggleReveal)
        Divider()
        Button("Edit…", action: edit)
        Button("Delete…", role: .destructive, action: delete)
    }
}

private struct NeverSaveRow: View {
    let site: String
    var allow: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            SiteIcon(image: Favicons.shared.cached(for: URL(string: "https://\(site)")), size: 16)
            Text(site)
            Spacer()
            Button("Allow Saving", action: allow)
                .buttonStyle(.borderless)
                .help("Offer to save passwords for \(site) again")
        }
    }
}

private struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search", text: $text, prompt: Text("Search sites and usernames"))
                .textFieldStyle(.plain)
                .labelsHidden()
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Clear")
                .accessibilityLabel("Clear Search")
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: text.isEmpty)
    }
}

// MARK: - Edit

private struct EditDraft: Identifiable {
    let login: SavedLogin
    let password: String
    var id: SavedLogin.ID { login.id }
}

private struct EditSheet: View {
    let draft: EditDraft
    var save: (String, String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var showsPassword = false
    @State private var saving = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                SiteIcon(image: Favicons.shared.cached(for: URL(string: draft.login.origin.serialized)), size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Edit Password").font(.headline)
                    Text(draft.login.origin.displayName).font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding([.horizontal, .top], 20)

            Form {
                TextField("Username", text: $username)
                LabeledContent("Password") {
                    HStack(spacing: 6) {
                        Group {
                            if showsPassword {
                                TextField("Password", text: $password)
                            } else {
                                SecureField("Password", text: $password)
                            }
                        }
                        .labelsHidden()
                        .font(.body.monospaced())
                        Button {
                            showsPassword.toggle()
                        } label: {
                            Image(systemName: showsPassword ? "eye.slash" : "eye")
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.borderless)
                        .help(showsPassword ? "Hide Password" : "Show Password")
                    }
                }
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: failure == nil ? 130 : 170)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || saving || !changed)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 400)
        .onAppear {
            username = draft.login.username
            password = draft.password
        }
    }

    private var trimmedUsername: String { username.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var changed: Bool { trimmedUsername != draft.login.username || password != draft.password }

    private func commit() {
        saving = true
        Task {
            defer { saving = false }
            do {
                try await save(trimmedUsername, password)
                dismiss()
            } catch {
                withAnimation { failure = error.localizedDescription }
            }
        }
    }
}
