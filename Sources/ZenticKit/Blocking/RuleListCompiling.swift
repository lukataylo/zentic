import Foundation
import WebKit

/// The one step of the pipeline that needs WebKit.
///
/// It is behind a protocol because `WKContentRuleList` has no public initialiser,
/// so a test cannot produce one — the cache-behaviour tests would otherwise have to
/// drive real WebKit compilation, which takes seconds and leaves state on disk. The
/// associated type keeps the production path returning the real thing rather than an
/// optional or a wrapper.
public protocol RuleListCompiling: Sendable {
    associatedtype CompiledList: Sendable

    /// Already-compiled list with this identifier, or nil if it is not in the store.
    func existing(identifier: String) async -> CompiledList?
    func compile(identifier: String, json: String) async throws -> CompiledList
    /// Everything currently in the store, so identifiers left behind by an older
    /// list version can be removed.
    func identifiers() async -> Set<String>
    func remove(identifier: String) async
}

/// `WKContentRuleListStore`-backed compiler.
///
/// WebKit persists compiled lists itself, keyed by identifier, and its bytecode is
/// not something we can produce or ship — a list can only enter the store by being
/// compiled on the device. That is the whole reason for the identifier-carries-the-
/// content-hash scheme: it turns "has this exact JSON already been compiled?" into a
/// single cheap lookup.
///
/// Every entry point hops to the main actor because `WKContentRuleListStore` is
/// `WK_SWIFT_UI_ACTOR`. That costs nothing: the store's work happens on WebKit's own
/// threads and only the completion lands on the main queue.
public struct WebKitRuleListCompiler: RuleListCompiling {
    public typealias CompiledList = WKContentRuleList

    /// Directory for the rule-list store, or nil for WebKit's default store.
    private let storeURL: URL?

    public init(storeURL: URL? = nil) {
        self.storeURL = storeURL
    }

    public func existing(identifier: String) async -> WKContentRuleList? {
        await lookUp(identifier)
    }

    public func compile(identifier: String, json: String) async throws -> WKContentRuleList {
        try await compileOnMain(identifier, json)
    }

    public func identifiers() async -> Set<String> {
        await identifiersOnMain()
    }

    public func remove(identifier: String) async {
        await removeOnMain(identifier)
    }

    @MainActor
    private func store() -> WKContentRuleListStore {
        if let storeURL {
            return WKContentRuleListStore(url: storeURL)
        }
        return WKContentRuleListStore.default()
    }

    /// A miss is reported as an error rather than a nil list, so it has to be
    /// flattened before a miss can be told apart from a real failure.
    @MainActor
    private func lookUp(_ identifier: String) async -> WKContentRuleList? {
        let store = store()
        return await withCheckedContinuation { continuation in
            store.lookUpContentRuleList(forIdentifier: identifier) { list, _ in
                continuation.resume(returning: list)
            }
        }
    }

    @MainActor
    private func compileOnMain(_ identifier: String, _ json: String) async throws
        -> WKContentRuleList
    {
        let store = store()
        return try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: json
            ) { list, error in
                if let list {
                    continuation.resume(returning: list)
                } else {
                    continuation.resume(
                        throwing: BlockerError.compilationFailed(
                            list: identifier,
                            message: error?.localizedDescription ?? "WebKit returned no list"
                        )
                    )
                }
            }
        }
    }

    @MainActor
    private func identifiersOnMain() async -> Set<String> {
        let store = store()
        return await withCheckedContinuation { continuation in
            store.getAvailableContentRuleListIdentifiers { identifiers in
                continuation.resume(returning: Set(identifiers ?? []))
            }
        }
    }

    @MainActor
    private func removeOnMain(_ identifier: String) async {
        let store = store()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.removeContentRuleList(forIdentifier: identifier) { _ in
                continuation.resume()
            }
        }
    }
}
