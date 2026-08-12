import ContentBlockerConverter
import Foundation

/// Limits and thresholds for the blocking layer.
///
/// These are deliberately *not* in ``Budget``, which is a contract shared with the
/// reader and the shell. Two of the numbers here are read off the OS at runtime
/// rather than being constants, so they could not live in an `enum` of
/// `static let`s anyway.
public enum BlockerLimits {
    /// Hard ceiling on entries in one compiled `WKContentRuleList`, as imposed by
    /// the running OS: 150k from Safari 15 on, 50k before that.
    ///
    /// Exceeding it does not raise an error — the converter silently truncates —
    /// so the pipeline splits ahead of time instead of finding out afterwards.
    public static var entriesPerRuleList: Int {
        SafariVersion.autodetect().rulesLimit
    }

    /// How long a downloaded filter list is trusted before ``ContentBlockerService``
    /// bothers to re-ask upstream. EasyList publishes several times a day; daily is
    /// the interval every blocker settled on.
    public static let listMaxAge: TimeInterval = 24 * 60 * 60

    /// Ceiling on a single downloaded list, as a sanity check against a hijacked or
    /// misconfigured URL. EasyList is ~2.5MB; 32MB is absurdly generous and still
    /// bounds memory.
    public static let maxListBytes = 32 * 1024 * 1024

    /// Bump when the on-disk layout or the identifier scheme changes. A mismatch
    /// discards the cache and recompiles rather than migrating: compiled lists are
    /// derived data, and a stale one is worse than a slow first launch.
    public static let cacheSchemaVersion = 1
}
