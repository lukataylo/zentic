import AppKit
import LocalAuthentication
import Observation
import ZenticKit

/// Saved passwords, app-wide: which accounts exist, the sites never to save
/// for, and the AutoFill preference.
///
/// Holds no secret. Passwords stay in the Keychain and are read only at the
/// moment one is filled, revealed or copied — each behind `unlock` — or to
/// compare after a sign-in while an earlier `unlock` still covers it.
@MainActor
@Observable
final class Passwords {
    static let shared = Passwords()

    /// Every saved account, from the Keychain's attributes alone.
    private(set) var logins: [SavedLogin] = []
    /// Site keys the person said never to save for.
    private(set) var neverSave: [String]

    /// Suggest saved accounts when a sign-in field is focused. Off, nothing is
    /// suggested until the person asks (⇧⌘A); saving is offered either way.
    var autoFill: Bool {
        didSet { DataDirectory.defaults.set(autoFill, forKey: "passwordAutoFill") }
    }

    /// Why the account list could not be read, until a read succeeds.
    private(set) var loadError: (any Error)?

    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private let neverSaveFile = JSONFile<[String]>(name: "password-never-save.json")

    private init() {
        autoFill = DataDirectory.defaults.object(forKey: "passwordAutoFill") as? Bool ?? true
        neverSave = neverSaveFile.load() ?? []
        observeLocking()
    }

    // MARK: Accounts

    /// Read the account list from the Keychain, off the main thread. Lazily:
    /// nothing is asked of the Keychain until a sign-in field or the Settings
    /// pane needs it.
    func loadIfNeeded() async {
        // After a failed read, every caller tries again.
        if loading == nil || loadError != nil { reload() }
        await loading?.value
    }

    /// Read the list again — accounts may have been changed in Keychain Access.
    func reload() {
        let previous = loading
        loading = Task {
            await previous?.value
            do {
                let logins = try await Task.detached(priority: .userInitiated) { try PasswordKeychain.logins() }.value
                self.logins = logins.sorted(by: Self.order)
                loadError = nil
            } catch {
                // A locked keychain (after wake, say) is not an empty one:
                // keep what is known, say why, and let the next sign-in field
                // try again rather than offering nothing all session.
                loadError = error
            }
        }
    }

    func suggestions(for origin: LoginOrigin?) -> [SavedLogin] {
        PasswordPolicy.suggestions(logins, for: origin)
    }

    /// What to ask after a sign-in on `origin`. Reads stored passwords, off the
    /// main thread, only for this origin's accounts, only to compare — and only
    /// inside the grace period of an `unlock` the person already gave (a fill
    /// just before signing in is one). Otherwise no secret is read: a sign-in
    /// to a saved account is taken as the same password, so an ordinary sign-in
    /// neither decrypts every account on the site nor raises a Keychain prompt
    /// nobody asked for. A new account is offered either way.
    func offer(origin: LoginOrigin, username: String, password: String, isPrivate: Bool) async -> PasswordOffer? {
        guard !isPrivate else { return nil }
        await loadIfNeeded()
        let (saved, never, unlocked) = (logins.filter { $0.origin == origin }, Set(neverSave), isUnlocked)
        return await Task.detached(priority: .userInitiated) {
            PasswordPolicy.offer(
                origin: origin, username: username, password: password, saved: saved,
                stored: { unlocked ? PasswordKeychain.password(for: $0) : password },
                neverSave: never, isPrivate: false)
        }.value
    }

    func save(_ password: String, for login: SavedLogin) async throws {
        try await Task.detached { try PasswordKeychain.save(password, for: login) }.value
        insert(login)
    }

    func edit(_ login: SavedLogin, username: String, password: String) async throws {
        try await Task.detached { try PasswordKeychain.edit(login, username: username, password: password) }.value
        logins.removeAll { $0 == login }
        insert(SavedLogin(origin: login.origin, username: username))
    }

    private func insert(_ login: SavedLogin) {
        guard !logins.contains(login) else { return }
        logins.append(login)
        logins.sort(by: Self.order)
    }

    private static func order(_ a: SavedLogin, _ b: SavedLogin) -> Bool {
        (a.origin, a.username) < (b.origin, b.username)
    }

    func delete(_ login: SavedLogin) async throws {
        try await Task.detached { try PasswordKeychain.delete(login) }.value
        logins.removeAll { $0 == login }
    }

    /// The password for `login`, after the person has proved they are here.
    ///
    /// - Parameter reason: completes "Zentic is trying to …" in the system's
    ///   Touch ID or password sheet.
    func password(for login: SavedLogin, reason: String) async -> String? {
        guard await unlock(reason: reason) else { return nil }
        return await Task.detached(priority: .userInitiated) { PasswordKeychain.password(for: login) }.value
    }

    // MARK: Never save

    func neverSave(_ siteKey: String) {
        guard !neverSave.contains(siteKey) else { return }
        neverSave.append(siteKey)
        neverSave.sort()
        persistNeverSave()
    }

    func allowSaving(_ siteKey: String) {
        neverSave.removeAll { $0 == siteKey }
        persistNeverSave()
    }

    private func persistNeverSave() {
        let (file, list) = (neverSaveFile, neverSave)
        Task.detached(priority: .utility) { file.save(list) }
    }

    // MARK: Local authentication

    /// How long one Touch ID or password check covers further reads. Long
    /// enough to fill, then copy, then reveal without asking three times;
    /// short enough that a Mac left unlocked does not stay open.
    static let unlockGrace: Duration = .seconds(120)

    @ObservationIgnored private var unlockedAt: ContinuousClock.Instant?
    @ObservationIgnored private var unlocking: Task<Bool, Never>?

    /// Whether an `unlock` given within the grace period still covers a read.
    private var isUnlocked: Bool {
        unlockedAt.map { ContinuousClock.now - $0 < Self.unlockGrace } ?? false
    }

    /// Ask for Touch ID or the login password, unless asked within the grace
    /// period. Concurrent requests share one prompt.
    func unlock(reason: String) async -> Bool {
        if isUnlocked { return true }
        if let unlocking { return await unlocking.value }
        let task = Task { () -> Bool in
            let context = LAContext()
            var error: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
            return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
        }
        unlocking = task
        let granted = await task.value
        unlocking = nil
        if granted { unlockedAt = .now }
        return granted
    }

    /// Lock again the moment the Mac sleeps or its screen locks: the grace
    /// period is for the person who just authenticated, not whoever sits down next.
    private func observeLocking() {
        let lock: @Sendable (Notification) -> Void = { _ in Task { @MainActor in Passwords.shared.unlockedAt = nil } }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: lock)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main, using: lock)
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main, using: lock)
    }
}

extension Passwords {
    /// Put a password on the clipboard marked as concealed, so clipboard
    /// managers that honour the convention skip it, and take it off again
    /// after a minute if nothing else has been copied since.
    static func copyToPasteboard(_ password: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(password, forType: .string)
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let change = pasteboard.changeCount
        Task {
            try? await Task.sleep(for: .seconds(60))
            if NSPasteboard.general.changeCount == change { NSPasteboard.general.clearContents() }
        }
    }
}
