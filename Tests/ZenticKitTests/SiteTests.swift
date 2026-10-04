import Foundation
import JavaScriptCore
import Testing

@testable import ZenticKit

@Suite struct SiteBookTests {
    let version = CustomVersion(base: .minimal, css: "body{color:red}", hide: [".ad"], summary: "Red.", prompts: ["red"])

    @Test func defaultAppliesToUnknownSites() {
        let book = SiteBook(defaultMode: .minimal)
        #expect(book.mode(for: "example.com") == .minimal)
    }

    @Test func customWithoutAVersionFallsBackRatherThanClaimingCustom() {
        var book = SiteBook(defaultMode: .clean)
        book.setMode(.custom, for: "example.com")
        #expect(book.mode(for: "example.com") == .clean)
    }

    @Test func removingCustomDropsBackToDefault() {
        var book = SiteBook(defaultMode: .minimal)
        book.saveCustom(version, for: "a.com")
        #expect(book.mode(for: "a.com") == .custom)
        book.removeCustom(for: "a.com")
        #expect(book.mode(for: "a.com") == .minimal)
        // Pruned: matching the default and carrying no version, it is noise.
        #expect(book.sites["a.com"] == nil)
    }

    @Test func choosingTheDefaultDoesNotPinAgainstALaterChange() {
        var book = SiteBook(defaultMode: .clean)
        book.setMode(.clean, for: "a.com")
        book.defaultMode = .minimal
        #expect(book.mode(for: "a.com") == .minimal)
    }

    @Test func switchingAwayFromCustomKeepsTheVersion() {
        var book = SiteBook()
        book.saveCustom(version, for: "a.com")
        book.setMode(.original, for: "a.com")
        #expect(book.mode(for: "a.com") == .original)
        #expect(book.custom(for: "a.com") == version)
        // And the in-page table doesn't ship CSS for a site not showing it.
        #expect(book.inPageConfig().sites["a.com"]?.custom == nil)
    }

    @Test func siteKeyIgnoresWWWAndCase() {
        #expect(SiteKey.for(URL(string: "https://WWW.Apple.com/uk/")) == "apple.com")
        #expect(SiteKey.for(URL(string: "https://news.ycombinator.com")) == "news.ycombinator.com")
        #expect(SiteKey.for(URL(string: "about:blank")) == nil)
    }
}

/// The bootstrap decides each document's mode in the page itself. Run it in a
/// real JS engine against a fake `location` — the Swift and JS halves have to
/// agree on the site key or a site's choice silently never applies.
@Suite struct BootstrapTests {
    func config(for href: String, book: SiteBook) -> [String: Any]? {
        let context = JSContext()!
        let url = URL(string: href)!
        context.evaluateScript(
            """
            var window = {};
            var location = { protocol: "\(url.scheme!):", hostname: "\(url.host() ?? "")" };
            """)
        context.evaluateScript(InPageScript.bootstrap(book.inPageConfig()))
        return context.evaluateScript("window.__zenticConfig")?.toDictionary() as? [String: Any]
    }

    @Test func picksTheSiteByHostWithoutWWW() {
        var book = SiteBook(defaultMode: .clean)
        book.setMode(.minimal, for: "apple.com")
        #expect(config(for: "https://www.apple.com/uk/", book: book)?["mode"] as? String == "minimal")
        #expect(config(for: "https://other.org/", book: book)?["mode"] as? String == "clean")
    }

    @Test func customCarriesItsStylesheet() {
        var book = SiteBook()
        book.saveCustom(
            CustomVersion(base: .clean, css: "h1{color:red}", hide: ["#ad"], summary: "", prompts: []), for: "a.com")
        let config = config(for: "https://a.com/x", book: book)
        let custom = config?["custom"] as? [String: Any]
        #expect(config?["mode"] as? String == "custom")
        #expect(custom?["css"] as? String == "h1{color:red}")
        #expect(custom?["hide"] as? [String] == ["#ad"])
    }

    @Test func nonWebPagesAreLeftAlone() {
        let book = SiteBook(defaultMode: .minimal)
        #expect(config(for: "file:///tmp/a.html", book: book)?["mode"] as? String == "original")
    }

    @Test func survivesHostileStylesheetText() {
        var book = SiteBook()
        book.saveCustom(
            CustomVersion(base: .clean, css: "p::after{content:\"\u{2028}\\\"});alert(1)//\"}", hide: [], summary: "", prompts: []),
            for: "a.com")
        #expect(config(for: "https://a.com/", book: book)?["mode"] as? String == "custom")
    }
}

@Suite struct CSSSanitizerTests {
    @Test func stripsEverythingThatCanFetch() {
        let css = """
            @import url("https://evil.example/x.css");
            @font-face { font-family: X; src: url(https://evil.example/f.woff2); }
            body { background: url( 'https://evil.example/p.gif' ) }
            .a { background-image: image-set("https://e.example/1.png" 1x) }
            .b { background: url(data:image/png;base64,AAAA) }
            """
        let out = CSSSanitizer.sanitize(css)
        #expect(!out.contains("evil.example"))
        #expect(!out.contains("e.example"))
        #expect(!out.contains("@import"))
        #expect(!out.contains("@font-face"))
        #expect(out.contains("url(data:image/png;base64,AAAA)"))
    }

    @Test func escapesHiddenInCommentsAndEscapesDontSurvive() {
        let out = CSSSanitizer.sanitize("a{background:u/**/rl(https://x.example/)} b{background:\\75rl(https://y.example)}")
        #expect(!out.contains("x.example") || !out.contains("url("))
        #expect(!out.contains("\\"))
    }

    /// Found in review: removing one token used to splice its neighbours into
    /// a new one, and the two sanitizers in series completed each other's work.
    @Test(arguments: [
        "body{background:urjavajavascript:script:l(https://evil.example/p.png)}",
        "@imjavajavascript:script:port \"https://evil.example/x.css\";",
        "a{background:urlexpression(https://evil.example/a.png)}",
        "a{background:\\75 rl(https://evil.example/a.png)}",
        "a{background:u/**/rl(https://evil.example/a.png)}",
        "a{background:-webkit-image-set(\"https://evil.example/a.png\" 1x)}",
        "a{background:src(\"https://evil.example/a.png\")}",
        "@import'https://evil.example/x.css';",
    ])
    func splicedTokensCannotFetch(_ css: String) {
        let out = CSSSanitizer.sanitize(css)
        #expect(!out.contains("evil.example") || !CSSSanitizer.fetchesRemotely(out), "\(out)")
        #expect(!CSSSanitizer.fetchesRemotely(out), "\(out)")
    }

    @Test func storedVersionsAreCleanedWhenLoaded() throws {
        let json = #"{"base":"clean","css":"a{background:url(https://evil.example/x)}","hide":[".ad"],"summary":"","prompts":[],"updatedAt":"2026-10-04T15:00:00Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let version = try decoder.decode(CustomVersion.self, from: Data(json.utf8))
        #expect(!version.css.contains("evil.example"))
    }

    @Test func tailwindSelectorsSurvive() {
        #expect(CSSSanitizer.sanitizeSelectors([#".md\:hidden"#]) == [#".md\:hidden"#])
    }

    @Test func cannotCloseTheStyleElement() {
        #expect(!CSSSanitizer.sanitize("a{}</style><script>alert(1)</script>").lowercased().contains("</style"))
    }

    @Test func selectorsCannotSmuggleDeclarations() {
        let out = CSSSanitizer.sanitizeSelectors([".ad", ".x{display:block}", "body", "html", ".ad", "  ", "#side"])
        #expect(out == [".ad", "#side"])
    }
}

@Suite struct URLGuessTests {
    @Test func resolves() {
        #expect(URLGuess.resolve("apple.com")?.absoluteString == "https://apple.com")
        #expect(URLGuess.resolve("localhost:3000")?.absoluteString == "http://localhost:3000")
        #expect(URLGuess.resolve("192.168.1.1")?.absoluteString == "http://192.168.1.1")
        #expect(URLGuess.resolve("https://x.org/a?b=1")?.absoluteString == "https://x.org/a?b=1")
        let search = URLGuess.resolve("how to bake bread", engine: .duckDuckGo)!
        #expect(URLGuess.isSearch(search, engine: .duckDuckGo))
        #expect(URLGuess.resolve("swift.org")!.host() == "swift.org")
        #expect(URLGuess.isSearch(URLGuess.resolve("file.txt")!, engine: .google) == false)
    }

    @Test func displayHost() {
        #expect(URLGuess.displayHost(URL(string: "https://www.apple.com/uk")) == "apple.com")
        #expect(URLGuess.displayHost(URL(string: "about:blank")) == "")
    }
}

@Suite struct OpenAIDesignerTests {
    func response(_ payload: String) -> Data {
        let content = payload.replacingOccurrences(of: "\"", with: "\\\"")
        return Data(#"{"choices":[{"message":{"content":"\#(content)"}}]}"#.utf8)
    }

    @Test func parsesAndSanitizesTheAnswer() throws {
        let answer = try OpenAIDesigner.answer(
            from: response(
                #"{"summary":"Calmer.","base":"minimal","css":"body{background:url(https://t.example/x)}","hide":[".ad","body"]}"#
            ))
        #expect(answer.base == .minimal)
        #expect(!answer.css.contains("t.example"))
        #expect(answer.hide == [".ad"])
        #expect(answer.summary == "Calmer.")
    }

    @Test func emptyAnswerIsAnErrorNotASilentNoOp() {
        #expect(throws: DesignError.self) {
            try OpenAIDesigner.answer(from: response(#"{"summary":"","base":"clean","css":"","hide":[]}"#))
        }
    }

    @Test func refusalSurfaces() {
        let data = Data(#"{"choices":[{"message":{"content":null,"refusal":"No."}}]}"#.utf8)
        #expect(throws: DesignError.refused("No.")) { try OpenAIDesigner.answer(from: data) }
    }

    @Test func reasoningModelsGetEffortNotTemperature() {
        let request = OpenAIDesigner.Request(
            url: URL(string: "https://a.com")!, title: "A", outline: "body", instruction: "x", current: nil)
        let reasoning = OpenAIDesigner.body(for: request, model: "gpt-5-mini")
        #expect(reasoning["reasoning_effort"] as? String == "low")
        #expect(reasoning["temperature"] == nil)
        let classic = OpenAIDesigner.body(for: request, model: "gpt-4.1-mini")
        #expect(classic["reasoning_effort"] == nil)
    }

    @Test func refinementIncludesTheCurrentVersion() {
        let current = CustomVersion(base: .clean, css: ".x{color:red}", hide: ["#ad"], summary: "", prompts: ["make it red"])
        let prompt = OpenAIDesigner.userPrompt(
            .init(url: URL(string: "https://a.com")!, title: "A", outline: "o", instruction: "now blue", current: current))
        #expect(prompt.contains(".x{color:red}"))
        #expect(prompt.contains("make it red"))
        #expect(prompt.contains("now blue"))
    }
}
