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
    func promptForDesign(origin: String?, over window: NSWindow?) async -> ReaderTheme? {
        guard let prompt = await askForPrompt(origin: origin, over: window) else { return nil }

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

    func forget(origin: String?) async {
        await store.remove(origin: origin)
    }

    // MARK: - Prompt

    private func askForPrompt(origin: String?, over window: NSWindow?) async -> String? {
        let alert = NSAlert()
        alert.messageText = origin.map { "Redesign \($0)" } ?? "Redesign every site"
        alert.informativeText = """
            Describe the look you want. The design is saved for this site and \
            reused on every visit.

            The model returns typography, colour and spacing values — never CSS — \
            so a generated design cannot load a webfont, fetch an image, or reach \
            the network on your behalf.
            """
        alert.addButton(withTitle: "Redesign")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "minimal, generous whitespace, warm greys"
        field.stringValue = (await store.design(for: origin))?.prompt ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let response: NSApplication.ModalResponse
        if let window {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        guard response == .alertFirstButtonReturn else { return nil }
        let prompt = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
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
            return "Add an OpenAI API key in Settings first."
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
