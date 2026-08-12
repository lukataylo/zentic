import Foundation
import Testing

@testable import ZenticKit

@Suite("Wire contract")
struct WireContractTests {

    // MARK: Golden fixtures shared with the TypeScript bundle

    @Test func configurationMatchesGolden() throws {
        try GoldenFixture.assertMatches(Sample.configuration, named: "configuration")
    }

    @Test func extractedEventMatchesGolden() throws {
        try GoldenFixture.assertMatches(
            ReaderEvent.extracted(Sample.extraction),
            named: "event-extracted"
        )
    }

    @Test func needsRecipeEventMatchesGolden() throws {
        try GoldenFixture.assertMatches(
            ReaderEvent.needsRecipe(Sample.skeleton),
            named: "event-needsRecipe"
        )
    }

    @Test func revealedEventMatchesGolden() throws {
        try GoldenFixture.assertMatches(
            ReaderEvent.revealed(RevealPayload(reason: .failsafe, elapsedMs: 1500)),
            named: "event-revealed"
        )
    }

    @Test func applyThemeCommandMatchesGolden() throws {
        try GoldenFixture.assertMatches(
            ReaderCommand.applyTheme(Sample.theme),
            named: "command-applyTheme"
        )
    }

    @Test func applyDocumentCommandMatchesGolden() throws {
        try GoldenFixture.assertMatches(
            ReaderCommand.applyDocument(
                GeneratedDocument(html: "<style>p{color:#222}</style><p>Hello</p>")
            ),
            named: "command-applyDocument"
        )
    }

    @Test func requestSkeletonCommandMatchesGolden() throws {
        try GoldenFixture.assertMatches(
            ReaderCommand.requestSkeleton,
            named: "command-requestSkeleton"
        )
    }

    /// Exports the rewritability rule so the TypeScript bundle can assert it
    /// agrees.
    ///
    /// Both languages need this predicate — Swift to build the request, the bundle
    /// to decide which nodes may be swapped — so it exists twice, and duplicated
    /// invariants drift. Publishing it as a fixture means a change on one side
    /// fails a test on the other rather than quietly letting a model rewrite a
    /// code block.
    @Test func sectionKindRulesMatchGolden() throws {
        let rules = Dictionary(
            uniqueKeysWithValues: SectionKind.allCases.map { ($0.rawValue, $0.isRewritable) }
        )
        try GoldenFixture.assertMatches(rules, named: "section-kinds")
    }

    // MARK: Envelope shape

    @Test("Events encode as a tagged envelope, not Swift's default enum shape")
    func envelopeShape() throws {
        let data = try ZenticCoding.makeEncoder()
            .encode(ReaderEvent.revealed(RevealPayload(reason: .rendered, elapsedMs: 42)))
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object["v"] as? Int == ZenticCoding.wireVersion)
        #expect(object["type"] as? String == "revealed")
        #expect(object["payload"] is [String: Any])
        // Swift's synthesised encoding would have produced {"revealed": {...}}.
        #expect(object["revealed"] == nil)
    }

    @Test("Dates cross the wire as ISO-8601, not epoch seconds")
    func datesAreISO8601() throws {
        let data = try ZenticCoding.makeEncoder().encode(Sample.recipe)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("2025-07-31T") || json.contains("2025-08-01T"))
        #expect(!json.contains("1754000000"))
    }

    // MARK: Round trips

    @Test(
        "Every event survives a round trip",
        arguments: [
            ReaderEvent.ready(ReadyPayload(bundleVersion: "0.1.0", url: "https://example.com")),
            ReaderEvent.extracted(Sample.extraction),
            ReaderEvent.needsRecipe(Sample.skeleton),
            ReaderEvent.revealed(RevealPayload(reason: .passthrough, elapsedMs: 12)),
            ReaderEvent.failed(ReaderFailure(stage: "extract", message: "boom")),
        ]
    )
    func eventRoundTrip(event: ReaderEvent) throws {
        let data = try ZenticCoding.makeEncoder().encode(event)
        let decoded = try ZenticCoding.makeDecoder().decode(ReaderEvent.self, from: data)
        #expect(decoded == event)
    }

    @Test(
        "Every command survives a round trip",
        arguments: [
            ReaderCommand.applyRecipe(Sample.recipe),
            ReaderCommand.setMode(.original),
            ReaderCommand.requestSkeleton,
            ReaderCommand.applyRewrite(
                RewritePatch(sectionID: "s1", markdown: "text", isFinal: true)
            ),
            ReaderCommand.discardRewrite,
            ReaderCommand.applyTheme(Sample.theme),
        ]
    )
    func commandRoundTrip(command: ReaderCommand) throws {
        let data = try ZenticCoding.makeEncoder().encode(command)
        let decoded = try ZenticCoding.makeDecoder().decode(ReaderCommand.self, from: data)
        #expect(decoded == command)
    }

    @Test("A future wire version is rejected rather than silently misread")
    func rejectsUnknownWireVersion() throws {
        let json = #"{"v":999,"type":"requestSkeleton"}"#
        #expect(throws: ReaderBridgeError.self) {
            try ZenticCoding.makeDecoder()
                .decode(ReaderCommand.self, from: Data(json.utf8))
        }
    }
}
