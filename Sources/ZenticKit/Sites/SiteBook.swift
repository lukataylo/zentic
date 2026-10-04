import Foundation

/// Every site's chosen mode and custom version, plus the default for sites the
/// user has never touched.
///
/// A value type so it is trivially testable and serialisable; the app holds one
/// and saves it whenever it changes.
public struct SiteBook: Codable, Sendable, Hashable {
    public var defaultMode: SiteMode
    public var sites: [String: SiteSettings]

    public init(defaultMode: SiteMode = .clean, sites: [String: SiteSettings] = [:]) {
        self.defaultMode = defaultMode
        self.sites = sites
    }

    /// The mode a page on `key` opens in.
    ///
    /// A site set to Custom with no saved version falls back to the default —
    /// "Custom" over a page nobody customised would be a control lying about
    /// the page.
    public func mode(for key: String?) -> SiteMode {
        guard let key, let settings = sites[key] else { return defaultMode == .custom ? .clean : defaultMode }
        if settings.mode == .custom && settings.custom == nil { return defaultMode == .custom ? .clean : defaultMode }
        return settings.mode
    }

    public func custom(for key: String?) -> CustomVersion? {
        guard let key else { return nil }
        return sites[key]?.custom
    }

    public mutating func setMode(_ mode: SiteMode, for key: String) {
        var settings = sites[key] ?? SiteSettings(mode: mode)
        settings.mode = mode
        sites[key] = settings
        prune(key)
    }

    public mutating func saveCustom(_ version: CustomVersion, for key: String) {
        sites[key] = SiteSettings(mode: .custom, custom: version)
    }

    /// Forget the custom version. The site drops back to the default mode.
    public mutating func removeCustom(for key: String) {
        guard var settings = sites[key] else { return }
        settings.custom = nil
        if settings.mode == .custom { settings.mode = defaultMode == .custom ? .clean : defaultMode }
        sites[key] = settings
        prune(key)
    }

    public mutating func forget(_ key: String) { sites[key] = nil }

    /// This book with a private window's own changes laid over it. A nil
    /// value is a site the window put back to the default, which must win
    /// over the shared choice too.
    public func overlaying(_ overrides: [String: SiteSettings?]) -> SiteBook {
        var book = self
        for (key, settings) in overrides { book.sites[key] = settings }
        return book
    }

    /// What to record in a private window's overrides after `change` is made
    /// to `key` on top of `self`. The shared book itself is never touched.
    public func override(_ key: String, _ change: (inout SiteBook) -> Void) -> SiteSettings? {
        var book = self
        change(&book)
        return book.sites[key]
    }

    /// A site that matches the default and has no custom version carries no
    /// information; keeping it would pin it against a later change of default.
    private mutating func prune(_ key: String) {
        if let s = sites[key], s.custom == nil, s.mode == defaultMode { sites[key] = nil }
    }

    /// What the in-page script needs, for every site that differs from the
    /// default. Encoded as JSON and injected at document-start, so the script
    /// knows a page's mode before the page has painted anything — including
    /// after a redirect to another host, which no Swift-side hook sees in time.
    public func inPageConfig() -> InPageConfig {
        var entries: [String: InPageConfig.Entry] = [:]
        for (key, settings) in sites {
            let mode = self.mode(for: key)
            entries[key] = InPageConfig.Entry(mode: mode, custom: mode == .custom ? settings.custom : nil)
        }
        return InPageConfig(defaultMode: mode(for: nil), sites: entries)
    }
}

/// The per-site table `InPageScript.bootstrap` embeds in every page.
public struct InPageConfig: Codable, Sendable, Hashable {
    public struct Entry: Codable, Sendable, Hashable {
        public var mode: SiteMode
        public var custom: CustomVersion?
    }
    public var defaultMode: SiteMode
    public var sites: [String: Entry]

    /// The per-page config the bundle's `zentic.apply()` takes.
    public static func pageConfig(mode: SiteMode, custom: CustomVersion?) -> [String: Any] {
        var config: [String: Any] = ["mode": mode.rawValue]
        if mode == .custom, let custom {
            config["custom"] = ["base": custom.base.rawValue, "css": custom.css, "hide": custom.hide]
        } else {
            config["custom"] = NSNull()
        }
        return config
    }
}
