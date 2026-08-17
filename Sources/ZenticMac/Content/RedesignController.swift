import AppKit
import ZenticKit

/// Drives the "redesign this site" flow: prompt, generate, apply, remember.
///
/// Layer 2 already re-renders the page in Zentic's design system. This is the
/// axis on top of that — *which* design system. Presentation is separate from
/// tone on purpose: a tone change alters meaning and needs consent and a badge,
/// whereas a design change is lossless and reversible, so it needs no ceremony at
/// all and the user can play with it freely.
@MainActor
final class RedesignController {
    static let shared = RedesignController()

    let store = DesignStore()
    private var provider = OpenAIProvider()

    /// Ask for a prompt, generate, and hand back the theme.
    ///
    /// Returns nil when the user cancels or generation fails; the caller has
    /// already got a perfectly good page on screen either way.
    func promptForDesign(
        origin: String?,
        suggestions: [String] = [],
        over window: NSWindow?
    ) async -> ReaderTheme? {
        guard
            let prompt = await askForPrompt(
                origin: origin,
                suggestions: suggestions,
                over: window
            )
        else { return nil }

        switch await provider.availability() {
        case .available:
            break
        case .unavailable(let reason), .ineligible(let reason):
            present(error: reason, over: window)
            return nil
        }

        do {
            let tokens = try await provider.generateTheme(from: prompt)
            let theme = ReaderTheme(
                id: UUID().uuidString,
                name: prompt.count > 40 ? String(prompt.prefix(40)) + "…" : prompt,
                source: .generated,
                tokens: tokens,
                prompt: prompt,
                createdAt: Date()
            )
            await store.save(theme, for: origin)
            trace("redesign", "generated for \(origin ?? "all sites"): \(prompt)")
            return theme
        } catch {
            present(error: Self.message(for: error), over: window)
            return nil
        }
    }

    /// The saved design for an origin, if any.
    func savedDesign(for origin: String?) async -> ReaderTheme? {
        await store.design(for: origin)
    }

    /// Keep a built-in preset for this site.
    ///
    /// The same storage a generated design uses, deliberately: from the page's point
    /// of view a preset and a prompted design are both just validated tokens, and
    /// having two ways to remember "how this site should look" would mean two places
    /// to look when it looks wrong.
    func adopt(_ theme: ReaderTheme, for origin: String?) async {
        await store.save(theme, for: origin)
        trace("redesign", "\(theme.name) for \(origin ?? "all sites")")
    }

    func forget(origin: String?) async {
        await store.remove(origin: origin)
    }

    // MARK: - Prompt

    private func askForPrompt(
        origin: String?,
        suggestions: [String],
        over window: NSWindow?
    ) async -> String? {
        let alert = NSAlert()
        alert.messageText = origin.map { "Redesign \($0)" } ?? "Redesign every site"
        alert.informativeText = """
            Describe the look you want, or start from one of the suggestions and \
            edit it. The design is saved for this site and reused on every visit.

            The model returns typography, colour and spacing values — never CSS — \
            so a generated design cannot load a webfont, fetch an image, or reach \
            the network on your behalf.
            """
        alert.addButton(withTitle: "Redesign")
        alert.addButton(withTitle: "Cancel")

        // A combo box rather than a text field: it is still free text — anything can
        // be typed — but it opens with answers rather than with a blank. The
        // suggestions are tailored to the page, so the first one is usually close
        // enough to edit instead of compose.
        let field = NSComboBox(frame: NSRect(x: 0, y: 0, width: 380, height: 26))
        field.completes = true
        field.hasVerticalScroller = suggestions.count > 6
        field.numberOfVisibleItems = 8
        field.addItems(withObjectValues: suggestions)
        field.placeholderString = suggestions.first ?? "minimal, generous whitespace, warm greys"

        // A design already saved for this site wins: editing what you have is the
        // common case once a site has been designed once.
        if let existing = (await store.design(for: origin))?.prompt, !existing.isEmpty {
            field.stringValue = existing
        }

        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let response: NSApplication.ModalResponse
        if let window {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        guard response == .alertFirstButtonReturn else { return nil }

        // `stringValue` is empty when a suggestion was picked from the list without
        // the field being edited, so fall back to the selection.
        let typed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = typed.isEmpty ? (field.objectValueOfSelectedItem as? String ?? "") : typed
        let prompt = chosen.trimmingCharacters(in: .whitespacesAndNewlines)
        return prompt.isEmpty ? nil : prompt
    }

    private func present(error: String, over window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "Could not generate a design"
        alert.informativeText = error
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    private static func message(for error: any Error) -> String {
        guard let llm = error as? LLMError else { return "\(error)" }
        switch llm {
        case .notEntitled:
            return "Add an OpenAI API key first — Zentic ▸ OpenAI API Key… (⌘,)."
        case .providerFailed(_, let message):
            return message
        case .malformedOutput(let detail):
            return "The model returned something unusable: \(detail)"
        case .noProviderAvailable:
            return "No model is available."
        case .cancelled:
            return "Cancelled."
        case .contextTooLarge:
            return "That page is too large to process."
        }
    }
}
