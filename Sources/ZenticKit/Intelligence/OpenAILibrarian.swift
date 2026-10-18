import Foundation

/// The library's two uses of the user's key: learning a site's JSON, and
/// designing an app over the result.
///
/// Both send exactly what their input type carries and nothing more — a
/// ``ShapeSummary`` string for a recipe, an ``AppBrief`` for an app — so what
/// leaves the device is decided by those types and their tests, not by whoever
/// next edits a prompt here.
public struct OpenAILibrarian: RecipeInferring {
    /// The model apps are designed with: OpenAI's current frontier model. A
    /// whole designed document is the one place in Zentic where the strongest
    /// model is worth its wait. Settings › Intelligence can change it.
    public static let defaultAppModel = "gpt-6-sol"

    public var apiKey: String
    /// For apps. Recipes use ``recipeModel``.
    public var appModel: String
    /// For recipes: a structural question, answered well by the model the user
    /// already chose for custom versions.
    public var recipeModel: String
    public var session: URLSession

    public init(
        apiKey: String, appModel: String = OpenAILibrarian.defaultAppModel,
        recipeModel: String = OpenAIDesigner.defaultModel, session: URLSession = OpenAIDesigner.ephemeralSession
    ) {
        self.apiKey = apiKey
        let app = appModel.trimmingCharacters(in: .whitespacesAndNewlines)
        self.appModel = app.isEmpty ? Self.defaultAppModel : app
        let recipe = recipeModel.trimmingCharacters(in: .whitespacesAndNewlines)
        self.recipeModel = recipe.isEmpty ? OpenAIDesigner.defaultModel : recipe
        self.session = session
    }

    private static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    // MARK: - Recipes

    public func inferEndpointRecipe(shape: String) async throws -> EndpointRecipe {
        var body: [String: Any] = [
            "model": recipeModel,
            "messages": [
                ["role": "system", "content": Self.recipeInstructions],
                ["role": "user", "content": "Shape of one response:\n\(shape)"],
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": ["name": "endpoint_recipe", "strict": true, "schema": Self.endpointRecipeSchema],
            ],
        ]
        Self.tune(&body, model: recipeModel, effort: "low")
        let content = try Self.content(of: try await post(body, timeout: 120))
        do {
            var recipe = try LibraryCoding.decoder().decode(EndpointRecipe.self, from: Data(content.utf8))
            recipe.inferredAt = .now
            // A path the parser rejects is a recipe that maps nothing; better to
            // know now than to store it and wonder why the source is empty.
            if let items = recipe.items { _ = try JSONPath(items) }
            return recipe
        } catch {
            throw DesignError.malformed("The model’s description of this site couldn’t be used.")
        }
    }

    // MARK: - Apps

    /// Design a new app, or revise one, from a brief.
    public func generateApp(_ brief: AppBrief) async throws -> AppDraft {
        var body: [String: Any] = [
            "model": appModel,
            "messages": [
                ["role": "system", "content": AppBrief.instructions],
                ["role": "user", "content": brief.userMessage()],
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": ["name": "app", "strict": true, "schema": Self.appSchema],
            ],
        ]
        // A designed document is worth thinking about; this is the one call in
        // Zentic where the user expects to wait.
        Self.tune(&body, model: appModel, effort: "medium")
        let content = try Self.content(of: try await post(body, timeout: 600))
        guard let draft = try? JSONDecoder().decode(AppDraft.self, from: Data(content.utf8)),
            draft.html.range(of: "<", options: .literal) != nil
        else { throw DesignError.malformed("The model’s answer wasn’t a usable app. Try again, or rephrase.") }
        guard draft.html.utf8.count <= LibraryBudget.maxAppHTMLBytes else {
            throw DesignError.malformed("The app came back too large (\(draft.html.utf8.count / 1000) KB). Try asking for less.")
        }
        return AppDraft(
            name: String(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)),
            symbol: AppBrief.symbols.contains(draft.symbol) ? draft.symbol : "square.grid.2x2",
            html: draft.html)
    }

    // MARK: - Transport

    /// Reasoning models take an effort and reject `temperature`; others the reverse.
    static func tune(_ body: inout [String: Any], model: String, effort: String) {
        let m = model.lowercased()
        if m.hasPrefix("gpt-5") || m.hasPrefix("gpt-6") || m.hasPrefix("o1") || m.hasPrefix("o3") || m.hasPrefix("o4") {
            body["reasoning_effort"] = effort
        } else {
            body["temperature"] = 0.4
        }
    }

    private func post(_ json: [String: Any], timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: Self.endpoint)
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
        try OpenAIDesigner.check(response, data)
        return data
    }

    static func content(of data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any]
        else { throw DesignError.malformed("The response had no message.") }
        if let refusal = message["refusal"] as? String, !refusal.isEmpty { throw DesignError.refused(refusal) }
        guard let content = message["content"] as? String, !content.isEmpty else {
            throw DesignError.malformed("The response was empty.")
        }
        return content
    }

    // MARK: - Prompts and schemas

    static let recipeInstructions = """
        You map a website's JSON API responses to records for a local database. \
        You are shown the SHAPE of one response — keys, value types, coarse length \
        buckets and string classes (date, url, imageURL, id, numeric, text, word) — \
        never its values. Decide whether it contains a list of user-facing items \
        (posts, comments, articles, products, videos, events) and, if so, how to find \
        them and their fields.

        Paths use a small JSONPath: `$` root, `.key` child, `..key` any-depth \
        descendant, `[*]` every element, `[?key]` objects having key, `[?!key]` \
        objects lacking key. `items` is evaluated from the response root and should \
        select each item object; prefer `..key` naming the item by what it is, so the \
        path survives wrapper changes. Field paths are evaluated from each item and \
        are lists of alternatives tried in order. `unwrap` paths replace an item with \
        a nested object first (reposts → original, wrapper → content). `mentions` \
        selects handles an item mentions or replies to; `links` selects outbound URLs, \
        expanded where the shape offers an expanded form.

        Exclude ads/promoted/sponsored entries with a `[?!key]` filter when the shape \
        shows a marker for them. If the response is configuration, counts, user \
        settings, tracking, or anything that is not a list of content, return \
        items = null. id and either text or title are required for an item to be kept.
        """

    static var appSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "name": ["type": "string"],
                "symbol": ["type": "string", "enum": AppBrief.symbols],
                "html": ["type": "string"],
            ],
            "required": ["name", "symbol", "html"],
            "additionalProperties": false,
        ]
    }

    static var endpointRecipeSchema: [String: Any] {
        let paths: [String: Any] = ["type": "array", "items": ["type": "string"]]
        let fieldNames = [
            "id", "title", "text", "author", "authorHandle", "authorAvatar",
            "publishedAt", "url", "parentID", "threadID", "media", "mentions", "links",
        ]
        var fieldProperties: [String: Any] = Dictionary(uniqueKeysWithValues: fieldNames.map { ($0, paths) })
        fieldProperties["urlTemplate"] = ["type": ["string", "null"]]
        fieldProperties["metrics"] = [
            "type": "array",
            "items": [
                "type": "object",
                "properties": ["name": ["type": "string"], "paths": paths],
                "required": ["name", "paths"],
                "additionalProperties": false,
            ],
        ]
        return [
            "type": "object",
            "properties": [
                "endpoint": ["type": "string"],
                "items": ["type": ["string", "null"]],
                "unwrap": paths,
                "kind": ["type": "string", "enum": SourceRecord.Kind.allCases.map(\.rawValue)],
                "fields": [
                    "type": "object",
                    "properties": fieldProperties,
                    "required": Array(fieldProperties.keys).sorted(),
                    "additionalProperties": false,
                ],
            ],
            "required": ["endpoint", "items", "unwrap", "kind", "fields"],
            "additionalProperties": false,
        ]
    }
}

// MARK: - Icons

/// What the image model is shown to draw an app's icon: its name and the user's
/// own words for it. Never a record — the icon is about the app, not the data.
public struct AppIconBrief: Sendable, Hashable {
    public var name: String
    public var request: String

    public init(name: String, request: String) {
        self.name = name
        self.request = String(request.prefix(600))
    }

    public var prompt: String {
        """
        A macOS app icon for a small personal app called "\(name)". What it is for, in its \
        owner's words: \(request)

        One simple, bold, instantly readable symbol that captures the idea, centred on a \
        rounded-square tile with a soft, rich gradient and gentle depth, in the refined \
        style of Apple's own app icons. It must read clearly at 20 points: one subject, \
        strong silhouette, few details, generous margin. No text, letters, numbers, \
        logos, brand marks or UI screenshots.
        """
    }
}

extension OpenAILibrarian {
    /// OpenAI's image model, by its confirmed id. Settings › Library can name
    /// another — image model ids move faster than releases.
    public static let defaultImageModel = "gpt-image-2"

    /// Draw an app's icon. Returns PNG data, already scaled down to
    /// ``iconPixels`` — a 1024-pixel original would be a megabyte per tile for
    /// something drawn at 44 points.
    public func generateIcon(_ brief: AppIconBrief, model: String = OpenAILibrarian.defaultImageModel) async throws
        -> Data
    {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: [String: Any] = [
            "model": trimmed.isEmpty ? Self.defaultImageModel : trimmed,
            "prompt": brief.prompt,
            "size": "1024x1024",
            "n": 1,
        ]
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/images/generations")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw DesignError.network(error.localizedDescription)
        }
        try OpenAIDesigner.check(response, data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let first = (json["data"] as? [[String: Any]])?.first,
            let encoded = first["b64_json"] as? String,
            let image = Data(base64Encoded: encoded)
        else { throw DesignError.malformed("The image model returned no picture.") }
        guard let png = AppIconImage.thumbnail(image, pixels: Self.iconPixels) else {
            throw DesignError.malformed("The image model’s picture couldn’t be read.")
        }
        return png
    }

    /// Big enough for a Retina tile with room to spare; small enough to keep.
    public static let iconPixels = 256
}
