import Foundation

/// The library's limits, in one place: several are safety limits rather than
/// tuning knobs, and changing one in isolation would quietly break another.
public enum LibraryBudget {
    /// Largest response body the recorder forwards. A timeline page is a few
    /// hundred kilobytes; anything past this is a bundle or a blob, not records.
    public static let maxCaptureBytes: Int = 4_000_000

    /// Raw responses kept per source for re-mapping when a recipe is fixed.
    public static let rawResponsesPerSource: Int = 300

    /// Most records one app query may return.
    public static let appQueryLimit: Int = 1_000

    /// Example records per source shown to the model when an app is generated —
    /// the user's own content, sent only at generation time and only for the
    /// sources the app reads. Enough to size a layout to real data; not a dump.
    public static let appSampleRecords: Int = 5

    /// Longest sample text sent with them, in characters.
    public static let appSampleTextLength: Int = 400

    /// How often public sources are revisited in the background, signed out.
    public static let sourceRefreshInterval: Duration = .seconds(30 * 60)

    /// How long a background refresh may keep its throwaway web view alive.
    public static let sourceRefreshLoadBudget: Duration = .seconds(20)

    /// How often a signed-in source the user opted in is revisited, before jitter.
    /// Slower than signed-out refresh: this is somebody's account.
    public static let sessionRefreshInterval: TimeInterval = 45 * 60

    /// Most signed-in visits to one source in a day, however the interval falls.
    public static let sessionVisitsPerDay: Int = 16

    /// Screens scrolled per signed-in visit, and the pause between them — the pace
    /// of someone glancing down a feed, not of a crawler.
    public static let sessionScrollSteps: Int = 4
    public static let sessionScrollPause: ClosedRange<Double> = 2.5...6.0

    /// How long a signed-in visit may keep its web view, scrolling included.
    public static let sessionVisitBudget: Duration = .seconds(60)

    /// A source not captured from in this long is shown as stale on its badge.
    public static let staleSourceAge: TimeInterval = 24 * 60 * 60

    /// Largest image the media cache stores. Avatars and post images, not video.
    public static let maxCachedImageBytes: Int = 3_000_000

    /// Images cached per captured record — the avatar plus the first few media.
    public static let cachedMediaPerRecord: Int = 4

    /// Model calls recipe inference may make per source per day. Every endpoint
    /// a site has is a potential call, and a page can invent endpoints.
    public static let recipeInferencesPerSourcePerDay: Int = 12

    /// How long a model's "this endpoint holds no records" verdict stands.
    public static let recipeVerdictMaxAge: TimeInterval = 7 * 24 * 60 * 60

    /// Consecutive empty mappings, from an endpoint that used to yield records,
    /// that mean the site changed shape and the recipe should be re-inferred.
    public static let staleRecipeStreak: Int = 3

    /// Responses smaller than this do not count towards a stale streak: an empty
    /// page of results is not evidence that the recipe broke.
    public static let staleRecipeMinBytes: Int = 8_000

    /// Largest generated app accepted, in bytes. A single designed page is tens of
    /// kilobytes; anything far past this is a model that lost the plot.
    public static let maxAppHTMLBytes: Int = 400_000
}

/// JSON as the library stores and serves it: ISO-8601 dates, sorted keys, so
/// what an app reads is stable and what a test compares is deterministic.
public enum LibraryCoding {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            // Apps send dates from `toISOString()`, with milliseconds; the store
            // writes them without. Both are the same instant.
            let string = try decoder.singleValueContainer().decode(String.self)
            guard let date = DateParsing.parse(string) ?? ISO8601DateFormatter().date(from: string) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a date: \(string)"))
            }
            return date
        }
        return decoder
    }
}
