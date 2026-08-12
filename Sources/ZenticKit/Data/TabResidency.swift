import Foundation

/// Which tabs are allowed to keep a live `WKWebView`.
///
/// A `WKWebView` costs 50–100MB once its web content process is warm, so a
/// browser that keeps one per tab dies somewhere around thirty tabs. The fix is
/// to hold at most ``Budget/maxLiveWebViews`` of them and suspend the rest to a
/// snapshot plus restorable state.
///
/// The policy lives here, as a value type with no UI or WebKit dependency, for
/// one reason: eviction order is the kind of thing that is obviously right until
/// it silently starts evicting the tab you are looking at. Kept separate it is
/// exhaustively testable.
public struct TabResidency: Sendable, Equatable {
    public let capacity: Int

    /// Least-recently-used first, most-recently-used last.
    ///
    /// An array rather than a dictionary of timestamps: capacity is single digits,
    /// so the linear scans are free, and array order *is* the LRU order — there is
    /// no separate clock to get out of step with it.
    private var order: [UUID] = []

    public init(capacity: Int = Budget.maxLiveWebViews) {
        precondition(capacity >= 1, "at least the foreground tab must be resident")
        self.capacity = capacity
    }

    /// Resident tabs, least-recently-used first.
    public var resident: [UUID] { order }
    public var count: Int { order.count }
    public func contains(_ id: UUID) -> Bool { order.contains(id) }

    /// Promote `id` to most-recently-used, admitting it if absent.
    ///
    /// - Returns: tabs that must now be suspended, least-recently-used first.
    ///   `id` is never among them — the tab being activated is the one tab that
    ///   cannot be evicted, which is why this is a single operation rather than
    ///   separate `admit` and `trim` calls a caller could get out of order.
    @discardableResult
    public mutating func activate(_ id: UUID) -> [UUID] {
        order.removeAll { $0 == id }
        order.append(id)

        let overflow = order.count - capacity
        guard overflow > 0 else { return [] }

        let evicted = Array(order.prefix(overflow))
        order.removeFirst(overflow)
        return evicted
    }

    /// Drop a tab from residency without evicting anything else — for a tab being
    /// closed, or one that has already been suspended.
    public mutating func remove(_ id: UUID) {
        order.removeAll { $0 == id }
    }

    /// Evict everything, e.g. on a memory-pressure warning.
    public mutating func drain() -> [UUID] {
        defer { order.removeAll() }
        return order
    }
}

/// Everything needed to rebuild a tab's web view as the user left it.
///
/// This is the round-trip contract for suspension. It is a plain value so a test
/// can assert "capture, persist, reload, restore" without a window on screen.
public struct SuspendedTabState: Codable, Sendable, Hashable {
    public var urlString: String
    public var title: String
    public var scrollY: Double
    public var canGoBack: Bool
    public var canGoForward: Bool
    /// `WKWebView.interactionState`. Opaque to us; nil is a supported state.
    public var interactionState: Data?
    /// JPEG shown as a placeholder while the restored web view loads.
    public var snapshotData: Data?

    public init(
        urlString: String,
        title: String = "",
        scrollY: Double = 0,
        canGoBack: Bool = false,
        canGoForward: Bool = false,
        interactionState: Data? = nil,
        snapshotData: Data? = nil
    ) {
        self.urlString = urlString
        self.title = title
        self.scrollY = scrollY
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.interactionState = interactionState
        self.snapshotData = snapshotData
    }
}

extension Tab {
    /// The suspended form of this tab.
    public var suspendedState: SuspendedTabState {
        SuspendedTabState(
            urlString: urlString,
            title: title,
            scrollY: scrollY,
            canGoBack: canGoBack,
            canGoForward: canGoForward,
            interactionState: interactionState,
            snapshotData: snapshotData
        )
    }

    /// Persist captured state. Called immediately before the web view is dropped.
    ///
    /// A nil `snapshotData` in `state` keeps whatever snapshot is already stored:
    /// `takeSnapshot` fails on an occluded or still-loading web view, and a stale
    /// snapshot is a far better placeholder than a blank rectangle.
    public func apply(_ state: SuspendedTabState) {
        urlString = state.urlString
        title = state.title
        scrollY = state.scrollY
        canGoBack = state.canGoBack
        canGoForward = state.canGoForward
        interactionState = state.interactionState
        if let snapshot = state.snapshotData {
            snapshotData = snapshot
        }
    }
}
