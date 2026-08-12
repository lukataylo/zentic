import Foundation
import FoundationModels

/// The on-device provider: Apple Foundation Models.
///
/// The default tier and the free one. Nothing leaves the device, which is what
/// lets rewriting exist at all under invariant 7 — a browser that shipped the
/// user's reading to a server to restyle it would be a telemetry product wearing
/// a reader's clothes.
///
/// ## Section at a time, not token at a time
///
/// Each rewritable section gets its own request and arrives as one finished
/// patch. Token-level streaming would repaint a paragraph as the model types,
/// which reads as instability in a document the user is trying to *read*; section
/// granularity still fills the page progressively and lets cancellation land on a
/// clean boundary. It also keeps each prompt small enough that the on-device
/// context limit is not a design constraint.
public actor FoundationModelsProvider: LLMProvider {
    public nonisolated let identifier = "apple.foundation-models"
    public nonisolated var tier: ProviderTier { .onDevice }

    public init() {}

    public func availability() async -> ProviderAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            // Split by whether the user can do anything about it. "Turn on Apple
            // Intelligence" is worth showing; "this Mac cannot" should not be
            // offered again.
            switch reason {
            case .deviceNotEligible:
                return .ineligible(reason: "This Mac does not support Apple Intelligence.")
            case .appleIntelligenceNotEnabled:
                return .unavailable(
                    reason: "Apple Intelligence is off. Turn it on in System Settings."
                )
            case .modelNotReady:
                return .unavailable(reason: "The on-device model is still downloading.")
            @unknown default:
                return .unavailable(reason: "The on-device model is unavailable.")
            }
        @unknown default:
            return .unavailable(reason: "The on-device model is unavailable.")
        }
    }

    public nonisolated func rewrite(
        _ request: RewriteRequest
    ) -> AsyncThrowingStream<RewriteEvent, any Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    try await run(request, into: continuation)
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

    private func run(
        _ request: RewriteRequest,
        into continuation: AsyncThrowingStream<RewriteEvent, any Error>.Continuation
    ) async throws {
        guard await availability().isAvailable else {
            throw LLMError.noProviderAvailable
        }

        let session = LanguageModelSession(instructions: Self.instructions(for: request))

        // Filtered here as well as by the caller. Invariant 3 says code, tables,
        // math and embeds never reach a model, and a provider that trusted its
        // caller for that would make the rule advisory.
        for section in request.sections where section.kind.isRewritable {
            try Task.checkCancellation()

            let text = section.markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            do {
                let response = try await session.respond(to: Self.prompt(for: text, request: request))
                let rewritten = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !rewritten.isEmpty else {
                    continuation.yield(.skipped(sectionID: section.id, reason: "empty response"))
                    continue
                }
                continuation.yield(
                    .patch(RewritePatch(sectionID: section.id, markdown: rewritten, isFinal: true))
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // One refused section must not lose the user the whole rewrite —
                // the reader keeps the original text for anything skipped.
                continuation.yield(
                    .skipped(sectionID: section.id, reason: "\(error)")
                )
            }
        }

        continuation.yield(.finished)
    }

    /// Session instructions: the rules that hold for every section.
    private static func instructions(for request: RewriteRequest) -> String {
        var lines = [
            "You rewrite passages from a web page so they are easier to read.",
            "Rules, in order of importance:",
            "1. Never add a fact, figure, name, date or claim that is not in the input.",
            "2. Never remove a fact the passage depends on.",
            "3. Preserve Markdown links exactly, including their URLs.",
            "4. Return only the rewritten passage. No preamble, no commentary, no quotes around it.",
            "5. Keep the output in the same language as the input.",
        ]
        if let title = request.context.title.nonEmpty {
            lines.append("The passage is from an article titled \"\(title)\".")
        }
        if let site = request.context.siteName?.nonEmpty {
            lines.append("Published by \(site).")
        }
        return lines.joined(separator: "\n")
    }

    private static func prompt(for text: String, request: RewriteRequest) -> String {
        var directives: [String] = [request.tone.directive]
        directives.append(request.length.directive)
        if let level = request.readingLevel {
            directives.append(level.directive)
        }
        return """
            Rewrite the passage below. \(directives.joined(separator: " "))

            Passage:
            \(text)
            """
    }

    // MARK: - Not this milestone

    public nonisolated func inferRecipe(from skeleton: DOMSkeleton) async throws -> SiteRecipe {
        throw LLMError.providerFailed(
            identifier: identifier,
            message: "Recipe inference is not implemented yet (M4)."
        )
    }

    /// Guided generation straight into ``ThemeTokens``.
    ///
    /// The structure *is* the schema — the model fills in fields, so it cannot
    /// return CSS, a font name outside ``FontKey``, or a value of the wrong type
    /// even if it wants to. `validated()` then clamps ranges and repairs contrast,
    /// which matters more here than with a frontier model: a 3B on-device model
    /// will happily pick charcoal text on a charcoal background.
    public func generateTheme(from prompt: String) async throws -> ThemeTokens {
        switch await availability() {
        case .available: break
        case .unavailable(let reason), .ineligible(let reason):
            throw LLMError.providerFailed(identifier: identifier, message: reason)
        }

        let session = LanguageModelSession(instructions: Self.themeInstructions)
        do {
            let response = try await session.respond(
                to: "Design a reading theme: \(prompt)",
                generating: ThemeTokens.self
            )
            return response.content.validated()
        } catch is CancellationError {
            throw LLMError.cancelled
        } catch {
            throw LLMError.providerFailed(identifier: identifier, message: "\(error)")
        }
    }

    private static let themeInstructions = """
        You are a typographer designing how a browser renders articles for reading.

        Fill in every field. Rules:
        1. Body text must be comfortable for long reading: line height around 1.5-1.7, \
        measure 60-75 characters.
        2. The light and dark palettes are both complete designs, not inversions of \
        each other. Dark means a dark background with light text.
        3. Text must contrast strongly against its own background in each palette.
        4. Colours are #rrggbb hex.
        5. Match the requested look — a retro or newspaper brief wants period fonts, \
        square corners and ornament; a minimal brief wants restraint.
        """
}

extension Tone {
    /// The instruction fragment for this tone.
    var directive: String {
        switch self {
        case .neutral: "Keep the tone neutral."
        case .plain: "Use plain, everyday language. Prefer short sentences and common words."
        case .concise: "Be concise. Cut filler and repetition."
        case .friendly: "Use a warm, conversational tone."
        case .formal: "Use a formal tone."
        case .technical: "Use precise technical language."
        case .custom(let instruction): instruction
        }
    }
}

extension LengthPreference {
    var directive: String {
        switch self {
        case .asIs: "Keep roughly the same length."
        case .shorter: "Make it noticeably shorter."
        case .brief: "Reduce it to its essential point in one or two sentences."
        case .bullets: "Rewrite it as a short Markdown bullet list."
        case .expanded: "Unpack it with more explanation, using only what the passage already says."
        }
    }
}

extension ReadingLevel {
    var directive: String {
        switch self {
        case .simple: "Aim for a reading level a twelve-year-old would follow."
        case .general: "Aim for a general adult reading level."
        case .expert: "Assume an expert reader; do not explain background terms."
        }
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
