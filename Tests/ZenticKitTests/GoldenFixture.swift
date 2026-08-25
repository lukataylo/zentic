import Foundation
import Testing

@testable import ZenticKit

/// Golden-file helper for the JS bridge contract.
///
/// Fixtures under `Tests/Fixtures/wire/` are the single source of truth for the
/// wire format. Swift asserts it *encodes* to them; the TypeScript suite asserts
/// it *decodes* them (`web/test/wire.contract.test.ts`). Either side changing
/// shape unilaterally therefore fails a test, instead of silently breaking pages
/// at runtime — which is the failure mode this exists to prevent.
///
/// Regenerate after an intentional format change:
///
/// ```
/// ZENTIC_UPDATE_FIXTURES=1 swift test
/// ```
///
/// Then review the diff and run `cd web && npm test` to confirm the TypeScript
/// side still parses it.
enum GoldenFixture {
    static var isUpdating: Bool {
        ProcessInfo.processInfo.environment["ZENTIC_UPDATE_FIXTURES"] == "1"
    }

    /// `Tests/Fixtures/wire`, derived from this file's path so it works under
    /// both `swift test` and Xcode without a bundle resource.
    static var directory: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()  // ZenticKitTests
            .deletingLastPathComponent()  // Tests
            .appending(path: "Fixtures/wire")
    }

    /// Assert `value` encodes to the named fixture, or write it when updating.
    static func assertMatches<T: Encodable>(
        _ value: T,
        named name: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let encoder = ZenticCoding.makeEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]

        let encoded = try encoder.encode(value)
        let url = directory.appending(path: "\(name).json")

        if isUpdating {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try encoded.write(to: url)
            return
        }

        guard let existing = try? Data(contentsOf: url) else {
            Issue.record(
                """
                Missing fixture \(name).json. Create it with:
                  ZENTIC_UPDATE_FIXTURES=1 swift test
                Encoded value was:
                \(String(decoding: encoded, as: UTF8.self))
                """,
                sourceLocation: sourceLocation
            )
            return
        }

        // Compare parsed JSON rather than bytes, so trailing-newline and
        // line-ending noise never fails a build.
        //
        // Both sides are *required* to parse as objects rather than defaulted to
        // empty: `as? [String: Any] ?? [:]` would make a truncated or malformed
        // fixture compare equal to a malformed encoding and pass vacuously,
        // turning this guard into decoration.
        let lhs = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
            "encoded value is not a JSON object",
            sourceLocation: sourceLocation
        )
        let rhs = try #require(
            try JSONSerialization.jsonObject(with: existing) as? [String: Any],
            "\(name).json is not a JSON object",
            sourceLocation: sourceLocation
        )

        #expect(
            NSDictionary(dictionary: lhs) == NSDictionary(dictionary: rhs),
            """
            \(name).json is out of date.
            Encoded:
            \(String(decoding: encoded, as: UTF8.self))
            """,
            sourceLocation: sourceLocation
        )
    }
}

/// Deterministic sample values. Dates are fixed so fixtures are stable.
enum Sample {
    static let timestamp = Date(timeIntervalSince1970: 1_754_000_000)

    static let recipe = SiteRecipe(
        origin: "https://example.com",
        pathPattern: "/posts/*",
        archetype: .article,
        contentSelectors: ["article.post", "main"],
        junkSelectors: [".related", ".newsletter-cta"],
        quirks: [.lazyImageAttrs],
        provenance: .curated,
        generatedAt: timestamp
    )

    static let skeleton = DOMSkeleton(
        origin: "https://example.com",
        pathPattern: "/posts/*",
        viewport: .init(width: 1280, height: 900),
        nodes: [
            SkeletonNode(
                tag: "article",
                id: "post",
                classes: ["post", "prose"],
                role: "main",
                path: "body>div:nth-of-type(2)>article",
                depth: 3,
                textLength: 4820,
                linkCount: 7,
                paragraphCount: 24,
                area: 620_000
            )
        ]
    )

    static let extraction = ExtractionResult(
        url: "https://example.com/posts/123/hello",
        archetype: .article,
        title: "Hello",
        byline: "A. Writer",
        publishedAt: timestamp,
        siteName: "Example",
        lang: "en",
        wordCount: 812,
        sections: [
            ContentSection(id: "s0", kind: .heading, markdown: "# Hello", level: 1),
            ContentSection(id: "s1", kind: .paragraph, markdown: "First paragraph."),
            ContentSection(
                id: "s2",
                kind: .code,
                markdown: "```swift\nlet x = 1\n```",
                html: "<pre><code class=\"language-swift\">let x = 1</code></pre>"
            ),
        ],
        usedRecipe: "https://example.com|/posts/*",
        confidence: 0.92
    )

    static var theme: ReaderTheme {
        var theme = ReaderTheme.zentic
        theme.createdAt = timestamp
        return theme
    }

    static var configuration: ReaderConfiguration {
        ReaderConfiguration(
            level: .reader,
            mode: .restructured,
            theme: theme,
            recipe: recipe,
            passthroughOrigins: ["https://mail.google.com"],
            debugLogging: true
        )
    }

    /// A second configuration below the reader threshold.
    ///
    /// One golden file cannot pin a clamp: `mode` is asked for as `.restructured`
    /// here and must come out `.original`, and the only way to hold both languages
    /// to that is a fixture where the two fields disagree with the request.
    static var cleanConfiguration: ReaderConfiguration {
        ReaderConfiguration(
            level: .clean,
            mode: .restructured,
            theme: theme,
            recipe: recipe,
            passthroughOrigins: ["https://mail.google.com"],
            debugLogging: true
        )
    }
}
