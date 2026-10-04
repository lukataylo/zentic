import Foundation

/// Writes a site's custom version with the user's own OpenAI key.
///
/// The model is shown a structural outline of the page — tags, ids, classes,
/// sizes and a little visible text, so it can write selectors that actually
/// match — and the user's words. It answers with a stylesheet and a list of
/// selectors to hide. Nothing it returns can run code, and the stylesheet is
/// sanitized before it is applied or stored (``CSSSanitizer``).
///
/// One call per instruction. Every later visit replays the stored result with
/// no call at all.
public struct OpenAIDesigner: Sendable {
    public struct Request: Sendable {
        public var url: URL
        public var title: String
        public var outline: String
        public var instruction: String
        /// The version being refined, if any.
        public var current: CustomVersion?
        /// A JPEG of the page as it looks now, as a data URL. A model that can
        /// see the page writes CSS that fits it; one working from the outline
        /// alone guesses at the layout and breaks table-built sites.
        public var screenshot: String?
        /// Set on a repair pass: what went wrong with `current` when previewed.
        public var problem: String?

        public init(
            url: URL, title: String, outline: String, instruction: String, current: CustomVersion?,
            screenshot: String? = nil, problem: String? = nil
        ) {
            self.url = url
            self.title = title
            self.outline = outline
            self.instruction = instruction
            self.current = current
            self.screenshot = screenshot
            self.problem = problem
        }
    }

    public struct Answer: Sendable, Hashable {
        public var base: CustomBase
        public var css: String
        public var hide: [String]
        public var summary: String
    }

    public static let defaultModel = "gpt-5-mini"

    public var apiKey: String
    public var model: String
    public var session: URLSession

    public init(apiKey: String, model: String = OpenAIDesigner.defaultModel, session: URLSession = .shared) {
        self.apiKey = apiKey
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = trimmed.isEmpty ? Self.defaultModel : trimmed
        self.session = session
    }

    private static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    // MARK: - Design

    public func design(_ request: Request) async throws -> Answer {
        let body = Self.body(for: request, model: model)
        let data = try await post(Self.endpoint, json: body, timeout: 120)
        return try Self.answer(from: data)
    }

    static func body(for request: Request, model: String) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userContent(request)],
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": ["name": "site_version", "strict": true, "schema": schema],
            ],
        ]
        // Reasoning models take an effort and reject `temperature`; others the
        // reverse. A design pass does not need deep reasoning, and speed is what
        // the user is waiting on.
        if Self.isReasoningModel(model) {
            body["reasoning_effort"] = "low"
        } else {
            body["temperature"] = 0.4
        }
        return body
    }

    static func isReasoningModel(_ model: String) -> Bool {
        let m = model.lowercased()
        return m.hasPrefix("gpt-5") || m.hasPrefix("o1") || m.hasPrefix("o3") || m.hasPrefix("o4")
    }

    static func answer(from data: Data) throws -> Answer {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any]
        else { throw DesignError.malformed("The response had no message.") }
        if let refusal = message["refusal"] as? String, !refusal.isEmpty {
            throw DesignError.refused(refusal)
        }
        guard let content = message["content"] as? String,
            let payload = try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any]
        else { throw DesignError.malformed("The model's answer was not JSON.") }

        let base = CustomBase(rawValue: payload["base"] as? String ?? "") ?? .clean
        let css = CSSSanitizer.sanitize(payload["css"] as? String ?? "")
        let hide = CSSSanitizer.sanitizeSelectors(payload["hide"] as? [String] ?? [])
        let summary = (payload["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !css.isEmpty || !hide.isEmpty || base == .minimal else {
            throw DesignError.malformed("The model returned no changes. Try describing it differently.")
        }
        return Answer(base: base, css: css, hide: hide, summary: summary.isEmpty ? "Your version" : summary)
    }

    // MARK: - Key check

    /// Confirms the key works and the model is reachable, without spending tokens.
    public func verify() async throws {
        let url = URL(string: "https://api.openai.com/v1/models/\(model)")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        try Self.check(response, data)
    }

    // MARK: - Transport

    private func post(_ url: URL, json: [String: Any], timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw DesignError.network(error.localizedDescription)
        }
        try Self.check(response, data)
        return data
    }

    static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200..<300).contains(http.statusCode) else { return }
        let message =
            ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any])?[
                "message"] as? String
        switch http.statusCode {
        case 401: throw DesignError.badKey
        case 404: throw DesignError.unknownModel(message ?? "The model was not found.")
        case 429: throw DesignError.rateLimited(message ?? "Rate limited or out of credit.")
        default: throw DesignError.server(http.statusCode, message ?? "Unexpected response.")
        }
    }

    // MARK: - Prompt

    /// A description of what the Minimal base does and which variables it
    /// exposes, kept next to the stylesheet in `web/src/minimal.ts`.
    public static let minimalDescription = """
        Base "minimal": every site stylesheet and inline style is switched off and Zentic's own \
        calm design is applied to the page's real HTML. Content sits in one centred column \
        (max-width var(--z-measure)); the site's top header/nav bars become compact horizontal \
        rows, other navs (tables of contents, side menus) quiet vertical lists; nested menus, \
        overlays, fixed widgets and visually-hidden helpers are hidden; images, video, tables, \
        code and forms are styled consistently; light and dark follow the system.
        Elements the site had hidden carry [data-zentic-hidden] and stay hidden. Restyle it by \
        overriding these custom properties on :root: --z-bg (page background), --z-fg (text), \
        --z-muted (secondary text), --z-accent (links, focus, primary buttons), --z-surface \
        (cards, code, inputs), --z-border (hairlines), --z-font (body font stack), \
        --z-font-display (headings), --z-mono (code), --z-measure (column width, e.g. 46rem), \
        --z-radius (corner radius), --z-size (base font size, e.g. 17px).
        Plain element selectors (h1, nav, article, img, table…) are reliable here; site class \
        names still exist in the DOM but nothing styles them.
        """

    static var systemPrompt: String {
        """
        You are a world-class product designer restyling a live website for one person, \
        through a user stylesheet that will be applied on every visit. The site's own DOM \
        stays live and interactive; you only add CSS and may hide elements.

        Return JSON with:
        - base: "clean" to layer over the site's own design (use when the request is a \
        tweak: hide things, recolour, enlarge text, reorder), or "minimal" to start from \
        Zentic's minimal redesign (use when the request is a different look or a calmer, \
        simpler page).
        - css: the stylesheet.
        - hide: CSS selectors of elements to remove entirely.
        - summary: one short sentence, in second person, saying what this version does.

        \(minimalDescription)

        Rules:
        - Only use selectors you can see in the outline (ids, classes, attributes, tags \
        and their nesting). Prefer stable ids, data-* attributes, roles and semantic tags \
        over hashed class names.
        - With base "clean", the site's CSS still applies: use !important where you need \
        to win, and keep the layout working.
        - Never hide html, body, or the element holding the main content.
        - No url(), @import or @font-face — they are stripped. Use system fonts \
        (-apple-system, "SF Pro", "New York", Georgia, Menlo, ui-monospace…).
        - Choose the base deliberately. Any change to the overall look — a theme, dark \
        mode, typography, a "reader" or "newspaper" feel — should use base "minimal" and \
        restyle it mainly through the --z-* variables plus a few plain element rules: that \
        is reliable on every site. Use "clean" only for surgical tweaks where the site's \
        own design should stay (hide a panel, recolour a bar, enlarge text).
        - Never change the display, position or float of table, tr or td elements, and \
        never turn rows into blocks: many sites are laid out with tables, and that \
        collapses them. Style inside cells instead.
        - When you change background colours, also set the colour of all text, links, \
        metadata and form controls, so nothing becomes unreadable.
        - Respect prefers-color-scheme unless the user asked for a specific scheme.
        - Keep it accessible: readable contrast, visible focus, no text under 13px.
        - Be bold and complete when the user asks for a redesign; be surgical when they \
        ask for a tweak. When refining an existing version, return the full revised \
        stylesheet and hide list, not a diff.
        """
    }

    /// Text, plus the screenshot when there is one.
    static func userContent(_ request: Request) -> Any {
        guard let screenshot = request.screenshot else { return userPrompt(request) }
        return [
            ["type": "text", "text": userPrompt(request)],
            ["type": "image_url", "image_url": ["url": screenshot, "detail": "high"]],
        ]
    }

    static func userPrompt(_ request: Request) -> String {
        var text = """
            Page: \(request.title)
            URL: \(request.url.absoluteString)

            """
        if let current = request.current {
            text += """
                The user already has a version of this site. Earlier instructions, oldest first:
                \(current.prompts.map { "- \($0)" }.joined(separator: "\n"))

                Its base is "\(current.base.rawValue)". Its current stylesheet:
                ```css
                \(current.css)
                ```
                Currently hidden: \(current.hide.isEmpty ? "nothing" : current.hide.joined(separator: ", "))

                Revise it according to the new instruction below.

                """
        }
        if let problem = request.problem {
            text += """
                Previewing that stylesheet broke the page: \(problem)
                The screenshot shows the broken result. Fix it — keep what the user asked for, \
                but make sure all the content is visible, readable and laid out sensibly.

                """
        }
        if request.screenshot != nil && request.problem == nil {
            text += "The screenshot shows the page as it looks now.\n\n"
        }
        text += """
            Instruction: \(request.instruction)

            Page outline:
            \(request.outline)
            """
        return text
    }

    static var schema: [String: Any] { [
        "type": "object",
        "additionalProperties": false,
        "required": ["summary", "base", "css", "hide"],
        "properties": [
            "summary": ["type": "string"],
            "base": ["type": "string", "enum": ["clean", "minimal"]],
            "css": ["type": "string"],
            "hide": ["type": "array", "items": ["type": "string"]],
        ],
    ] }
}

public enum DesignError: LocalizedError, Sendable, Equatable {
    case noKey
    case badKey
    case unknownModel(String)
    case rateLimited(String)
    case server(Int, String)
    case network(String)
    case refused(String)
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .noKey: "Add your OpenAI API key to design custom versions."
        case .badKey: "OpenAI didn't accept that API key."
        case .unknownModel(let m): "Model unavailable: \(m)"
        case .rateLimited(let m): m
        case .server(let code, let m): "OpenAI error \(code): \(m)"
        case .network(let m): m
        case .refused(let m): m
        case .malformed(let m): m
        }
    }
}
