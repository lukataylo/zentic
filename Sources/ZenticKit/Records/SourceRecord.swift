import Foundation

/// One thing a site showed the user, normalised so any app can read it.
///
/// The shape is deliberately small and fixed. Generated apps are written against
/// it — the model is shown this schema and nothing site-specific — so a field
/// added here is an API change for every app the user has ever prompted. A
/// site's long tail of attributes does not belong here; an app that needs one
/// is asking for a different record.
public struct SourceRecord: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// A short, authored, timestamped item: a post, reply, comment, status.
        case post
        /// A long-form page the reader extracted.
        case article
        /// Anything else listed by a site: a product, video, event, link.
        case item
    }

    /// The origin it came from, e.g. `https://x.com`.
    public var source: String
    /// The site's own identifier, unique within ``source``.
    public var id: String
    public var kind: Kind
    /// Where the user can see this on the site itself.
    public var url: String?
    public var title: String?
    public var text: String?
    public var author: String?
    public var authorHandle: String?
    /// Remote URL as captured. Apps never see it — see ``MediaCache``.
    public var authorAvatar: String?
    public var publishedAt: Date?
    /// The record this one replies to, within the same source.
    public var parentID: String?
    /// The conversation or thread this belongs to.
    public var threadID: String?
    /// Remote image URLs as captured. Apps never see these either.
    public var media: [String]
    /// Handles this record mentions or replies to — lowercased, no `@`. What lets
    /// an app answer "who is talking to me" without parsing text.
    public var mentions: [String]
    /// Outbound links, expanded (never a shortener like `t.co`). An article's own
    /// ``url`` is not among them.
    public var links: [String]
    /// Numbers the site itself reported — likes, replies, points, views.
    ///
    /// The site's figures, copied verbatim, and stale from the moment they were
    /// captured: apps are told to show ``lastSeen`` beside them. Never derived or
    /// estimated here (invariant 8).
    public var metrics: [String: Double]
    /// When Zentic first and most recently saw it. A record seen again is the same
    /// record with fresher fields, not a duplicate.
    public var firstSeen: Date
    public var lastSeen: Date

    public init(
        source: String,
        id: String,
        kind: Kind,
        url: String? = nil,
        title: String? = nil,
        text: String? = nil,
        author: String? = nil,
        authorHandle: String? = nil,
        authorAvatar: String? = nil,
        publishedAt: Date? = nil,
        parentID: String? = nil,
        threadID: String? = nil,
        media: [String] = [],
        mentions: [String] = [],
        links: [String] = [],
        metrics: [String: Double] = [:],
        firstSeen: Date = .now,
        lastSeen: Date = .now
    ) {
        self.source = source
        self.id = id
        self.kind = kind
        self.url = url
        self.title = title
        self.text = text
        self.author = author
        self.authorHandle = authorHandle
        self.authorAvatar = authorAvatar
        self.publishedAt = publishedAt
        self.parentID = parentID
        self.threadID = threadID
        self.media = media
        self.mentions = mentions
        self.links = links
        self.metrics = metrics
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }

    private enum CodingKeys: String, CodingKey {
        case source, id, kind, url, title, text, author, authorHandle, authorAvatar, publishedAt
        case parentID, threadID, media, mentions, links, metrics, firstSeen, lastSeen
    }

    /// Hand-written so the collections are optional on the way in: a record
    /// stored before a field existed must still decode, or one schema change
    /// would empty every app.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(String.self, forKey: .source)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        authorHandle = try c.decodeIfPresent(String.self, forKey: .authorHandle)
        authorAvatar = try c.decodeIfPresent(String.self, forKey: .authorAvatar)
        publishedAt = try c.decodeIfPresent(Date.self, forKey: .publishedAt)
        parentID = try c.decodeIfPresent(String.self, forKey: .parentID)
        threadID = try c.decodeIfPresent(String.self, forKey: .threadID)
        media = try c.decodeIfPresent([String].self, forKey: .media) ?? []
        mentions = try c.decodeIfPresent([String].self, forKey: .mentions) ?? []
        links = try c.decodeIfPresent([String].self, forKey: .links) ?? []
        metrics = try c.decodeIfPresent([String: Double].self, forKey: .metrics) ?? [:]
        firstSeen = try c.decode(Date.self, forKey: .firstSeen)
        lastSeen = try c.decode(Date.self, forKey: .lastSeen)
    }
}

/// A site the user has chosen to keep a database of.
///
/// Opt-in, per origin. Nothing is recorded on a site that is not one of these —
/// the user's bank and mail never enter the library unless they put them there.
public struct Source: Codable, Sendable, Hashable, Identifiable {
    public enum Refresh: String, Codable, Sendable {
        /// Updated only by the user's own browsing. The only safe policy for a
        /// signed-in site: automated visits under someone's session are exactly
        /// the pattern that gets accounts locked.
        case browse
        /// Also revisited in the background, signed out, by a throwaway web view
        /// with no cookies. For public sites, where there is no session to risk.
        case background
        /// Also revisited in the background *with the user's session*, scrolled a
        /// little like a person reading, so a signed-in site keeps filling while
        /// the user is elsewhere. Never a default: a site may treat any automated
        /// visit to an account as a breach of its terms. The user turns it on per
        /// source, past a warning, and ``RefreshSchedule`` keeps it paced and capped.
        case session
    }

    public var id: String { origin }
    public var origin: String
    public var title: String
    /// The page the source was added from, and the one background refresh revisits.
    public var homeURL: String
    public var refresh: Refresh
    public var addedAt: Date
    public var lastCapturedAt: Date?
    /// How the site's JSON maps to records. Nil until the first recipe exists.
    public var recipe: SourceRecipe?

    public init(
        origin: String,
        title: String,
        homeURL: String,
        refresh: Refresh,
        addedAt: Date = .now,
        lastCapturedAt: Date? = nil,
        recipe: SourceRecipe? = nil
    ) {
        self.origin = origin
        self.title = title
        self.homeURL = homeURL
        self.refresh = refresh
        self.addedAt = addedAt
        self.lastCapturedAt = lastCapturedAt
        self.recipe = recipe
    }
}

/// What an app asks the library for.
///
/// Decoded from the app's own request, so every field is treated as hostile:
/// the scheme handler intersects ``sources`` with the app's declared sources and
/// ``RecordStore`` clamps ``limit``.
public struct RecordQuery: Codable, Sendable, Hashable {
    public enum Order: String, Codable, Sendable {
        case newest, oldest
    }

    public var sources: [String]?
    public var kinds: [SourceRecord.Kind]?
    public var since: Date?
    public var until: Date?
    /// Case-insensitive substring over title, text and author.
    public var search: String?
    public var threadID: String?
    public var authorHandle: String?
    /// Records talking to this handle: ones that mention it, or reply to one of
    /// its records. What an inbox needs, answered by the store rather than by an
    /// app downloading everything to filter it.
    public var addressedTo: String?
    public var limit: Int?
    public var offset: Int?
    public var order: Order?

    public init(
        sources: [String]? = nil,
        kinds: [SourceRecord.Kind]? = nil,
        since: Date? = nil,
        until: Date? = nil,
        search: String? = nil,
        threadID: String? = nil,
        authorHandle: String? = nil,
        addressedTo: String? = nil,
        limit: Int? = nil,
        offset: Int? = nil,
        order: Order? = nil
    ) {
        self.sources = sources
        self.kinds = kinds
        self.since = since
        self.until = until
        self.search = search
        self.threadID = threadID
        self.authorHandle = authorHandle
        self.addressedTo = addressedTo
        self.limit = limit
        self.offset = offset
        self.order = order
    }
}
