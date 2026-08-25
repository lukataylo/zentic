import Foundation
import Testing

@testable import ZenticKit

/// The path matcher, as a contract between the two languages.
///
/// Two implementations decide whether a lens applies to the page in front of the
/// user: ``LensPath`` when the app hands a tab its lens set, and
/// `matchingLenses()` in `web/src/lens/index.ts` on every pass, because a
/// same-document navigation changes the path without asking the app for anything.
///
/// A disagreement between them is the quietest bug in the feature. The app's
/// answer decides what the popover shows and what gets sent down; the page's
/// answer decides what actually runs — and a lens the page filters out produces
/// **no** ``LensReport`` at all, not even a `missed`, so the drift UI cannot
/// explain why the site looks untouched. That is what string equality did to
/// every pattern containing a wildcard segment.
///
/// So the cases live here, the answers are published to
/// `Tests/Fixtures/wire/lens-path-cases.json`, and `web/test/lens/engine.test.ts`
/// drives the TypeScript port over the same table.
@Suite("Lens path contract")
struct LensPathContractTests {

    /// One (pattern, path) pair and what both implementations must say about it.
    struct PathCase: Codable, Sendable {
        var pattern: String
        var path: String
        var matches: Bool
    }

    struct PathCases: Codable, Sendable {
        var cases: [PathCase]
    }

    /// Authored expectations, not recorded behaviour: a table generated from one
    /// implementation would agree with that implementation by construction, which
    /// is precisely the property that is not worth testing.
    static let cases: [PathCase] = [
        // The three scopes the editor's control offers.
        PathCase(pattern: "*", path: "/anything/at/all", matches: true),
        PathCase(pattern: "/watch", path: "/watch", matches: true),
        PathCase(pattern: "/watch", path: "/results", matches: false),

        // The case the whole port exists for: a wildcard stands for one segment,
        // so "pages like this" covers the page it was created on.
        PathCase(pattern: "/posts/*/*", path: "/posts/12345/my-title", matches: true),
        PathCase(pattern: "/posts/*/my-title", path: "/posts/12345/my-title", matches: true),
        PathCase(pattern: "/posts/*", path: "/posts/98765", matches: true),

        // Segment counts must agree: a pattern for a post is not a pattern for the
        // index of posts, in either direction.
        PathCase(pattern: "/posts/*/*", path: "/posts/12345", matches: false),
        PathCase(pattern: "/posts/*", path: "/posts/12345/my-title", matches: false),

        // The root, and a trailing slash — empty segments are dropped on both
        // sides, so "/watch" and "/watch/" are the same page.
        PathCase(pattern: "/", path: "/", matches: true),
        PathCase(pattern: "/", path: "/watch", matches: false),
        PathCase(pattern: "/watch", path: "/watch/", matches: true),
        PathCase(pattern: "/x/*", path: "/x/", matches: false),

        // Paths are case-sensitive; only the host is not.
        PathCase(pattern: "/Watch", path: "/watch", matches: false),

        // Percent-encoding is decoded per segment, on both sides, so a "this page"
        // lens fires on the page it was created on when the path holds a
        // non-ASCII segment.
        PathCase(pattern: "/%E7%8C%AB", path: "/猫", matches: true),
        PathCase(pattern: "/猫", path: "/%E7%8C%AB", matches: true),
        // Decoded *after* the split, so an encoded slash cannot invent a segment
        // boundary and make a one-segment pattern cover a two-segment path.
        PathCase(pattern: "/a%2Fb", path: "/a/b", matches: false),
        // An encoded `*` is a literal asterisk in the path, not a wildcard in the
        // pattern: decoding before the wildcard test would turn a lens for one
        // page into a lens for the whole directory.
        PathCase(pattern: "/a/%2A", path: "/a/*", matches: true),

        // Stored patterns are trimmed before they are read.
        PathCase(pattern: "  *  ", path: "/x", matches: true),
    ]

    @Test("Swift answers the shared table")
    func swiftAgreesWithTheTable() {
        for entry in Self.cases {
            #expect(
                LensPath.matches(pattern: entry.pattern, path: entry.path) == entry.matches,
                "\(entry.pattern) vs \(entry.path)"
            )
        }
    }

    @Test("The table is published for the TypeScript half")
    func tableIsPublished() throws {
        try GoldenFixture.assertMatches(PathCases(cases: Self.cases), named: "lens-path-cases")
    }
}
