import Foundation

/// Bring-your-own-key provider, talking to OpenAI's Responses API.
///
/// The premium tier's first form, and the one with **zero backend**: the user's
/// key goes to the user's own account, so there is no service to run, no billing
/// relationship to broker, and no server of ours that browsing data could pass
/// through. The key lives in the Keychain (``APIKeyStore``).
///
/// ## The boundary that matters
///
/// This provider generates *design*, and design is the place where a model is
/// most tempted to emit code. It does not get to. `generateTheme` returns
/// ``ThemeTokens`` parsed from a constrained JSON schema, and the caller runs
/// `validated()` before anything is rendered. Free-form CSS from a model could
/// carry `url()`, which would beacon to an arbitrary host on every page the user
/// reads — invariant 5 exists precisely because that failure would be silent.
public actor OpenAIProvider: LLMProvider {
    public nonisolated let identifier = "openai"
    public nonisolated var tier: ProviderTier { .byoKey }

    private let model: String
    private let session: URLSession
    private let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    public init(model: String = "gpt-4.1-mini", session: URLSession = .shared) {
        self.model = model
        self.session = session
    }

    public func availability() async -> ProviderAvailability {
        APIKeyStore.has(.openAI)
            ? .available
            : .unavailable(reason: "Add an OpenAI API key in Settings to use cloud redesign.")
    }

    // MARK: - Theme generation

    public func generateTheme(from prompt: String) async throws -> ThemeTokens {
        let instructions = """
            You are a typographer and interface designer. You produce reading \
            designs for a browser that re-renders web pages in its own design \
            system. You never write CSS or code — only the token values requested.

            Design for sustained reading: generous line height, a measure in the \
            55–80 character range, restrained accent colour, and enough contrast \
            that body text is comfortable. Light and dark palettes must both be \
            complete and legible in their own right; the dark palette is not the \
            light one inverted.

            Colours are #rrggbb. Fonts must come from the allowed list.
            """

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": "Design a reading theme: \(prompt)"],
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "theme_tokens",
                    "strict": true,
                    "schema": Self.themeSchema,
                ],
            ],
        ]

        let json = try await post(body)
        guard let content = Self.firstMessageContent(json) else {
            throw LLMError.malformedOutput("no content in response")
        }
        guard let data = content.data(using: .utf8) else {
            throw LLMError.malformedOutput("content was not UTF-8")
        }
        do {
            // Validated by the caller too, but a provider that returned unclamped
            // tokens would make the rule advisory rather than enforced.
            return try JSONDecoder().decode(ThemeTokens.self, from: data).validated()
        } catch {
            throw LLMError.malformedOutput("\(error)")
        }
    }

    // MARK: - Rewrite

    public nonisolated func rewrite(
        _ request: RewriteRequest
    ) -> AsyncThrowingStream<RewriteEvent, any Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    for section in request.sections where section.kind.isRewritable {
                        try Task.checkCancellation()
                        let text = section.markdown.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { continue }
                        do {
                            let rewritten = try await self.rewriteSection(text, request: request)
                            continuation.yield(
                                .patch(
                                    RewritePatch(
                                        sectionID: section.id,
                                        markdown: rewritten,
                                        isFinal: true
                                    )
                                )
                            )
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            continuation.yield(.skipped(sectionID: section.id, reason: "\(error)"))
                        }
                    }
                    continuation.yield(.finished)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: LLMError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    private func rewriteSection(_ text: String, request: RewriteRequest) async throws -> String {
        var directives = [request.tone.directive, request.length.directive]
        if let level = request.readingLevel { directives.append(level.directive) }

        let body: [String: Any] = [
            "model": model,
            "messages": [
                [
                    "role": "system",
                    "content": """
                        You rewrite passages from a web page. Never add a fact, figure, \
                        name, date or claim that is not in the input, and never drop one \
                        the passage depends on. Preserve Markdown links exactly. Return \
                        only the rewritten passage.
                        """,
                ],
                [
                    "role": "user",
                    "content": "\(directives.joined(separator: " "))\n\nPassage:\n\(text)",
                ],
            ],
        ]
        let json = try await post(body)
        guard let content = Self.firstMessageContent(json)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty
        else {
            throw LLMError.malformedOutput("empty rewrite")
        }
        return content
    }

    // MARK: - Not this milestone

    public nonisolated func inferRecipe(from skeleton: DOMSkeleton) async throws -> SiteRecipe {
        throw LLMError.providerFailed(
            identifier: identifier,
            message: "Recipe inference is not implemented yet (M4)."
        )
    }

    // MARK: - Transport

    private func post(_ body: [String: Any]) async throws -> [String: Any] {
        guard let key = APIKeyStore.load(.openAI) else {
            throw LLMError.notEntitled(tier: .byoKey)
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 90

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.providerFailed(identifier: identifier, message: "no response")
        }
        guard (200..<300).contains(http.statusCode) else {
            // The API's own error text is the most useful thing we can show, and it
            // never contains the key.
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0?["error"] as? [String: Any])?["message"] as? String }
                ?? "HTTP \(http.statusCode)"
            throw LLMError.providerFailed(identifier: identifier, message: detail)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.malformedOutput("response was not an object")
        }
        return json
    }

    private static func firstMessageContent(_ json: [String: Any]) -> String? {
        guard let choices = json["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else { return nil }
        return content
    }
}

// MARK: - Schema

extension OpenAIProvider {
    /// The JSON schema the model must fill in.
    ///
    /// Every enum is a closed list and every number is bounded, so the *worst* a
    /// model can return is an ugly theme — not an illegible one, and never a
    /// network request. `ThemeTokens.validated()` then clamps ranges and repairs
    /// text/background contrast, so "ugly" is bounded too.
    static var themeSchema: [String: Any] {
        func object(_ properties: [String: Any]) -> [String: Any] {
            [
                "type": "object",
                "properties": properties,
                "required": Array(properties.keys),
                "additionalProperties": false,
            ]
        }
        let hex: [String: Any] = ["type": "string", "pattern": "^#[0-9a-fA-F]{6}$"]
        func number(_ lower: Double, _ upper: Double) -> [String: Any] {
            ["type": "number", "minimum": lower, "maximum": upper]
        }
        func enumeration(_ cases: [String]) -> [String: Any] {
            ["type": "string", "enum": cases]
        }

        let fonts = FontKey.allCases.map(\.rawValue)
        let palette = object([
            "background": hex, "surface": hex, "text": hex, "textMuted": hex,
            "accent": hex, "visited": hex, "border": hex, "codeBackground": hex,
        ])

        return object([
            "typography": object([
                "body": enumeration(fonts),
                "heading": enumeration(fonts),
                "mono": enumeration(fonts),
                "baseSize": number(14, 24),
                "scaleRatio": number(1.1, 1.5),
                "lineHeight": number(1.3, 2.0),
                "measure": number(45, 90),
                "letterSpacing": number(-0.03, 0.08),
            ]),
            "light": palette,
            "dark": palette,
            "shape": object([
                "radius": number(0, 20),
                "borderWidth": number(0, 3),
                "elevation": enumeration(ThemeTokens.Shape.Elevation.allCases.map(\.rawValue)),
            ]),
            "ornament": object([
                "rule": enumeration(ThemeTokens.Ornament.RuleStyle.allCases.map(\.rawValue)),
                "listMarker": enumeration(ThemeTokens.Ornament.ListMarker.allCases.map(\.rawValue)),
                "linkDecoration": enumeration(
                    ThemeTokens.Ornament.LinkDecoration.allCases.map(\.rawValue)
                ),
                "headingCase": enumeration(ThemeTokens.Ornament.HeadingCase.allCases.map(\.rawValue)),
                "dropCap": ["type": "boolean"],
                "justify": ["type": "boolean"],
            ]),
            "density": number(0.7, 1.4),
        ])
    }
}
