import Foundation

/// How one site's JSON becomes ``SourceRecord``s.
///
/// Inferred once per endpoint by a model that is shown the response's *shape* —
/// keys, types and lengths, never values (see ``ShapeSummary``) — or shipped
/// curated, as X's is. Applied thereafter by ``RecordMapper``, locally and
/// deterministically: the model is consulted when a site changes shape, not
/// when the user reads it.
public struct SourceRecipe: Codable, Sendable, Hashable {
    public enum Provenance: String, Codable, Sendable {
        case curated, inferred
    }

    public var origin: String
    public var endpoints: [EndpointRecipe]
    public var provenance: Provenance
    public var generatedAt: Date
    /// Hosts besides the source's own site that its images may be cached from —
    /// a CDN like `pbs.twimg.com`. Curated only: an inferred recipe gets the
    /// source's own site and nothing else, so a site's JSON cannot point the media
    /// cache at an arbitrary host.
    public var mediaHosts: [String]

    public init(
        origin: String,
        endpoints: [EndpointRecipe],
        provenance: Provenance,
        generatedAt: Date = .now,
        mediaHosts: [String] = []
    ) {
        self.origin = origin
        self.endpoints = endpoints
        self.provenance = provenance
        self.generatedAt = generatedAt
        self.mediaHosts = mediaHosts
    }

    private enum CodingKeys: String, CodingKey {
        case origin, endpoints, provenance, generatedAt, mediaHosts
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        origin = try c.decode(String.self, forKey: .origin)
        endpoints = try c.decode([EndpointRecipe].self, forKey: .endpoints)
        provenance = try c.decode(Provenance.self, forKey: .provenance)
        generatedAt = try c.decode(Date.self, forKey: .generatedAt)
        mediaHosts = try c.decodeIfPresent([String].self, forKey: .mediaHosts) ?? []
    }

    /// The recipe for a response, preferring an exact endpoint over the wildcard.
    public func endpoint(for key: String) -> EndpointRecipe? {
        endpoints.first { $0.endpoint == key } ?? endpoints.first { $0.endpoint == "*" }
    }
}

/// The mapping for one endpoint.
public struct EndpointRecipe: Codable, Sendable, Hashable {
    /// An ``EndpointKey``, or `*` for every response from the origin.
    public var endpoint: String
    /// Where the items are. Nil records a verdict — "this endpoint holds no
    /// records" — so a badge-count or settings response is not re-inferred on
    /// every page load.
    public var items: String?
    /// Paths tried in order on each item; the first that yields an object
    /// replaces it. Unwraps reposts to the original and visibility wrappers to
    /// their content.
    public var unwrap: [String]
    public var kind: SourceRecord.Kind
    public var fields: FieldMap
    /// When a model produced this. Nil for curated recipes. A "no records here"
    /// verdict expires (``LibraryBudget/recipeVerdictMaxAge``), because the first response
    /// an endpoint returns can be an empty search or an error.
    public var inferredAt: Date?

    public init(
        endpoint: String,
        items: String?,
        unwrap: [String] = [],
        kind: SourceRecord.Kind = .item,
        fields: FieldMap = FieldMap(),
        inferredAt: Date? = nil
    ) {
        self.endpoint = endpoint
        self.items = items
        self.unwrap = unwrap
        self.kind = kind
        self.fields = fields
        self.inferredAt = inferredAt
    }
}

/// Paths from an item to each ``SourceRecord`` field.
///
/// Every field is a list of alternatives, tried in order, because sites migrate
/// fields rather than rename them atomically — X moved display names from
/// `legacy.name` to `core.name` over months, with both live at once.
public struct FieldMap: Codable, Sendable, Hashable {
    public var id: [String]
    public var title: [String]
    public var text: [String]
    public var author: [String]
    public var authorHandle: [String]
    public var authorAvatar: [String]
    public var publishedAt: [String]
    public var url: [String]
    /// `{field}` placeholders filled from the mapped record, for sites whose
    /// items carry no link of their own: `https://x.com/{authorHandle}/status/{id}`.
    public var urlTemplate: String?
    public var parentID: [String]
    public var threadID: [String]
    /// Paths that may select several image URLs each, e.g. `media[*].src`.
    public var media: [String]
    /// Paths to handles mentioned or replied to, e.g. `entities.mentions[*].handle`.
    public var mentions: [String]
    /// Paths to outbound links, expanded, e.g. `entities.urls[*].expanded_url`.
    public var links: [String]
    public var metrics: [Metric]

    public struct Metric: Codable, Sendable, Hashable {
        public var name: String
        public var paths: [String]

        public init(name: String, paths: [String]) {
            self.name = name
            self.paths = paths
        }
    }

    public init(
        id: [String] = [],
        title: [String] = [],
        text: [String] = [],
        author: [String] = [],
        authorHandle: [String] = [],
        authorAvatar: [String] = [],
        publishedAt: [String] = [],
        url: [String] = [],
        urlTemplate: String? = nil,
        parentID: [String] = [],
        threadID: [String] = [],
        media: [String] = [],
        mentions: [String] = [],
        links: [String] = [],
        metrics: [Metric] = []
    ) {
        self.id = id
        self.title = title
        self.text = text
        self.author = author
        self.authorHandle = authorHandle
        self.authorAvatar = authorAvatar
        self.publishedAt = publishedAt
        self.url = url
        self.urlTemplate = urlTemplate
        self.parentID = parentID
        self.threadID = threadID
        self.media = media
        self.mentions = mentions
        self.links = links
        self.metrics = metrics
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, text, author, authorHandle, authorAvatar, publishedAt, url, urlTemplate
        case parentID, threadID, media, mentions, links, metrics
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func paths(_ key: CodingKeys) throws -> [String] { try c.decodeIfPresent([String].self, forKey: key) ?? [] }
        id = try paths(.id)
        title = try paths(.title)
        text = try paths(.text)
        author = try paths(.author)
        authorHandle = try paths(.authorHandle)
        authorAvatar = try paths(.authorAvatar)
        publishedAt = try paths(.publishedAt)
        url = try paths(.url)
        urlTemplate = try c.decodeIfPresent(String.self, forKey: .urlTemplate)
        parentID = try paths(.parentID)
        threadID = try paths(.threadID)
        media = try paths(.media)
        mentions = try paths(.mentions)
        links = try paths(.links)
        metrics = try c.decodeIfPresent([Metric].self, forKey: .metrics) ?? []
    }
}

/// A stable name for "this kind of response", so a recipe outlives the URL.
///
/// Segments that look like identifiers are dropped. X's GraphQL paths carry a
/// query ID that rotates with every deploy — `/i/api/graphql/Xq3…/HomeTimeline` —
/// and a recipe keyed on it would be re-inferred weekly. What survives is the
/// operation name, which is what the response's shape actually depends on.
public enum EndpointKey {
    public static func of(_ url: URL) -> String {
        if url.scheme == "embedded" { return "embedded/\(url.host() ?? "json")" }
        let segments = url.path().split(separator: "/").map(String.init).filter { !looksLikeID($0) }
        return segments.suffix(3).joined(separator: "/").lowercased()
    }

    static func looksLikeID(_ segment: String) -> Bool {
        if segment.allSatisfy(\.isNumber) { return true }
        // Long tokens mixing letters and digits: query hashes, UUIDs, slugs-with-ids.
        guard segment.count >= 12 else { return false }
        let hasDigit = segment.contains(where: \.isNumber)
        let hasLetter = segment.contains(where: \.isLetter)
        let isToken = segment.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return hasDigit && hasLetter && isToken
    }
}

// MARK: - Curated

extension SourceRecipe {
    /// Recipes shipped with the app, for sites where a wrong inference would be
    /// most visible. Everything else is inferred on first capture.
    public static func curated(for origin: String) -> SourceRecipe? {
        switch origin {
        case "https://x.com", "https://twitter.com": x(origin: origin)
        default: nil
        }
    }

    /// X's web client GraphQL. One wildcard endpoint, because the same tweet
    /// object appears in every timeline, thread, search and profile response and
    /// recursive descent finds it wherever it sits.
    ///
    /// Promoted entries carry `promotedMetadata` beside the tweet, on the
    /// `itemContent` that wraps it — so the filter sits there, and an ad is
    /// excluded by construction rather than by a check someone can forget.
    static func x(origin: String) -> SourceRecipe {
        let user = "core.user_results.result"
        return SourceRecipe(
            origin: origin,
            endpoints: [
                EndpointRecipe(
                    endpoint: "*",
                    items: "$..itemContent[?!promotedMetadata].tweet_results.result",
                    unwrap: [
                        // `TweetWithVisibilityResults` wraps the real tweet.
                        "tweet",
                        // A repost: the record is the original, seen via a follow.
                        "legacy.retweeted_status_result.result",
                    ],
                    kind: .post,
                    fields: FieldMap(
                        id: ["rest_id", "legacy.id_str"],
                        text: ["note_tweet.note_tweet_results.result.text", "legacy.full_text"],
                        author: ["\(user).core.name", "\(user).legacy.name"],
                        authorHandle: ["\(user).core.screen_name", "\(user).legacy.screen_name"],
                        authorAvatar: [
                            "\(user).avatar.image_url", "\(user).legacy.profile_image_url_https",
                        ],
                        publishedAt: ["legacy.created_at"],
                        urlTemplate: "https://x.com/{authorHandle}/status/{id}",
                        parentID: ["legacy.in_reply_to_status_id_str"],
                        threadID: ["legacy.conversation_id_str"],
                        media: ["legacy.extended_entities.media[*].media_url_https"],
                        mentions: ["legacy.entities.user_mentions[*].screen_name"],
                        // Expanded, so an app shows `github.com/…` rather than an
                        // opaque `t.co` redirect that X counts on every click.
                        links: ["legacy.entities.urls[*].expanded_url"],
                        metrics: [
                            .init(name: "replies", paths: ["legacy.reply_count"]),
                            .init(name: "reposts", paths: ["legacy.retweet_count"]),
                            .init(name: "likes", paths: ["legacy.favorite_count"]),
                            .init(name: "quotes", paths: ["legacy.quote_count"]),
                            .init(name: "views", paths: ["views.count"]),
                        ]
                    )
                )
            ],
            provenance: .curated,
            generatedAt: Date(timeIntervalSince1970: 1_790_000_000),
            mediaHosts: ["pbs.twimg.com"]
        )
    }
}
