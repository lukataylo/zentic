import Foundation
import Observation
import ZenticKit

/// The user's permission decisions for every site, saved in `permissions.json`.
@MainActor
@Observable
final class SitePermissionStore {
    static let shared = SitePermissionStore()

    private(set) var book: PermissionBook {
        didSet {
            guard book != oldValue else { return }
            // Off the main thread and in order: a serial queue, so two quick
            // changes can never land on disk backwards.
            let (file, book) = (file, book)
            writer.async { file.save(book) }
        }
    }

    func set(_ decision: PermissionDecision?, _ permission: SitePermission, for site: String) {
        book.set(decision, permission, for: site)
    }

    func setDefault(_ decision: PermissionDecision, for permission: SitePermission) {
        book.setDefault(decision, for: permission)
    }

    func forget(_ site: String) { book.forget(site) }

    @ObservationIgnored private let file = JSONFile<PermissionBook>(name: "permissions.json")
    @ObservationIgnored private let writer = DispatchQueue(label: "zentic.permissions", qos: .utility)

    private init() {
        // A few hundred bytes, read once, on the first permission question.
        book = file.load() ?? PermissionBook()
    }
}

/// What one window's pages are allowed to do.
///
/// An ordinary window reads and writes the user's decisions. A private
/// window starts from them but keeps its own answers in memory, so "Allow"
/// given in a private window is forgotten with it.
@MainActor
@Observable
final class PermissionScope {
    let isPrivate: Bool
    private var overrides: [String: [SitePermission: PermissionDecision]] = [:]

    init(isPrivate: Bool) { self.isPrivate = isPrivate }

    /// For a tab that has no window yet.
    static let shared = PermissionScope(isPrivate: false)

    var book: PermissionBook {
        let shared = SitePermissionStore.shared.book
        return isPrivate ? shared.overlaying(overrides) : shared
    }

    func decision(_ permission: SitePermission, for site: String?) -> PermissionDecision {
        book.decision(permission, for: site)
    }

    func set(_ decision: PermissionDecision, _ permission: SitePermission, for site: String) {
        if isPrivate {
            overrides[site, default: [:]][permission] = decision
        } else {
            SitePermissionStore.shared.set(decision, permission, for: site)
        }
    }

    /// Whether the site has decisions of its own that `forget` would clear.
    func hasOwnDecisions(for site: String) -> Bool {
        isPrivate ? overrides[site] != nil : SitePermissionStore.shared.book.sites[site] != nil
    }

    /// Back to the defaults. In a private window, only this window's answers
    /// are dropped; the user's own decisions are not this window's to delete.
    func forget(_ site: String) {
        if isPrivate { overrides[site] = nil } else { SitePermissionStore.shared.forget(site) }
    }
}
